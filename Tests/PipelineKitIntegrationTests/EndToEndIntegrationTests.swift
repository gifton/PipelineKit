import XCTest
@testable import PipelineKit
@testable import PipelineKitCore
import PipelineKitTestSupport

/// End-to-end integration tests that verify complete system functionality
final class EndToEndIntegrationTests: XCTestCase {
    // MARK: - Complete Pipeline Integration Test
    
    func testCompleteOrderProcessingPipeline() async throws {
        // Given - Full order processing pipeline with all middleware
        let pipeline = StandardPipeline()
        
        // Add all middleware in proper order
        pipeline.use(LoggingMiddleware())
        pipeline.use(MetricsMiddleware())
        pipeline.use(ValidationMiddleware())
        pipeline.use(AuthenticationMiddleware { token in
            guard let token = token, token.starts(with: "token-") || token == "valid-token" else {
                throw PipelineError.authorization(reason: .invalidCredentials)
            }
            return "authenticated-user"
        })
        pipeline.use(AuthorizationMiddleware { userId, permission in
            return true // Allow all for testing
        })
        pipeline.use(RateLimitingMiddleware(limiter: PipelineKitCore.RateLimiter(
            strategy: .tokenBucket(capacity: 100, refillRate: 10),
            scope: .global
        )))
        pipeline.use(CachingMiddleware(cache: InMemoryCache()))
        pipeline.use(PipelineKitResilience.CircuitBreakerMiddleware())
        pipeline.use(RetryMiddleware(maxAttempts: 3))
        // TODO: Add when these middleware are implemented
        // pipeline.use(EncryptionMiddleware(encryptionService: MockEncryptionService()))
        // pipeline.use(AuditLoggingMiddleware(logger: MockAuditLogger()))
        
        // Register handler
        pipeline.registerHandler { (command: CreateOrderCommand, _: CommandContext) in
            // Simulate order creation
            return Order(
                id: UUID().uuidString,
                userId: command.userId,
                items: command.items,
                total: command.items.reduce(0) { $0 + $1.price * Double($1.quantity) },
                status: .created
            )
        }
        
        // Setup context with authentication
        let context = CommandContext.test()
        await context.set("user123", for: "user_id")
        await context.set("valid-token", for: "auth_token")
        await context.set(["create_order"], for: "permissions")
        
        // When - Execute order creation
        let command = CreateOrderCommand(
            userId: "user123",
            items: [
                OrderItem(productId: "prod1", quantity: 2, price: 29.99),
                OrderItem(productId: "prod2", quantity: 1, price: 49.99)
            ]
        )
        
        let order = try await pipeline.execute(command, context: context)
        
        // Then - Verify order created successfully
        XCTAssertEqual(order.userId, "user123")
        XCTAssertEqual(order.items.count, 2)
        XCTAssertEqual(order.total, 109.97, accuracy: 0.01)
        XCTAssertEqual(order.status, .created)
        
        // Verify middleware executed
        let requestId = await context.get(String.self, for: "request_id")
        XCTAssertNotNil(requestId) // From logging
        XCTAssertNotNil(context.metrics["execution_time"]) // From metrics
        let authenticated = await context.get(Bool.self, for: "authenticated") ?? false
        XCTAssertTrue(authenticated) // From auth
    }
    
    // MARK: - Multi-Stage Pipeline Integration
    
