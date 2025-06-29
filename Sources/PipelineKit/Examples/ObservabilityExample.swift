import Foundation

// MARK: - Example Commands

/// Example e-commerce order command that demonstrates observability integration
public struct ProcessOrderCommand: Command, ObservableCommand {
    public let orderId: String
    public let customerId: String
    public let items: [OrderItem]
    public let totalAmount: Decimal
    
    public typealias Result = OrderResult
    
    public init(orderId: String, customerId: String, items: [OrderItem], totalAmount: Decimal) {
        self.orderId = orderId
        self.customerId = customerId
        self.items = items
        self.totalAmount = totalAmount
    }
    
    // MARK: - ObservableCommand Implementation
    
    public func setupObservability(context: CommandContext) async {
        // Set up custom observability data for this order
        await context.setObservabilityData("order.id", value: orderId)
        await context.setObservabilityData("order.customer_id", value: customerId)
        await context.setObservabilityData("order.item_count", value: items.count)
        await context.setObservabilityData("order.total_amount", value: totalAmount)
        
        // Emit business event
        await context.emitCustomEvent("ecommerce.order_processing_started", properties: [
            "order_id": orderId,
            "customer_id": customerId,
            "item_count": String(items.count),
            "total_amount": totalAmount.description
        ])
    }
    
    public func observabilityDidComplete(context: CommandContext) async {
        // Record successful order processing metrics
        await context.recordMetric("orders.processed", value: 1, unit: "count")
        await context.recordMetric("orders.revenue", value: Double(truncating: totalAmount as NSNumber), unit: "currency")
        
        // Emit business completion event
        await context.emitCustomEvent("ecommerce.order_processed", properties: [
            "order_id": orderId,
            "customer_id": customerId,
            "item_count": String(items.count),
            "total_amount": totalAmount.description
        ])
    }
    
    public func observabilityDidFail(context: CommandContext, error: Error) async {
        // Record failure metrics
        await context.recordMetric("orders.failed", value: 1, unit: "count")
        
        // Emit business failure event
        await context.emitCustomEvent("ecommerce.order_failed", properties: [
            "order_id": orderId,
            "error_type": String(describing: type(of: error)),
            "error_reason": error.localizedDescription
        ])
    }
}

public struct OrderItem: Sendable {
    public let productId: String
    public let quantity: Int
    public let price: Decimal
    
    public init(productId: String, quantity: Int, price: Decimal) {
        self.productId = productId
        self.quantity = quantity
        self.price = price
    }
}

public struct OrderResult: Sendable {
    public let orderId: String
    public let status: OrderStatus
    public let paymentMethod: String
    public let shippingMethod: String
    public let estimatedDelivery: Date
    
    public init(orderId: String, status: OrderStatus, paymentMethod: String, shippingMethod: String, estimatedDelivery: Date) {
        self.orderId = orderId
        self.status = status
        self.paymentMethod = paymentMethod
        self.shippingMethod = shippingMethod
        self.estimatedDelivery = estimatedDelivery
    }
}

public enum OrderStatus: String, Sendable {
    case confirmed = "confirmed"
    case processing = "processing"
    case shipped = "shipped"
    case delivered = "delivered"
    case cancelled = "cancelled"
}

// MARK: - Example Handler

public struct ProcessOrderHandler: CommandHandler {
    public typealias CommandType = ProcessOrderCommand
    
    public init() {}
    
    public func handle(_ command: ProcessOrderCommand) async throws -> OrderResult {
        // Simulate order processing with various steps
        try await simulateInventoryCheck(for: command.items)
        try await simulatePaymentProcessing(amount: command.totalAmount)
        try await simulateShippingArrangement(customerId: command.customerId)
        
        return OrderResult(
            orderId: command.orderId,
            status: .confirmed,
            paymentMethod: "credit_card",
            shippingMethod: "standard",
            estimatedDelivery: Date().addingTimeInterval(7 * 24 * 60 * 60) // 7 days
        )
    }
    
    private func simulateInventoryCheck(for items: [OrderItem]) async throws {
        // Simulate some processing time
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Simulate occasional inventory issues
        if items.count > 5 {
            throw OrderProcessingError.insufficientInventory
        }
    }
    
    private func simulatePaymentProcessing(amount: Decimal) async throws {
        // Simulate payment processing time
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Simulate occasional payment failures
        if amount > 1000 {
            throw OrderProcessingError.paymentDeclined
        }
    }
    
    private func simulateShippingArrangement(customerId: String) async throws {
        // Simulate shipping arrangement time
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
}

public enum OrderProcessingError: Error, LocalizedError {
    case insufficientInventory
    case paymentDeclined
    case shippingUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .insufficientInventory:
            return "Insufficient inventory for one or more items"
        case .paymentDeclined:
            return "Payment was declined"
        case .shippingUnavailable:
            return "Shipping is not available to this location"
        }
    }
}

// MARK: - Observable Middleware Examples

/// Example middleware that tracks inventory operations
public struct InventoryTrackingMiddleware: ContextAwareMiddleware, ObservableMiddleware {
    
    public var observabilityName: String { "InventoryTracker" }
    public var observabilityTags: [String: String] { ["component": "inventory", "version": "2.1.0"] }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        
        // Check if this is an order command
        if let orderCommand = command as? ProcessOrderCommand {
            await trackInventoryReservation(for: orderCommand, context: context)
        }
        
