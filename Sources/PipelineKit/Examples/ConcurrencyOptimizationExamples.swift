import Foundation

// MARK: - Example Commands

struct ProcessOrderCommand: Command {
    typealias Result = OrderResult
    let orderId: String
    let items: [OrderItem]
}

struct OrderResult: Sendable {
    let orderId: String
    let total: Decimal
    let estimatedDelivery: Date
}

struct OrderItem: Sendable {
    let productId: String
    let quantity: Int
    let price: Decimal
}

struct ProcessOrderHandler: CommandHandler {
    typealias CommandType = ProcessOrderCommand
    
    func handle(_ command: ProcessOrderCommand) async throws -> OrderResult {
        // Simulate order processing
        let total = command.items.reduce(Decimal(0)) { $0 + ($1.price * Decimal($1.quantity)) }
        let estimatedDelivery = Date().addingTimeInterval(86400 * 3) // 3 days
        
        return OrderResult(
            orderId: command.orderId,
            total: total,
            estimatedDelivery: estimatedDelivery
        )
    }
}

// MARK: - Batching Example

/// Demonstrates efficient bulk order processing with batching
func batchingExample() async throws {
    print("=== Batching Example ===")
    
    // Create pipeline with order processing handler
    let pipeline = StandardPipeline(handler: ProcessOrderHandler())
    
    // Configure batch processor for high-throughput
    let batchConfig = BatchProcessor<ProcessOrderCommand>.Configuration(
        maxBatchSize: 100,
        maxBatchWaitTime: 0.01, // 10ms
        preserveOrder: false, // Allow parallel processing within batch
        partialBatchStrategy: .processAfterTimeout
    )
    
    let batchProcessor = BatchProcessor(
        pipeline: pipeline,
        configuration: batchConfig
    )
    
    // Create 1000 orders to process
    let orders = (0..<1000).map { i in
        ProcessOrderCommand(
            orderId: "ORDER-\(i)",
            items: [
                OrderItem(productId: "PROD-1", quantity: 2, price: 29.99),
                OrderItem(productId: "PROD-2", quantity: 1, price: 49.99)
            ]
        )
    }
    
    let start = CFAbsoluteTimeGetCurrent()
    
    // Submit all orders as a batch
    let results = try await batchProcessor.submitBatch(orders)
    
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    
    print("Processed \(results.count) orders in \(elapsed)s")
    print("Average: \(elapsed / Double(results.count) * 1000)ms per order")
    
    // Check results
    let successful = results.filter { if case .success = $0 { return true } else { return false } }.count
    print("Success rate: \(Double(successful) / Double(results.count) * 100)%")
}

// MARK: - Parallel Middleware Example

/// Demonstrates parallel execution of independent middleware
func parallelMiddlewareExample() async throws {
    print("\n=== Parallel Middleware Example ===")
    
    // Create parallel pipeline with dependency analysis
    var dependencyGraph = ParallelMiddlewareExecutor.DependencyGraph()
    
    // Define middleware dependencies
    // Authentication must run before authorization
    // dependencyGraph.addDependency(from: AuthorizationMiddleware.self, to: AuthenticationMiddleware.self)
    
    let parallelPipeline = ParallelPipeline(
        handler: ProcessOrderHandler(),
        dependencyGraph: dependencyGraph
    )
    
    // Add middleware that can run in parallel
    await parallelPipeline.addMiddleware(OrderLoggingMiddleware())
    await parallelPipeline.addMiddleware(OrderMetricsMiddleware())
    await parallelPipeline.addMiddleware(OrderTracingMiddleware())
    await parallelPipeline.addMiddleware(OrderValidationMiddleware())
    
    let testOrder = ProcessOrderCommand(
        orderId: "TEST-123",
        items: [
            OrderItem(productId: "PROD-1", quantity: 5, price: 99.99)
        ]
    )
    
    let start = CFAbsoluteTimeGetCurrent()
    
    // Execute with parallel middleware
    let result = try await parallelPipeline.execute(testOrder)
    
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    
    print("Order processed in \(elapsed * 1000)ms")
    print("Result: \(result)")
}

// MARK: - Work-Stealing Example

/// Demonstrates work-stealing for uneven workloads
func workStealingExample() async throws {
    print("\n=== Work-Stealing Example ===")
    
    let executor = WorkStealingPipelineExecutor(workerCount: 8)
    
    // Create orders with varying complexity
    let complexOrders = (0..<100).map { i -> @Sendable () async throws -> OrderResult in
        let complexity = i % 10 == 0 ? 100 : 10 // Every 10th order is complex
        
        return {
            // Simulate complex processing
            for _ in 0..<complexity {
                _ = (0..<1000).reduce(0, +)
            }
            
            return OrderResult(
                orderId: "COMPLEX-\(i)",
                total: Decimal(100 * complexity),
                estimatedDelivery: Date()
            )
        }
    }
    
    let start = CFAbsoluteTimeGetCurrent()
    
    // Execute with work-stealing
    let results = await withTaskGroup(of: OrderResult.self) { group in
        for work in complexOrders {
            group.addTask {
                try! await executor.execute(work)
            }
        }
        
        var results: [OrderResult] = []
        for await result in group {
            results.append(result)
        }
        return results
    }
    
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    
    print("Processed \(results.count) complex orders in \(elapsed)s")
    print("Work-stealing distributed load efficiently across workers")
}

// MARK: - Adaptive Concurrency Example