    func testMultiStagePipelineIntegration() async throws {
        // Given - Complex multi-stage pipeline
        let validationPipeline = StandardPipeline()
        validationPipeline.use(ValidationMiddleware())
        validationPipeline.registerHandler { (command: ProcessDataCommand, context: CommandContext) in
            await context.set(true, for: "validation_passed")
            return ProcessedData(
                originalData: command.data,
                transformedData: "",
                enrichedData: [:],
                processingTime: Date()
            )
        }
        
        let processingPipeline = StandardPipeline()
        processingPipeline.use(TransformationMiddleware())
        processingPipeline.use(EnrichmentMiddleware())
        processingPipeline.registerHandler { (command: ProcessDataCommand, context: CommandContext) in
            let transformedData = await context.get(String.self, for: "transformed_data") ?? ""
            let enrichedData = await context.get([String: Any].self, for: "enriched_data") ?? [:]
            return ProcessedData(
                originalData: command.data,
                transformedData: transformedData,
                enrichedData: enrichedData,
                processingTime: Date()
            )
        }
        
        let notificationPipeline = StandardPipeline()
        notificationPipeline.use(NotificationMiddleware())
        notificationPipeline.registerHandler { (_: SendNotificationCommand, _: CommandContext) in
            NotificationResult(success: true, messageId: UUID().uuidString)
        }
        
        // Orchestrate stages
        let context = CommandContext.test()
        
        // Stage 1: Validation
        let dataCommand = ProcessDataCommand(data: "test-data-123")
        _ = try await validationPipeline.execute(dataCommand, context: context)
        
        let validationPassed = await context.get(Bool.self, for: "validation_passed") ?? false
        guard validationPassed else {
            XCTFail("Validation should pass")
            return
        }
        
        // Stage 2: Processing
        let processedData = try await processingPipeline.execute(dataCommand, context: context)
        
        // Stage 3: Notification
        let notificationCommand = SendNotificationCommand(
            recipient: "user@example.com",
            message: "Data processed: \(processedData.transformedData)"
        )
        let notificationResult = try await notificationPipeline.execute(notificationCommand, context: context)
        
        // Then - Verify complete flow
        XCTAssertTrue(notificationResult.success)
        XCTAssertNotNil(processedData.transformedData)
        XCTAssertFalse(processedData.enrichedData.isEmpty)
    }
    
    // MARK: - Concurrent Pipeline Execution Integration
    
