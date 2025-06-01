import Foundation

// MARK: - Example Commands

struct CreateOrderCommand: Command, ValidatableCommand {
    typealias Result = Order
    
    let customerId: String
    let items: [ContextOrderItem]
    let paymentMethod: String
    
    func validate() throws {
        try CommandValidator.validateNotEmpty(customerId, field: "customerId")
        guard !items.isEmpty else {
            throw ValidationError.custom("Order must contain at least one item")
        }
        guard ["credit_card", "paypal", "apple_pay"].contains(paymentMethod) else {
            throw ValidationError.custom("Invalid payment method")
        }
    }
}

struct Order: Sendable {
    let id: String
    let customerId: String
    let items: [ContextOrderItem]
    let total: Double
    let discount: Double
    let status: String
}

internal struct ContextOrderItem: Sendable {
    let productId: String
    let quantity: Int
    let price: Double
}

// MARK: - Context Keys

struct CustomerContextKey: ContextKey {
    typealias Value = Customer
}

struct DiscountContextKey: ContextKey {
    typealias Value = Double
}

struct InventoryContextKey: ContextKey {
    typealias Value = [String: Int] // productId -> available quantity
}

struct Customer: Sendable {
    let id: String
    let name: String
    let loyaltyTier: String
}

// MARK: - Context-Aware Middleware

struct CustomerEnrichmentMiddleware: ContextAwareMiddleware {
    let customerService: CustomerService
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if command has customerId
        if let orderCommand = command as? CreateOrderCommand {
            let customer = try await customerService.getCustomer(orderCommand.customerId)
            await context.set(customer, for: CustomerContextKey.self)
        }
        
        return try await next(command, context)
    }
}

struct LoyaltyDiscountMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Apply discount based on customer loyalty tier
        if let customer = await context[CustomerContextKey.self] {
            let discount: Double = switch customer.loyaltyTier {
            case "gold": 0.15
            case "silver": 0.10
            case "bronze": 0.05
            default: 0.0
            }
            
            await context.set(discount, for: DiscountContextKey.self)
        }
        
        return try await next(command, context)
    }
}

struct ContextInventoryCheckMiddleware: ContextAwareMiddleware {
    let inventoryService: InventoryService
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        if let orderCommand = command as? CreateOrderCommand {
            // Load inventory for all products
            let productIds = orderCommand.items.map { $0.productId }
            let inventory = try await inventoryService.getInventory(for: productIds)
            await context.set(inventory, for: InventoryContextKey.self)
            
            // Verify availability
            for item in orderCommand.items {
                let available = inventory[item.productId] ?? 0
                guard available >= item.quantity else {
                    throw OrderError.insufficientInventory(productId: item.productId)
                }
            }
        }
        
        return try await next(command, context)
    }
}

// MARK: - Context-Aware Handler

struct CreateOrderHandler: CommandHandler {
    typealias CommandType = CreateOrderCommand
    
    func handle(_ command: CreateOrderCommand) async throws -> Order {
        // In a real implementation, this would create the order in the database
        let total = command.items.reduce(0) { $0 + ($1.price * Double($1.quantity)) }
        
        return Order(
            id: UUID().uuidString,
            customerId: command.customerId,
            items: command.items,
            total: total,
            discount: 0, // Will be enriched by context
            status: "pending"
        )
    }
}

// MARK: - Context-Aware Handler Wrapper

struct ContextAwareCreateOrderHandler: CommandHandler {
    typealias CommandType = CreateOrderCommand
    
    let baseHandler: CreateOrderHandler
    let context: CommandContext
    
    func handle(_ command: CreateOrderCommand) async throws -> Order {
        var order = try await baseHandler.handle(command)
        
        // Enrich order with context data
        if let discount = await context[DiscountContextKey.self] {
            let discountAmount = order.total * discount
            order = Order(
                id: order.id,
                customerId: order.customerId,
                items: order.items,
                total: order.total - discountAmount,
                discount: discountAmount,
                status: order.status
            )
        }
        
        return order
    }
}

// MARK: - Service Protocols

protocol CustomerService: Sendable {
    func getCustomer(_ id: String) async throws -> Customer
}

protocol InventoryService: Sendable {
    func getInventory(for productIds: [String]) async throws -> [String: Int]
}

enum OrderError: Error, Sendable {
    case insufficientInventory(productId: String)
    case paymentFailed
    case customerNotFound
}

// MARK: - Usage Example

func demonstrateContextAwarePipeline() async throws {
    // Mock services
    struct MockCustomerService: CustomerService {
        func getCustomer(_ id: String) async throws -> Customer {
            Customer(id: id, name: "John Doe", loyaltyTier: "gold")
        }
    }
    
    struct MockInventoryService: InventoryService {
        func getInventory(for productIds: [String]) async throws -> [String: Int] {
            Dictionary(uniqueKeysWithValues: productIds.map { ($0, 100) })
        }
    }
    
    // Build context-aware pipeline
    let builder = ContextAwarePipelineBuilder(handler: CreateOrderHandler())
    _ = await builder.withRegular(ValidationMiddleware()) // Regular middleware
    _ = await builder.with(CustomerEnrichmentMiddleware(customerService: MockCustomerService()))
    _ = await builder.with(LoyaltyDiscountMiddleware())
    _ = await builder.with(ContextInventoryCheckMiddleware(inventoryService: MockInventoryService()))
    _ = await builder.with(ContextMetricsMiddleware { name, duration in
        print("Command \(name) executed in \(duration)s")
    })
    let pipeline = try await builder.build()
    
    // Create order command
    let command = CreateOrderCommand(
        customerId: "customer-123",
        items: [
            ContextOrderItem(productId: "prod-1", quantity: 2, price: 29.99),
            ContextOrderItem(productId: "prod-2", quantity: 1, price: 49.99)
        ],
        paymentMethod: "credit_card"
    )
    
    // Execute through pipeline
    let order = try await pipeline.execute(
        command,
        metadata: DefaultCommandMetadata(userId: "customer-123")
    )
    
    print("Order created: \(order.id)")
    print("Total: $\(order.total)")
    print("Discount: $\(order.discount)")
}

// MARK: - Comparison with Regular Pipeline

func demonstrateRegularVsContextPipeline() async throws {
    // Regular pipeline - middleware cannot share state
    let _ = DefaultPipeline(handler: CreateOrderHandler())
    
    // Context-aware pipeline - middleware can share state
    let _ = ContextAwarePipeline(handler: CreateOrderHandler())
    
    // Regular middleware must pass all data through command/result
    // Context-aware middleware can store intermediate results in context
    
    /*
    Key differences:
    
    1. State Sharing:
       - Regular: No shared state between middleware
       - Context: Shared context accessible by all middleware
    
    2. Middleware Communication:
       - Regular: Must modify command or result to pass data
       - Context: Can store typed values in context
    
    3. Use Cases:
       - Regular: Simple, stateless transformations
       - Context: Complex workflows with shared state
    
    4. Performance:
       - Regular: Slightly faster, no context overhead
       - Context: Small overhead for context management
    
    5. Type Safety:
       - Regular: Command/Result types must contain all data
       - Context: Type-safe key-value storage
    */
}
