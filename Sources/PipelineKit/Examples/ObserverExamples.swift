import Foundation

// Note: StandardPipeline is the standard pipeline implementation in PipelineKit

/// Examples demonstrating how to use the built-in observers
public struct ObserverExamples {
    
    /// Example: Using ConsoleObserver for development
    public static func consoleObserverExample() async throws {
        // Create a console observer with pretty formatting
        let consoleObserver = ConsoleObserver.development()
        
        // Create a pipeline with the observer
        let pipeline = ObservablePipeline(
            wrapping: StandardPipeline(handler: ExampleHandler()),
            observers: [consoleObserver]
        )
        
        // Execute commands - output will be printed to console
        let command = ExampleCommand(value: "Hello")
        let context = CommandContext(metadata: StandardCommandMetadata())
        let result = try await pipeline.execute(command, context: context)
        print("Result: \(result)")
    }
    
    /// Example: Using MemoryObserver for testing
    public static func memoryObserverExample() async throws {
        // Create a memory observer to capture events
        let memoryObserver = MemoryObserver(options: MemoryObserver.Options(
            maxEvents: 1000,
            captureMiddlewareEvents: true
        ))
        
        // Start cleanup if needed
        await memoryObserver.startCleanup()
        
        let pipeline = ObservablePipeline(
            wrapping: StandardPipeline(handler: ExampleHandler()),
            observers: [memoryObserver]
        )
        
        // Execute some commands
        for i in 0..<5 {
            let command = ExampleCommand(value: "Test \(i)")
            let context = CommandContext(metadata: StandardCommandMetadata())
            _ = try await pipeline.execute(command, context: context)
        }
        
        // Query the captured events
        let allEvents = await memoryObserver.allEvents()
        print("Captured \(allEvents.count) events")
        
        let stats = await memoryObserver.statistics()
        print("Executed \(stats.pipelineExecutions) pipelines")
        print("Success rate: \(Double(stats.successfulExecutions) / Double(stats.pipelineExecutions) * 100)%")
    }
    
    /// Example: Using MetricsObserver with console backend
    public static func metricsObserverExample() async throws {
        // Create a metrics observer with console backend for development
        let metricsBackend = ConsoleMetricsBackend()
        let metricsObserver = MetricsObserver(
            backend: metricsBackend,
            configuration: MetricsObserver.Configuration(
                metricPrefix: "myapp.pipeline",
                includeCommandType: true,
                trackMiddleware: true
            )
        )
        
        let pipeline = ObservablePipeline(
            wrapping: StandardPipeline(handler: ExampleHandler()),
            observers: [metricsObserver]
        )
        
        // Execute commands - metrics will be printed to console
        let command = ExampleCommand(value: "Metrics Test")
        let context = CommandContext(metadata: StandardCommandMetadata())
        _ = try await pipeline.execute(command, context: context)
    }
    
    /// Example: Using CompositeObserver to combine multiple observers
    public static func compositeObserverExample() async throws {
        // Combine console and memory observers
        let consoleObserver = ConsoleObserver(style: .simple, level: .info)
        let memoryObserver = MemoryObserver()
        let metricsObserver = MetricsObserver(
            backend: InMemoryMetricsBackend(),
            configuration: .init(metricPrefix: "app")
        )
        
        let compositeObserver = CompositeObserver(
            consoleObserver,
            memoryObserver,
            metricsObserver
        )
        
        let pipeline = ObservablePipeline(
            wrapping: StandardPipeline(handler: ExampleHandler()),
            observers: [compositeObserver]
        )
        
        // All observers will receive events
        let command = ExampleCommand(value: "Composite Test")
        let context = CommandContext(metadata: StandardCommandMetadata())
        _ = try await pipeline.execute(command, context: context)
    }
    