    func testConcurrentPipelineExecutionIntegration() async throws {
        // Given - Pipeline handling concurrent requests
        let pipeline = StandardPipeline()
        let semaphore = MockAsyncSemaphore(value: 10) // Limit concurrency
        
        pipeline.use(ConcurrencyLimitingMiddleware(semaphore: semaphore))
        // TODO: Add when LoadBalancingMiddleware is implemented
        // pipeline.use(LoadBalancingMiddleware())
        pipeline.use(MetricsMiddleware())
        
        let executionCounter = ThreadSafeCounter()
        pipeline.registerHandler { (command: WorkCommand, _: CommandContext) in
            await executionCounter.increment()
            // Simulate work
            try await Task.sleep(nanoseconds: UInt64.random(in: 10_000_000...50_000_000))
            return WorkResult(workerId: command.workerId, completed: true)
        }
        
        // When - Execute many concurrent commands
        let commandCount = 100
        let start = CFAbsoluteTimeGetCurrent()
        
        let results = await withTaskGroup(of: Result<WorkResult, Error>.self) { group in
            for i in 0..<commandCount {
                group.addTask {
                    do {
                        let command = WorkCommand(workerId: "worker-\(i)")
                        let context = CommandContext.test()
                        let result = try await pipeline.execute(command, context: context)
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<WorkResult, Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        
        // Then - Verify all completed successfully
        let successCount = results.filter { if case .success = $0 { return true } else { return false } }.count
        XCTAssertEqual(successCount, commandCount, "All commands should complete successfully")
        
        let totalExecutions = await executionCounter.value
        XCTAssertEqual(totalExecutions, commandCount, "All commands should have been executed")
        
        // Verify concurrency was limited
        print("Completed \(commandCount) commands in \(duration)s")
        XCTAssertGreaterThan(duration, 0.5, "Should take time due to concurrency limits")
    }
    
    // MARK: - Error Recovery Integration Test
    
    func testErrorRecoveryIntegration() async throws {
        // Given - Pipeline with comprehensive error handling
        let pipeline = StandardPipeline()
        
        pipeline.use(PipelineKitResilience.CircuitBreakerMiddleware(
            failureThreshold: 3,
            recoveryTimeout: 0.5,
            halfOpenSuccessThreshold: 1
        ))
        pipeline.use(RetryMiddleware(maxAttempts: 3, backoffStrategy: .exponential(baseDelay: 0.1)))
        // TODO: Add when FallbackMiddleware is implemented
        // pipeline.use(FallbackMiddleware(fallbackProvider: MockFallbackProvider()))
        // TODO: Add when ErrorTransformationMiddleware is implemented
        // pipeline.use(ErrorTransformationMiddleware())
        
        var attemptCount = 0
        pipeline.registerHandler { (_: UnreliableCommand, _: CommandContext) -> String in
            attemptCount += 1
            
            // Fail first 2 attempts
            if attemptCount < 3 {
                throw ServiceError.temporaryFailure
            }
            
            return "Success after \(attemptCount) attempts"
        }
        
        // When - Execute command that initially fails
        let command = UnreliableCommand()
        let context = CommandContext.test()
        
        let result = try await pipeline.execute(command, context: context)
        
        // Then - Verify recovery
        XCTAssertEqual(result, "Success after 3 attempts")
        XCTAssertEqual(attemptCount, 3, "Should have retried")
        
        // Test circuit breaker opens after failures
        attemptCount = 0
        pipeline.registerHandler { (_: UnreliableCommand, _: CommandContext) -> String in
            throw ServiceError.permanentFailure
        }
        
        // Cause circuit to open
        for _ in 0..<3 {
            do {
                _ = try await pipeline.execute(command, context: context)
            } catch {
                // Expected failures
            }
        }
        
        // Next call should fail fast
        do {
            _ = try await pipeline.execute(command, context: context)
            XCTFail("Circuit should be open")
        } catch let error as CircuitBreakerError {
            if case .circuitOpen = error {
                // Expected
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }
    
    // MARK: - Memory Management Integration Test
    
    func testMemoryManagementIntegration() async throws {
        // Given - Pipeline with memory management
        let memoryHandler = MemoryPressureResponder()
        let objectPool = ObjectPool<DataProcessor>(
            maxSize: 20,
            factory: { DataProcessor() }
        )
        
        let pipeline = StandardPipeline()
        // TODO: Add when these middleware are implemented
        // pipeline.use(MemoryAwareMiddleware(memoryHandler: memoryHandler, pool: objectPool))
        // pipeline.use(BatchingMiddleware(batchSize: 10))
        
        pipeline.registerHandler { (command: ProcessLargeDataCommand, _: CommandContext) in
            let processor = await objectPool.acquire()
            defer {
                Task {
                    await objectPool.release(processor)
                }
            }
            
            return await processor.process(command.data)
        }
        
        // Register memory cleanup
        await memoryHandler.register {
            await objectPool.clear()
        }
        
        // When - Process many large data commands
        let commands = (0..<50).map { i in
            ProcessLargeDataCommand(data: Array(repeating: i, count: 1000))
        }
        
        var results: [ProcessedResult] = []
        for command in commands {
            let context = CommandContext.test()
            let result = try await pipeline.execute(command, context: context)
            results.append(result)
        }
        
        // Then - Verify all processed
        XCTAssertEqual(results.count, 50)
        
        // Simulate memory pressure
        await memoryHandler.simulateMemoryPressure()
        
        // Pool should have been cleared
        // Next execution should still work
        let testCommand = ProcessLargeDataCommand(data: [1, 2, 3])
        let testResult = try await pipeline.execute(testCommand, context: CommandContext.test())
        XCTAssertNotNil(testResult)
    }
    
    // MARK: - Full System Stress Test
    
    func testFullSystemStressTest() async throws {
        // Given - Complete system under stress
        let pipeline = createFullFeaturedPipeline()
        
        let metrics = SystemMetrics()
        
        // When - Simulate realistic load
        let duration: TimeInterval = 2.0 // Run for 2 seconds
        let startTime = CFAbsoluteTimeGetCurrent()
        var totalCommands = 0
        var errors = 0
        
        // Run commands for the specified duration
        while CFAbsoluteTimeGetCurrent() - startTime < duration {
            await withTaskGroup(of: Void.self) { group in
                // Generate a batch of concurrent commands
                for _ in 0..<10 {
                    group.addTask {
                        do {
                            let command = self.generateRandomCommand()
                            let context = await self.createAuthenticatedContext()
                            _ = try await pipeline.execute(command, context: context)
                            await metrics.recordSuccess()
                        } catch {
                            await metrics.recordError(error)
                        }
                    }
                    totalCommands += 1
                }
            }
            
            // Vary load
            let delay = UInt64.random(in: 1_000_000...10_000_000) // 1-10ms
            try? await Task.sleep(nanoseconds: delay)
        }
        
        // Then - Analyze results
        let report = await metrics.generateReport()
        
        print("""
        Stress Test Results:
        - Total Commands: \(report.totalRequests)
        - Successful: \(report.successCount)
        - Failed: \(report.errorCount)
        - Error Rate: \(String(format: "%.2f%%", report.errorRate * 100))
        - Throughput: \(String(format: "%.2f", report.throughput)) commands/sec
        - Average Latency: \(String(format: "%.2f", report.averageLatency * 1000))ms
        """)
        
        // Verify system remained stable
        XCTAssertLessThan(report.errorRate, 0.05, "Error rate should be less than 5%")
        XCTAssertGreaterThan(report.throughput, 100, "Should handle at least 100 commands/sec")
    }
    
    // MARK: - Helper Methods
    
    private func createFullFeaturedPipeline() -> StandardPipeline {
        let pipeline = StandardPipeline()
        
        // Add all production middleware
        pipeline.use(RequestIDMiddleware())
        pipeline.use(LoggingMiddleware())
        pipeline.use(MetricsMiddleware())
        pipeline.use(ValidationMiddleware())
        pipeline.use(SanitizationMiddleware())
        pipeline.use(AuthenticationMiddleware { token in
            guard let token = token, token.starts(with: "token-") || token == "valid-token" else {
                throw PipelineError.authorization(reason: .invalidCredentials)
            }
            return "authenticated-user"
        })
        pipeline.use(AuthorizationMiddleware { userId, permission in
            return true // Allow all for testing
        })
        pipeline.use(RateLimitingMiddleware(limiter: PipelineKitCore.RateLimiter(
            strategy: .adaptive(baseRate: 100, loadFactor: { 0.5 }),
            scope: .global
        )))
        pipeline.use(CachingMiddleware(cache: LRUCache(maxSize: 1000)))
        pipeline.use(PipelineKitResilience.CircuitBreakerMiddleware())
        pipeline.use(RetryMiddleware(maxAttempts: 3))
        pipeline.use(TimeoutMiddleware(timeout: 1.0))
        // TODO: Add when CompressionMiddleware is implemented
        // pipeline.use(CompressionMiddleware())
        // TODO: Add when these middleware are implemented
        // pipeline.use(EncryptionMiddleware(encryptionService: MockEncryptionService()))
        // pipeline.use(AuditLoggingMiddleware(logger: MockAuditLogger()))
        
        // Register handlers for different command types
        pipeline.registerHandler { (command: CreateOrderCommand, _: CommandContext) in
            Order(
                id: UUID().uuidString,
                userId: command.userId,
                items: command.items,
                total: 100.0,
                status: .created
            )
        }
        
        pipeline.registerHandler { (command: ProcessDataCommand, _: CommandContext) in
            ProcessedData(
                originalData: command.data,
                transformedData: "transformed-\(command.data)",
                enrichedData: [:],
                processingTime: Date()
            )
        }
        
        pipeline.registerHandler { (_: QueryCommand, _: CommandContext) in
            QueryResult(data: ["result": "success"], count: 1)
        }
        
        return pipeline
    }
    
    private func generateRandomCommand() -> any Command {
        let commands: [any Command] = [
            CreateOrderCommand(
                userId: "user\(Int.random(in: 1...100))",
                items: [OrderItem(productId: "prod1", quantity: 1, price: 10.0)]
            ),
            ProcessDataCommand(data: "data-\(UUID().uuidString)"),
            QueryCommand(query: "SELECT * FROM test"),
            WorkCommand(workerId: "worker-\(Int.random(in: 1...10))")
        ]
        
        return commands.randomElement() ?? CreateOrderCommand(
            userId: "default-user",
            items: [OrderItem(productId: "default", quantity: 1, price: 10.0)]
        )
    }
    
    private func createAuthenticatedContext() async -> CommandContext {
        let context = CommandContext.test()
        await context.set("user\(Int.random(in: 1...100))", for: "user_id")
        await context.set("token-\(UUID().uuidString)", for: "auth_token")
        await context.set(["read", "write", "create_order"], for: "permissions")
        return context
    }
}

// MARK: - Test Support Types

struct CreateOrderCommand: Command {
    typealias Result = Order
    
    let userId: String
    let items: [OrderItem]
}

struct Order {
    let id: String
    let userId: String
    let items: [OrderItem]
    let total: Double
    let status: OrderStatus
}

struct OrderItem {
    let productId: String
    let quantity: Int
    let price: Double
}

enum OrderStatus {
    case created, processing, completed, cancelled
}

struct ProcessDataCommand: Command {
    typealias Result = ProcessedData
    let data: String
}

struct ProcessedData: Sendable {
    let originalData: String
    let transformedData: String
    let enrichedData: [String: Any]
    let processingTime: Date
}

struct SendNotificationCommand: Command {
    typealias Result = NotificationResult
    let recipient: String
    let message: String
}

struct NotificationResult {
    let success: Bool
    let messageId: String
}

struct WorkCommand: Command {
    typealias Result = WorkResult
    let workerId: String
}

struct WorkResult {
    let workerId: String
    let completed: Bool
}

struct UnreliableCommand: Command {
    typealias Result = String
}

struct ProcessLargeDataCommand: Command {
    typealias Result = ProcessedResult
    let data: [Int]
}

struct ProcessedResult {
    let checksum: Int
}

struct QueryCommand: Command {
    typealias Result = QueryResult
    let query: String
}

struct QueryResult: Sendable {
    let data: [String: Any]
    let count: Int
}

// ServiceError is defined in ResilienceIntegrationTests.swift

// Mock implementations removed - using closures in middleware initialization instead

// Test utilities
actor ThreadSafeCounter {
    private var count = 0
    
    func increment() {
        count += 1
    }
    
    var value: Int {
        count
    }
}

actor SystemMetrics {
    private var successCount = 0
    private var errors: [Error] = []
    private var startTime = CFAbsoluteTimeGetCurrent()
    
    func recordSuccess() {
        successCount += 1
    }
    
    func recordError(_ error: Error) {
        errors.append(error)
    }
    
    func generateReport() -> MetricsReport {
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let total = successCount + errors.count
        
        return MetricsReport(
            totalRequests: total,
            successCount: successCount,
            errorCount: errors.count,
            errorRate: Double(errors.count) / Double(max(total, 1)),
            throughput: Double(total) / duration,
            averageLatency: duration / Double(max(total, 1))
        )
    }
}

struct MetricsReport {
    let totalRequests: Int
    let successCount: Int
    let errorCount: Int
    let errorRate: Double
    let throughput: Double
    let averageLatency: Double
}

// Additional middleware for testing
struct TransformationMiddleware: Middleware {
    let priority: ExecutionPriority = .processing
    
    func execute<C: Command>(
        _ command: C,
        context: CommandContext,
        next: @Sendable (C, CommandContext) async throws -> C.Result
    ) async throws -> C.Result {
        if let dataCommand = command as? ProcessDataCommand {
            await context.set(dataCommand.data.uppercased(), for: "transformed_data")
        }
        return try await next(command, context)
    }
}

struct EnrichmentMiddleware: Middleware {
    let priority: ExecutionPriority = .processing
    
    func execute<C: Command>(
        _ command: C,
        context: CommandContext,
        next: @Sendable (C, CommandContext) async throws -> C.Result
    ) async throws -> C.Result {
        await context.set([
            "timestamp": Date(),
            "source": "test-system",
            "version": "1.0"
        ], for: "enriched_data")
        return try await next(command, context)
    }
}

struct NotificationMiddleware: Middleware {
    let priority: ExecutionPriority = .processing
    
    func execute<C: Command>(
        _ command: C,
        context: CommandContext,
        next: @Sendable (C, CommandContext) async throws -> C.Result
    ) async throws -> C.Result {
        await context.set(true, for: "notification_sent")
        return try await next(command, context)
    }
}

class DataProcessor {
    func process(_ data: [Int]) async -> ProcessedResult {
        // Simulate processing
        await Task.yield()
        let checksum = data.reduce(0, +)
        return ProcessedResult(checksum: checksum)
    }
}
