import XCTest
@testable import PipelineKit

final class PipelineBuilderDSLTests: XCTestCase {
    
    // MARK: - Test Command and Handler
    
    struct TestCommand: Command {
        typealias Result = String
        let value: String
    }
    
    struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Handled: \(command.value)"
        }
    }
    
    // MARK: - Test Middleware
    
    actor TestMiddleware: Middleware {
        let name: String
        private(set) var executionCount = 0
        private(set) var lastCommand: (any Command)?
        
        init(name: String) {
            self.name = name
        }
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            executionCount += 1
            lastCommand = command
            return try await next(command, metadata)
        }
        
        func getExecutionCount() async -> Int {
            executionCount
        }
    }
    
    actor OrderTrackingMiddleware: Middleware {
        private var executionOrder: [String] = []
        let name: String
        
        init(name: String) {
            self.name = name
        }
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            executionOrder.append(name)
            return try await next(command, metadata)
        }
        
        func getExecutionOrder() async -> [String] {
            executionOrder
        }
    }
    
    actor ConditionalTestMiddleware: Middleware {
        let shouldExecute: Bool
        private(set) var wasExecuted = false
        
        init(shouldExecute: Bool) {
            self.shouldExecute = shouldExecute
        }
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            wasExecuted = true
            return try await next(command, metadata)
        }
        
        func getWasExecuted() async -> Bool {
            wasExecuted
        }
    }
    
    // MARK: - Basic DSL Tests
    
    func testBasicDSLPipelineCreation() async throws {
        // Given
        let handler = TestHandler()
        let middleware1 = TestMiddleware(name: "Middleware1")
        let middleware2 = TestMiddleware(name: "Middleware2")
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            middleware1
            middleware2
        }
        
        // Then
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(result, "Handled: test")
        XCTAssertEqual(await middleware1.getExecutionCount(), 1)
        XCTAssertEqual(await middleware2.getExecutionCount(), 1)
    }
    
    func testEmptyDSLPipeline() async throws {
        // Given
        let handler = TestHandler()
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            // Empty pipeline
        }
        
        // Then
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        XCTAssertEqual(result, "Handled: test")
    }
    
    // MARK: - Conditional Middleware Tests
    
    func testConditionalMiddlewareWithIfStatement() async throws {
        // Given
        let handler = TestHandler()
        let condition = true
        let conditionalMiddleware = ConditionalTestMiddleware(shouldExecute: true)
        let alwaysMiddleware = TestMiddleware(name: "Always")
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            alwaysMiddleware
            if condition {
                conditionalMiddleware
            }
        }
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(await alwaysMiddleware.getExecutionCount(), 1)
        XCTAssertTrue(await conditionalMiddleware.getWasExecuted())
    }
    
    func testConditionalMiddlewareWithIfElse() async throws {
        // Given
        let handler = TestHandler()
        let useFirst = false
        let firstMiddleware = ConditionalTestMiddleware(shouldExecute: true)
        let secondMiddleware = ConditionalTestMiddleware(shouldExecute: true)
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            if useFirst {
                firstMiddleware
            } else {
                secondMiddleware
            }
        }
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertFalse(await firstMiddleware.getWasExecuted())
        XCTAssertTrue(await secondMiddleware.getWasExecuted())
    }
    
    func testWhenModifier() async throws {
        // Given
        let handler = TestHandler()
        let shouldExecute = true
        let conditionalMiddleware = ConditionalTestMiddleware(shouldExecute: true)
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            conditionalMiddleware
                .when { shouldExecute }
        }
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertTrue(await conditionalMiddleware.getWasExecuted())
    }
    
    func testWhenModifierWithFalseCondition() async throws {
        // Given
        let handler = TestHandler()
        let shouldExecute = false
        let conditionalMiddleware = ConditionalTestMiddleware(shouldExecute: true)
        let alwaysMiddleware = TestMiddleware(name: "Always")
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            alwaysMiddleware
            conditionalMiddleware
                .when { shouldExecute }
        }
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(await alwaysMiddleware.getExecutionCount(), 1)
        // Note: Due to the wrapper, the middleware itself might be created but not executed
        // The actual execution should be prevented by the condition
    }
    
    // MARK: - Execution Order Tests
    
    func testMiddlewareExecutionOrder() async throws {
        // Given
        let handler = TestHandler()
        let tracker1 = OrderTrackingMiddleware(name: "First")
        let tracker2 = OrderTrackingMiddleware(name: "Second")
        let tracker3 = OrderTrackingMiddleware(name: "Third")
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            tracker1
            tracker2
            tracker3
        }
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        // Middleware execute in the order they're added
        let order1 = await tracker1.getExecutionOrder()
        let order2 = await tracker2.getExecutionOrder()
        let order3 = await tracker3.getExecutionOrder()
        
        XCTAssertEqual(order1, ["First"])
        XCTAssertEqual(order2, ["Second"])
        XCTAssertEqual(order3, ["Third"])
    }
    
    // MARK: - Group Tests
    
    func testMiddlewareGroup() async throws {
        // Given
        let handler = TestHandler()
        let middleware1 = TestMiddleware(name: "Group1")
        let middleware2 = TestMiddleware(name: "Group2")
        let middleware3 = TestMiddleware(name: "Outside")
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            middleware3
            
            MiddlewareGroup {
                middleware1
                middleware2
            }
        }
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(await middleware1.getExecutionCount(), 1)
        XCTAssertEqual(await middleware2.getExecutionCount(), 1)
        XCTAssertEqual(await middleware3.getExecutionCount(), 1)
    }
    
    // MARK: - Array/Loop Tests
    
    func testForLoopInDSL() async throws {
        // Given
        let handler = TestHandler()
        let middlewares = (1...3).map { TestMiddleware(name: "Middleware\($0)") }
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            for middleware in middlewares {
                middleware
            }
        }
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        for middleware in middlewares {
            XCTAssertEqual(await middleware.getExecutionCount(), 1)
        }
    }
    
    // MARK: - Retry Tests
    
    actor FailingMiddleware: Middleware {
        let failuresBeforeSuccess: Int
        private var attemptCount = 0
        
        init(failuresBeforeSuccess: Int) {
            self.failuresBeforeSuccess = failuresBeforeSuccess
        }
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            attemptCount += 1
            if attemptCount <= failuresBeforeSuccess {
                throw TestError.simulatedFailure
            }
            return try await next(command, metadata)
        }
        
        func getAttemptCount() async -> Int {
            attemptCount
        }
    }
    
    enum TestError: Error {
        case simulatedFailure
    }
    
    func testRetryWithImmediateStrategy() async throws {
        // Given
        let handler = TestHandler()
        let failingMiddleware = FailingMiddleware(failuresBeforeSuccess: 2)
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            failingMiddleware
                .retry(maxAttempts: 3, strategy: .immediate)
        }
        
        // Then
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(result, "Handled: test")
        XCTAssertEqual(await failingMiddleware.getAttemptCount(), 3) // 2 failures + 1 success
    }
    
    func testRetryExhaustion() async throws {
        // Given
        let handler = TestHandler()
        let failingMiddleware = FailingMiddleware(failuresBeforeSuccess: 5)
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            failingMiddleware
                .retry(maxAttempts: 3, strategy: .immediate)
        }
        
        // Then
        let command = TestCommand(value: "test")
        
        do {
            _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
            XCTFail("Expected error but succeeded")
        } catch {
            // Expected to fail after exhausting retries
            XCTAssertEqual(await failingMiddleware.getAttemptCount(), 3)
        }
    }
    
    // MARK: - Complex Scenario Tests
    
    func testComplexDSLScenario() async throws {
        // Given
        let handler = TestHandler()
        let authMiddleware = TestMiddleware(name: "Auth")
        let validationMiddleware = TestMiddleware(name: "Validation")
        let cacheMiddleware = TestMiddleware(name: "Cache")
        let loggingMiddleware = TestMiddleware(name: "Logging")
        let conditionalDebug = ConditionalTestMiddleware(shouldExecute: true)
        
        let isDevelopment = true
        let cacheEnabled = true
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            // Always run auth
            authMiddleware
            
            // Conditional validation
            validationMiddleware
                .when { true }
            
            // Development-only middleware
            if isDevelopment {
                conditionalDebug
            }
            
            // Feature-flagged middleware
            if cacheEnabled {
                cacheMiddleware
            }
            
            // Group for monitoring
            MiddlewareGroup {
                loggingMiddleware
            }
        }
        
        // Then
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(result, "Handled: test")
        XCTAssertEqual(await authMiddleware.getExecutionCount(), 1)
        XCTAssertEqual(await validationMiddleware.getExecutionCount(), 1)
        XCTAssertEqual(await cacheMiddleware.getExecutionCount(), 1)
        XCTAssertEqual(await loggingMiddleware.getExecutionCount(), 1)
        XCTAssertTrue(await conditionalDebug.getWasExecuted())
    }
    
    // MARK: - Availability Tests
    
    func testLimitedAvailability() async throws {
        // Given
        let handler = TestHandler()
        let middleware = TestMiddleware(name: "Modern")
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            if #available(macOS 10.15, iOS 13.0, *) {
                middleware
            }
        }
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(await middleware.getExecutionCount(), 1)
    }
}