        return try await next(command, context)
    }
    
    private func trackInventoryReservation(for order: ProcessOrderCommand, context: CommandContext) async {
        let totalItems = order.items.reduce(0) { $0 + $1.quantity }
        
        await context.recordMetric("inventory.items_reserved", value: Double(totalItems), unit: "count")
        
        await context.emitCustomEvent("inventory.reservation_attempted", properties: [
            "order_id": order.orderId,
            "item_count": String(totalItems),
            "product_ids": order.items.map { $0.productId }.joined(separator: ",")
        ])
    }
}

/// Example middleware that tracks payment operations
public struct PaymentTrackingMiddleware: ContextAwareMiddleware, ObservableMiddleware {
    
    public var observabilityName: String { "PaymentTracker" }
    public var observabilityTags: [String: String] { ["component": "payment", "provider": "stripe"] }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        
        if let orderCommand = command as? ProcessOrderCommand {
            await trackPaymentAttempt(for: orderCommand, context: context)
        }
        
        do {
            let result = try await next(command, context)
            
            if let orderCommand = command as? ProcessOrderCommand,
               let orderResult = result as? OrderResult {
                await trackPaymentSuccess(order: orderCommand, result: orderResult, context: context)
            }
            
            return result
            
        } catch {
            if let orderCommand = command as? ProcessOrderCommand {
                await trackPaymentFailure(order: orderCommand, error: error, context: context)
            }
            throw error
        }
    }
    
    private func trackPaymentAttempt(for order: ProcessOrderCommand, context: CommandContext) async {
        await context.recordMetric("payments.attempted", value: 1, unit: "count")
        await context.recordMetric("payments.amount_attempted", value: Double(truncating: order.totalAmount as NSNumber), unit: "currency")
        
        await context.emitCustomEvent("payment.attempt_started", properties: [
            "order_id": order.orderId,
            "amount": order.totalAmount.description,
            "customer_id": order.customerId
        ])
    }
    
    private func trackPaymentSuccess(order: ProcessOrderCommand, result: OrderResult, context: CommandContext) async {
        await context.recordMetric("payments.successful", value: 1, unit: "count")
        await context.recordMetric("payments.amount_processed", value: Double(truncating: order.totalAmount as NSNumber), unit: "currency")
        
        await context.emitCustomEvent("payment.completed", properties: [
            "order_id": order.orderId,
            "amount": order.totalAmount.description,
            "payment_method": result.paymentMethod
        ])
    }
    
    private func trackPaymentFailure(order: ProcessOrderCommand, error: Error, context: CommandContext) async {
        await context.recordMetric("payments.failed", value: 1, unit: "count")
        
        await context.emitCustomEvent("payment.failed", properties: [
            "order_id": order.orderId,
            "amount": order.totalAmount.description,
            "error_type": String(describing: type(of: error)),
            "error_message": error.localizedDescription
        ])
    }
}

// MARK: - Complete Example Setup

/// Demonstrates how to set up a complete observable pipeline
public class ObservabilityExampleSetup {
    
    public static func createDevelopmentPipeline<T: Command, H: CommandHandler>(
        handler: H
    ) async throws -> ContextAwarePipeline where H.CommandType == T {
        let pipeline = ContextAwarePipeline(handler: handler)
        
        // Add observability middleware first
        try await pipeline.addMiddleware(ObservabilityMiddleware(configuration: .development()))
        try await pipeline.addMiddleware(PerformanceTrackingMiddleware())
        try await pipeline.addMiddleware(DistributedTracingMiddleware(serviceName: "ecommerce-api", version: "1.2.0"))
        
        // Add business middleware with observability decorators
        try await pipeline.addMiddleware(
            InventoryTrackingMiddleware()
                .withObservability(name: "InventoryTracker", order: 100)
        )
        try await pipeline.addMiddleware(
            PaymentTrackingMiddleware()
                .withObservability(name: "PaymentTracker", order: 200)
        )
        
        // Add custom event emitter
        try await pipeline.addMiddleware(CustomEventEmitterMiddleware(eventPrefix: "ecommerce"))
        
        return pipeline
    }
    
    @available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
    public static func createProductionPipeline<P: Pipeline>(
        basePipeline: P
    ) async -> ObservablePipeline where P: Sendable {
        // Create observable wrapper
        let observers: [PipelineObserver] = [
            OSLogObserver.production()
        ]
        
        return ObservablePipeline(wrapping: basePipeline, observers: observers)
    }
    
    /// Example usage demonstrating the complete observability system
    public static func runExample() async throws {
        print("🔍 Starting Observability Example")
        
        // Create development pipeline with full observability
        let handler = ProcessOrderHandler()
        let pipeline = try await createDevelopmentPipeline(handler: handler)
        
        // Create example order
        let order = ProcessOrderCommand(
            orderId: "ORDER-001",
            customerId: "CUSTOMER-123",
            items: [
                OrderItem(productId: "PRODUCT-A", quantity: 2, price: 29.99),
                OrderItem(productId: "PRODUCT-B", quantity: 1, price: 49.99)
            ],
            totalAmount: 109.97
        )
        
        // Execute with observability
        do {
            let result = try await pipeline.execute(order, metadata: StandardCommandMetadata(
                userId: "CUSTOMER-123",
                correlationId: "TRACE-" + UUID().uuidString
            ))
            
            print("✅ Order processed successfully: \(result.orderId) - \(result.status)")
            
        } catch {
            print("❌ Order processing failed: \(error.localizedDescription)")
        }
        
        print("🔍 Observability Example Complete")
    }
}