    /// Example: Using ConditionalObserver for selective observation
    public static func conditionalObserverExample() async throws {
        // Only observe specific command types
        let errorObserver = ConditionalObserver.onlyFailures(
            observer: ConsoleObserver(style: .pretty, level: .error)
        )
        
        // Only observe commands matching a pattern
        let importantObserver = ConditionalObserver.matching(
            pattern: "Important",
            observer: ConsoleObserver.development()
        )
        
        // Need separate pipelines for different command types
        let examplePipeline = ObservablePipeline(
            wrapping: StandardPipeline(handler: ExampleHandler()),
            observers: [errorObserver]
        )
        
        let importantPipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ImportantHandler()),
            observers: [importantObserver]
        )
        
        // This will be observed by importantObserver
        let importantCommand = ImportantCommand(value: "Critical")
        let context1 = CommandContext(metadata: StandardCommandMetadata())
        _ = try await importantPipeline.execute(importantCommand, context: context1)
        
        // This won't be observed by importantObserver (unless it fails and errorObserver sees it)
        let regularCommand = ExampleCommand(value: "Regular")
        let context2 = CommandContext(metadata: StandardCommandMetadata())
        _ = try await examplePipeline.execute(regularCommand, context: context2)
    }
    
    /// Example: Production setup with multiple observers
    public static func productionSetupExample() async throws {
        // OS Log for Apple platforms
        let osLogObserver = OSLogObserver.production()
        
        // Metrics for monitoring
        let metricsObserver = MetricsObserver(
            backend: MyProductionMetricsBackend(), // Your real metrics backend
            configuration: MetricsObserver.Configuration(
                metricPrefix: "production.pipeline",
                includeCommandType: true,
                includePipelineType: true,
                globalTags: [
                    "environment": "production",
                    "service": "api",
                    "version": "1.0.0"
                ]
            )
        )
        
        // Memory observer for debugging (with limited retention)
        let debugObserver = MemoryObserver(options: MemoryObserver.Options(
            maxEvents: 100,
            captureMiddlewareEvents: false,
            cleanupInterval: 3600 // 1 hour
        ))
        await debugObserver.startCleanup()
        
        // Create your pipeline with all observers
        let pipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ProductionHandler()),
            observers: [
                osLogObserver,
                metricsObserver,
                debugObserver
            ]
        )
        
        // Use the pipeline
        let command = ProductionCommand()
        let context = CommandContext(metadata: StandardCommandMetadata())
        _ = try await pipeline.execute(command, context: context)
    }
    
    /// Example: Using ObservableCommand for business metrics
    public static func observableCommandExample() async throws {
        // Create a pipeline with observers
        let consoleObserver = ConsoleObserver.development()
        let metricsObserver = MetricsObserver(
            backend: ConsoleMetricsBackend(),
            configuration: MetricsObserver.Configuration(
                metricPrefix: "ecommerce",
                includeCommandType: true
            )
        )
        
        let pipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ProcessOrderHandler()),
            observers: [consoleObserver, metricsObserver]
        )
        
        // Execute an observable command
        let order = ProcessOrderCommand(
            orderId: "ORDER-001",
            customerId: "CUSTOMER-123",
            items: [
                OrderItem(productId: "PRODUCT-A", quantity: 2, price: 29.99),
                OrderItem(productId: "PRODUCT-B", quantity: 1, price: 49.99)
            ],
            totalAmount: 109.97
        )
        
        let context = CommandContext(metadata: StandardCommandMetadata(
            userId: "CUSTOMER-123",
            correlationId: "TRACE-" + UUID().uuidString
        ))
        
        do {
            let result = try await pipeline.execute(order, context: context)
            print("✅ Order processed: \(result.orderId) - \(result.status)")
        } catch {
            print("❌ Order failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Example Commands and Handlers

private struct ExampleCommand: Command {
    let value: String
    typealias Result = String
}

private struct ImportantCommand: Command {
    let value: String
    typealias Result = String
}

private struct ProductionCommand: Command {
    typealias Result = Void
}

private struct ExampleHandler: CommandHandler {
    func handle(_ command: ExampleCommand) async throws -> String {
        return "Processed: \(command.value)"
    }
}

private struct ImportantHandler: CommandHandler {
    func handle(_ command: ImportantCommand) async throws -> String {
        return "Important: \(command.value)"
    }
}

private struct ProductionHandler: CommandHandler {
    func handle(_ command: ProductionCommand) async throws {
        // Production logic here
    }
}

// Placeholder for production metrics backend
private struct MyProductionMetricsBackend: MetricsBackend {
    func recordCounter(name: String, tags: [String: String]) async {
        // Send to your metrics service
    }
    
    func recordGauge(name: String, value: Double, tags: [String: String]) async {
        // Send to your metrics service
    }
    
    func recordHistogram(name: String, value: Double, tags: [String: String]) async {
        // Send to your metrics service
    }
}

// MARK: - ObservableCommand Example

/// Example e-commerce order command that demonstrates observability integration
private struct ProcessOrderCommand: Command, ObservableCommand {
    let orderId: String
    let customerId: String
    let items: [OrderItem]
    let totalAmount: Decimal
    
    typealias Result = OrderResult
    
    // ObservableCommand Implementation
    func setupObservability(context: CommandContext) async {
        // Set up custom observability data
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
    
    func observabilityDidComplete(context: CommandContext) async {
        // Record success metrics
        await context.recordMetric("orders.processed", value: 1, unit: "count")
        await context.recordMetric("orders.revenue", value: Double(truncating: totalAmount as NSNumber), unit: "currency")
        
        // Emit completion event
        await context.emitCustomEvent("ecommerce.order_processed", properties: [
            "order_id": orderId,
            "customer_id": customerId
        ])
    }
    
    func observabilityDidFail(context: CommandContext, error: Error) async {
        // Record failure metrics
        await context.recordMetric("orders.failed", value: 1, unit: "count")
        
        // Emit failure event
        await context.emitCustomEvent("ecommerce.order_failed", properties: [
            "order_id": orderId,
            "error_type": String(describing: type(of: error)),
            "error_reason": error.localizedDescription
        ])
    }
}

private struct OrderItem: Sendable {
    let productId: String
    let quantity: Int
    let price: Decimal
}

private struct OrderResult: Sendable {
    let orderId: String
    let status: OrderStatus
    let paymentMethod: String
    let shippingMethod: String
    let estimatedDelivery: Date
}

private enum OrderStatus: String, Sendable {
    case confirmed = "confirmed"
    case processing = "processing"
    case shipped = "shipped"
    case delivered = "delivered"
    case cancelled = "cancelled"
}

private struct ProcessOrderHandler: CommandHandler {
    typealias CommandType = ProcessOrderCommand
    
    func handle(_ command: ProcessOrderCommand) async throws -> OrderResult {
        // Simulate order processing
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        return OrderResult(
            orderId: command.orderId,
            status: .confirmed,
            paymentMethod: "credit_card",
            shippingMethod: "standard",
            estimatedDelivery: Date().addingTimeInterval(7 * 24 * 60 * 60)
        )
    }
}