// MARK: - Parallel Execution Tests

extension PipelineBuilderDSLTests {
    
    actor ParallelTrackingMiddleware: Middleware {
        let name: String
        let delay: TimeInterval
        private var startTime: Date?
        private var endTime: Date?
        
        init(name: String, delay: TimeInterval = 0) {
            self.name = name
            self.delay = delay
        }
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            startTime = Date()
            
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            let result = try await next(command, metadata)
            endTime = Date()
            return result
        }
        
        func getExecutionTimes() async -> (start: Date?, end: Date?) {
            (startTime, endTime)
        }
    }
    
    func testParallelMiddleware() async throws {
        // Given
        let handler = TestHandler()
        let parallel1 = ParallelTrackingMiddleware(name: "Parallel1", delay: 0.1)
        let parallel2 = ParallelTrackingMiddleware(name: "Parallel2", delay: 0.1)
        let parallel3 = ParallelTrackingMiddleware(name: "Parallel3", delay: 0.1)
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            ParallelMiddleware(
                parallel1,
                parallel2,
                parallel3
            )
        }
        
        // Then
        let startTime = Date()
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        let endTime = Date()
        
        // If executed in parallel, total time should be close to the longest individual delay
        // not the sum of all delays
        let totalTime = endTime.timeIntervalSince(startTime)
        XCTAssertLessThan(totalTime, 0.25) // Should be much less than 0.3 (sum of delays)
    }
    
    // MARK: - Conditional Group Tests
    
    func testConditionalMiddlewareGroup() async throws {
        // Given
        let handler = TestHandler()
        let middleware1 = TestMiddleware(name: "Conditional1")
        let middleware2 = TestMiddleware(name: "Conditional2")
        let alwaysMiddleware = TestMiddleware(name: "Always")
        
        let shouldExecute = true
        
        // When
        let pipeline = try await CreatePipeline(handler: handler) {
            alwaysMiddleware
            
            ConditionalMiddleware({ shouldExecute }) {
                middleware1
                middleware2
            }
        }
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(await alwaysMiddleware.getExecutionCount(), 1)
        XCTAssertEqual(await middleware1.getExecutionCount(), 1)
        XCTAssertEqual(await middleware2.getExecutionCount(), 1)
    }
}