/// Demonstrates adaptive concurrency based on system load
func adaptiveConcurrencyExample() async throws {
    print("\n=== Adaptive Concurrency Example ===")
    
    // Create base pipeline
    let basePipeline = StandardPipeline(handler: ProcessOrderHandler())
    
    // Configure adaptive controller
    let adaptiveConfig = AdaptiveConcurrencyController.Configuration(
        minConcurrency: 2,
        maxConcurrency: 50,
        targetCPUUtilization: 0.8,
        targetMemoryPressure: 0.7,
        adjustmentInterval: 2.0, // Adjust every 2 seconds
        adjustmentAggressiveness: 0.5
    )
    
    let adaptivePipeline = AdaptivePipeline(
        basePipeline: basePipeline,
        controllerConfig: adaptiveConfig
    )
    
    // Simulate varying load
    for phase in 0..<3 {
        print("\nPhase \(phase + 1):")
        
        let load = phase == 1 ? 500 : 50 // High load in middle phase
        let orders = (0..<load).map { i in
            ProcessOrderCommand(
                orderId: "ADAPTIVE-\(phase)-\(i)",
                items: [OrderItem(productId: "PROD-1", quantity: 1, price: 10.00)]
            )
        }
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for order in orders {
                group.addTask {
                    _ = try? await adaptivePipeline.execute(order)
                }
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let metrics = await adaptivePipeline.getAdaptiveMetrics()
        
        print("  Load: \(load) orders")
        print("  Time: \(elapsed)s")
        print("  Concurrency limit: \(metrics.currentConcurrencyLimit)")
        print("  Utilization: \(metrics.utilizationPercent)%")
    }
}

// MARK: - Lock-Free Example

/// Demonstrates ultra-low latency with lock-free components
func lockFreeExample() async throws {
    print("\n=== Lock-Free Example ===")
    
    // Create lock-free pipeline for ultra-low latency
    let lockFreePipeline = LockFreePipeline(
        handler: ProcessOrderHandler(),
        middlewares: [] // Middleware must be set at initialization
    )
    
    // Create high-frequency orders
    let orders = (0..<10000).map { i in
        ProcessOrderCommand(
            orderId: "LOCKFREE-\(i)",
            items: [OrderItem(productId: "PROD-1", quantity: 1, price: 1.00)]
        )
    }
    
    let start = CFAbsoluteTimeGetCurrent()
    
    // Submit orders concurrently
    await withTaskGroup(of: Void.self) { group in
        for order in orders {
            group.addTask {
                _ = try? await lockFreePipeline.execute(order)
            }
        }
    }
    
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    
    // Get metrics
    let metrics = await lockFreePipeline.performanceMetrics
    
    print("Processed \(metrics.commandCount) orders in \(elapsed)s")
    print("Throughput: \(Double(metrics.commandCount) / elapsed) orders/second")
    print("Average latency: \(metrics.averageLatency * 1000)ms")
    print("Max latency: \(metrics.maxLatencySeconds * 1000)ms")
    print("Success rate: \(metrics.successRate * 100)%")
}

// MARK: - Optimized Concurrent Pipeline Example

/// Demonstrates reduced actor contention with sharding
func optimizedConcurrentPipelineExample() async throws {
    print("\n=== Optimized Concurrent Pipeline Example ===")
    
    // Create optimized pipeline with sharding
    let optimizedPipeline = OptimizedConcurrentPipeline(
        options: PipelineOptions(
            maxConcurrency: 20,
            backPressureStrategy: .suspend
        ),
        shardCount: 16 // Distribute across 16 shards
    )
    
    // Register different command types
    await optimizedPipeline.register(ProcessOrderCommand.self, pipeline: StandardPipeline(handler: ProcessOrderHandler()))
    
    // Create concurrent load
    let orders = (0..<1000).map { i in
        ProcessOrderCommand(
            orderId: "OPTIMIZED-\(i)",
            items: [OrderItem(productId: "PROD-1", quantity: 1, price: 5.00)]
        )
    }
    
    let start = CFAbsoluteTimeGetCurrent()
    
    // Execute concurrently
    await withTaskGroup(of: Void.self) { group in
        for order in orders {
            group.addTask {
                _ = try? await optimizedPipeline.execute(order)
            }
        }
    }
    
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    
    print("Processed \(orders.count) orders in \(elapsed)s")
    print("Sharding reduced actor contention for better throughput")
}

// MARK: - Supporting Middleware

struct OrderLoggingMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        // Log order processing
        if let order = command as? ProcessOrderCommand {
            print("Processing order: \(order.orderId)")
        }
        return try await next(command, context)
    }
}

struct OrderMetricsMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        let start = Date()
        let result = try await next(command, context)
        let duration = Date().timeIntervalSince(start)
        
        // Record metrics
        await context.set(duration, for: ProcessingDurationKey.self)
        
        return result
    }
}

struct OrderTracingMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        let traceId = UUID().uuidString
        await context.set(traceId, for: TraceIDKey.self)
        return try await next(command, context)
    }
}

struct OrderValidationMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        if let order = command as? ProcessOrderCommand {
            guard !order.items.isEmpty else {
                throw OrderValidationError.emptyOrder
            }
        }
        return try await next(command, context)
    }
}

enum OrderValidationError: Error {
    case emptyOrder
}

struct ProcessingDurationKey: ContextKey {
    typealias Value = TimeInterval
}

// MARK: - Main Example Runner

@main
struct ConcurrencyOptimizationExamples {
    static func main() async throws {
        print("PipelineKit Concurrency Optimization Examples")
        print("============================================\n")
        
        // Run all examples
        try await batchingExample()
        try await parallelMiddlewareExample()
        try await workStealingExample()
        try await adaptiveConcurrencyExample()
        try await lockFreeExample()
        try await optimizedConcurrentPipelineExample()
        
        print("\n✅ All examples completed successfully!")
    }
}