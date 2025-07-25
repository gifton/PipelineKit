import XCTest
@testable import PipelineKit

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
        pipeline.use(AuthenticationMiddleware(authenticator: MockAuthenticator()))
        pipeline.use(AuthorizationMiddleware(authorizer: MockAuthorizer()))
        pipeline.use(RateLimitingMiddleware(limiter: TokenBucketRateLimiter(capacity: 100, refillRate: 10)))
        pipeline.use(CachingMiddleware(cache: InMemoryCache()))
        pipeline.use(CircuitBreakerMiddleware(breaker: CircuitBreaker()))
        pipeline.use(RetryMiddleware(maxAttempts: 3))
        pipeline.use(EncryptionMiddleware(encryptionService: MockEncryptionService()))
        pipeline.use(AuditLoggingMiddleware(logger: MockAuditLogger()))
        
        // Register handler
        pipeline.registerHandler { (command: CreateOrderCommand, context: Context) in
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
        context.metadata["user_id"] = "user123"
        context.metadata["auth_token"] = "valid-token"
        context.metadata["permissions"] = ["create_order"]
        
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
        XCTAssertNotNil(context.metadata["request_id"]) // From logging
        XCTAssertNotNil(context.metrics["execution_time"]) // From metrics
        XCTAssertTrue(context.metadata["authenticated"] as? Bool ?? false) // From auth
    }
    
    // MARK: - Multi-Stage Pipeline Integration
    
    func testMultiStagePipelineIntegration() async throws {
        // Given - Complex multi-stage pipeline
        let validationPipeline = StandardPipeline()
        validationPipeline.use(ValidationMiddleware())
        validationPipeline.registerHandler { (command: any Command, context: Context) in
            context.metadata["validation_passed"] = true
            return command
        }
        
        let processingPipeline = StandardPipeline()
        processingPipeline.use(TransformationMiddleware())
        processingPipeline.use(EnrichmentMiddleware())
        processingPipeline.registerHandler { (command: ProcessDataCommand, context: Context) in
            ProcessedData(
                originalData: command.data,
                transformedData: context.metadata["transformed_data"] as? String ?? "",
                enrichedData: context.metadata["enriched_data"] as? [String: Any] ?? [:],
                processingTime: Date()
            )
        }
        
        let notificationPipeline = StandardPipeline()
        notificationPipeline.use(NotificationMiddleware())
        notificationPipeline.registerHandler { (command: SendNotificationCommand, context: Context) in
            NotificationResult(success: true, messageId: UUID().uuidString)
        }
        
        // Orchestrate stages
        let context = CommandContext.test()
        
        // Stage 1: Validation
        let dataCommand = ProcessDataCommand(data: "test-data-123")
        _ = try await validationPipeline.execute(dataCommand, context: context)
        
        guard context.metadata["validation_passed"] as? Bool == true else {
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
        let semaphore = BackPressureAsyncSemaphore(value: 10) // Limit concurrency
        
        pipeline.use(ConcurrencyLimitingMiddleware(semaphore: semaphore))
        pipeline.use(LoadBalancingMiddleware())
        pipeline.use(MetricsMiddleware())
        
        let executionCounter = ThreadSafeCounter()
        pipeline.registerHandler { (command: WorkCommand, context: Context) in
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
        
        let circuitBreaker = CircuitBreaker(failureThreshold: 3, timeout: 0.5)
        pipeline.use(CircuitBreakerMiddleware(breaker: circuitBreaker))
        pipeline.use(RetryMiddleware(maxAttempts: 3, backoffStrategy: .exponential(baseDelay: 0.1)))
        pipeline.use(FallbackMiddleware(fallbackProvider: MockFallbackProvider()))
        pipeline.use(ErrorTransformationMiddleware())
        
        var attemptCount = 0
        pipeline.registerHandler { (command: UnreliableCommand, context: Context) -> String in
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
        pipeline.registerHandler { (command: UnreliableCommand, context: Context) -> String in
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
        let memoryHandler = MemoryPressureHandler()
        let objectPool = ObjectPool<DataProcessor>(
            maxSize: 20,
            factory: { DataProcessor() }
        )
        
        let pipeline = StandardPipeline()
        pipeline.use(MemoryAwareMiddleware(memoryHandler: memoryHandler, pool: objectPool))
        pipeline.use(BatchingMiddleware(batchSize: 10))
        
        pipeline.registerHandler { (command: ProcessLargeDataCommand, context: Context) in
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
        
        await withTaskGroup(of: Void.self) { group in
            // Continuous command generation
            group.addTask {
                while CFAbsoluteTimeGetCurrent() - startTime < duration {
                    group.addTask {
                        do {
                            let command = self.generateRandomCommand()
                            let context = self.createAuthenticatedContext()
                            _ = try await pipeline.execute(command, context: context)
                            await metrics.recordSuccess()
                        } catch {
                            await metrics.recordError(error)
                        }
                    }
                    
                    totalCommands += 1
                    
                    // Vary load
                    let delay = UInt64.random(in: 1_000_000...10_000_000) // 1-10ms
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
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
        pipeline.use(AuthenticationMiddleware(authenticator: MockAuthenticator()))
        pipeline.use(AuthorizationMiddleware(authorizer: MockAuthorizer()))
        pipeline.use(RateLimitingMiddleware(limiter: AdaptiveRateLimiter()))
        pipeline.use(CachingMiddleware(cache: LRUCache(maxSize: 1000)))
        pipeline.use(CircuitBreakerMiddleware(breaker: CircuitBreaker()))
        pipeline.use(RetryMiddleware(maxAttempts: 3))
        pipeline.use(TimeoutMiddleware(timeout: 1.0))
        pipeline.use(CompressionMiddleware())
        pipeline.use(EncryptionMiddleware(encryptionService: MockEncryptionService()))
        pipeline.use(AuditLoggingMiddleware(logger: MockAuditLogger()))
        
        // Register handlers for different command types
        pipeline.registerHandler { (command: CreateOrderCommand, context: Context) in
            Order(
                id: UUID().uuidString,
                userId: command.userId,
                items: command.items,
                total: 100.0,
                status: .created
            )
        }
        
        pipeline.registerHandler { (command: ProcessDataCommand, context: Context) in
            ProcessedData(
                originalData: command.data,
                transformedData: "transformed-\(command.data)",
                enrichedData: [:],
                processingTime: Date()
            )
        }
        
        pipeline.registerHandler { (command: QueryCommand, context: Context) in
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
        
        return commands.randomElement()!
    }
    
    private func createAuthenticatedContext() -> Context {
        let context = CommandContext.test()
        context.metadata["user_id"] = "user\(Int.random(in: 1...100))"
        context.metadata["auth_token"] = "token-\(UUID().uuidString)"
        context.metadata["permissions"] = ["read", "write", "create_order"]
        return context
    }
}

// MARK: - Test Support Types

struct CreateOrderCommand: Command {
    typealias Output = Order
    
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
    typealias Output = ProcessedData
    let data: String
}

struct ProcessedData {
    let originalData: String
    let transformedData: String
    let enrichedData: [String: Any]
    let processingTime: Date
}

struct SendNotificationCommand: Command {
    typealias Output = NotificationResult
    let recipient: String
    let message: String
}

struct NotificationResult {
    let success: Bool
    let messageId: String
}

struct WorkCommand: Command {
    typealias Output = WorkResult
    let workerId: String
}

struct WorkResult {
    let workerId: String
    let completed: Bool
}

struct UnreliableCommand: Command {
    typealias Output = String
}

struct ProcessLargeDataCommand: Command {
    typealias Output = ProcessedResult
    let data: [Int]
}

struct ProcessedResult {
    let checksum: Int
}

struct QueryCommand: Command {
    typealias Output = QueryResult
    let query: String
}

struct QueryResult {
    let data: [String: Any]
    let count: Int
}

enum ServiceError: Error {
    case temporaryFailure
    case permanentFailure
}

// Mock implementations
class MockAuthenticator: Authenticator {
    func authenticate(token: String) async -> Bool {
        return token.starts(with: "token-") || token == "valid-token"
    }
}

class MockAuthorizer: Authorizer {
    func authorize(userId: String, permission: String) async -> Bool {
        return true // Allow all for testing
    }
}

class MockEncryptionService: EncryptionService {
    override func encrypt(_ data: String) async throws -> EncryptedData {
        EncryptedData(
            data: data.data(using: .utf8)!,
            keyId: "test-key",
            algorithm: "AES-256",
            metadata: [:]
        )
    }
    
    override func decrypt(_ encryptedData: EncryptedData) async throws -> String {
        String(data: encryptedData.data, encoding: .utf8) ?? ""
    }
}

class MockAuditLogger: AuditLogger {
    func log(event: AuditEvent) async {
        // Log to memory for testing
    }
}

class MockFallbackProvider: FallbackProvider {
    func getFallback<T>(for error: Error) -> T? {
        if T.self == String.self {
            return "Fallback response" as? T
        }
        return nil
    }
}

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
    func handle<C: Command>(_ command: C, context: Context, next: MiddlewareChain) async throws -> C.Output {
        if let dataCommand = command as? ProcessDataCommand {
            context.metadata["transformed_data"] = dataCommand.data.uppercased()
        }
        return try await next(command, context: context)
    }
}

struct EnrichmentMiddleware: Middleware {
    func handle<C: Command>(_ command: C, context: Context, next: MiddlewareChain) async throws -> C.Output {
        context.metadata["enriched_data"] = [
            "timestamp": Date(),
            "source": "test-system",
            "version": "1.0"
        ]
        return try await next(command, context: context)
    }
}

struct NotificationMiddleware: Middleware {
    func handle<C: Command>(_ command: C, context: Context, next: MiddlewareChain) async throws -> C.Output {
        context.metadata["notification_sent"] = true
        return try await next(command, context: context)
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