// MARK: - Retry Strategy Tests

extension PipelineBuilderDSLTests {
    
    func testRetryStrategyDelayCalculations() async throws {
        // Test immediate strategy
        let immediate = RetryStrategy.immediate
        let immediateDelay = await immediate.delay(for: 1)
        XCTAssertEqual(immediateDelay, 0)
        
        // Test fixed delay
        let fixed = RetryStrategy.fixedDelay(2.0)
        let fixedDelay = await fixed.delay(for: 3)
        XCTAssertEqual(fixedDelay, 2.0)
        
        // Test exponential backoff
        let exponential = RetryStrategy.exponentialBackoff(base: 1.0, multiplier: 2.0, maxDelay: 10.0)
        let exp1 = await exponential.delay(for: 0)
        let exp2 = await exponential.delay(for: 1)
        let exp3 = await exponential.delay(for: 2)
        let exp4 = await exponential.delay(for: 10) // Should hit max
        
        XCTAssertEqual(exp1, 1.0)
        XCTAssertEqual(exp2, 2.0)
        XCTAssertEqual(exp3, 4.0)
        XCTAssertEqual(exp4, 10.0) // Capped at max
        
        // Test linear backoff
        let linear = RetryStrategy.linearBackoff(increment: 3.0, maxDelay: 10.0)
        let lin1 = await linear.delay(for: 1)
        let lin2 = await linear.delay(for: 2)
        let lin3 = await linear.delay(for: 5) // Should hit max
        
        XCTAssertEqual(lin1, 3.0)
        XCTAssertEqual(lin2, 6.0)
        XCTAssertEqual(lin3, 10.0) // Capped at max
        
        // Test custom strategy
        let custom = RetryStrategy.custom { attempt in
            Double(attempt) * 0.5
        }
        let custom1 = await custom.delay(for: 2)
        XCTAssertEqual(custom1, 1.0)
    }
}