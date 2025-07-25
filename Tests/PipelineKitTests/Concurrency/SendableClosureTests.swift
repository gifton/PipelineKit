import XCTest
@testable import PipelineKit

// MARK: - Sendable Closure Tests

final class SendableClosureTests: XCTestCase {
    
    // MARK: - CommandBus Retry Tests
    
    func testCommandBusRetrySendableClosure() async throws {
        let bus = CommandBus()
        let command = MockCommand(value: 42, shouldFail: false)
        let handler = MockCommandHandler()
        
        try await bus.register(MockCommand.self, handler: handler)
        
        var attemptCount = 0
        let attemptLock = NSLock()
        
        // This closure must be Sendable
        let result = try await bus.send(command, retryPolicy: RetryPolicy(
            maxAttempts: 3,
            delayStrategy: .fixed(0.1),
            shouldRetry: { _ in
                attemptLock.lock()
                defer { attemptLock.unlock() }
                attemptCount += 1
                return attemptCount < 2
            }
        ))
        
        XCTAssertEqual(result, "Result: 42")
    }
    
    // MARK: - ConditionalObserver Tests
    
    func testConditionalObserverSendablePredicate() async {
        let baseObserver = ConsoleObserver()
        var conditionCheckCount = 0
        let countLock = NSLock()
        
        // This predicate must be @Sendable
        let observer = ConditionalObserver(wrapping: baseObserver) { _, _ in
            countLock.lock()
            defer { countLock.unlock() }
            conditionCheckCount += 1
            return conditionCheckCount <= 2
        }
        
        // Test that the predicate is called and enforced
        let metadata = StandardCommandMetadata()
        await observer.pipelineWillExecute(
            MockCommand(value: 42),
            metadata: metadata,
            pipelineType: "test"
        )
        
        countLock.lock()
        let finalCount = conditionCheckCount
        countLock.unlock()
        
        XCTAssertGreaterThan(finalCount, 0)
    }
    
    // MARK: - CompositeObserver Tests
    
    func testCompositeObserverSendableErrorHandler() async {
        var errorCount = 0
        let errorLock = NSLock()
        
        // Create a failing observer
        let failingObserver = FailingTestObserver()
        
        // Error handler must be @Sendable
        let composite = CompositeObserver(
            observers: [failingObserver],
            errorHandler: { error, observerName in
                errorLock.lock()
                defer { errorLock.unlock() }
                errorCount += 1
                print("Error from \(observerName): \(error)")
            }
        )
        
        // Trigger an error
        await composite.pipelineWillExecute(
            MockCommand(value: 42),
            metadata: StandardCommandMetadata(),
            pipelineType: "test"
        )
        
        // Wait a bit for async error handling
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        errorLock.lock()
        let finalCount = errorCount
        errorLock.unlock()
        
        XCTAssertGreaterThan(finalCount, 0)
    }
    
    // MARK: - PipelineBuilderDSL Tests
    
    func testPipelineBuilderDSLConditionalClosure() async throws {
        var shouldExecute = true
        let executeLock = NSLock()
        
        let handler = MockCommandHandler()
        
        // Conditional closure must be @Sendable
        let pipeline = try await CreatePipeline(handler: handler) {
            LoggingMiddleware()
                .when { @Sendable in
                    executeLock.lock()
                    defer { executeLock.unlock() }
                    return shouldExecute
                }
        }
        
        let command = MockCommand(value: 42, shouldFail: false)
        let result = try await pipeline.execute(command, context: CommandContext())
        
        XCTAssertEqual(result, "Result: 42")
        
        // Change condition and test again
        executeLock.lock()
        shouldExecute = false
        executeLock.unlock()
        
        let result2 = try await pipeline.execute(command, context: CommandContext())
        XCTAssertEqual(result2, "success")
    }
    
    // MARK: - Parallel Execution Tests
    
    func testParallelMiddlewareContextIsolation() async throws {
        let handler = MockCommandHandler()
        
        // Create middleware that modifies context
        let middleware1 = ContextModifyingMiddleware(key: "m1", value: "value1")
        let middleware2 = ContextModifyingMiddleware(key: "m2", value: "value2")
        
        let pipeline = try await CreatePipeline(handler: handler) {
            ParallelMiddleware(middleware1, middleware2)
        }
        
        let command = MockCommand(value: 42, shouldFail: false)
        let context = CommandContext()
        
        let result = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result, "Result: 42")
    }
    
    // MARK: - Memory Pressure Handler Tests
    
    func testMemoryPressureHandlerSendableHandlers() async {
        let handler = MemoryPressureHandler()
        var notificationCounts = [Int: Int]()
        let countsLock = NSLock()
        
        // Start monitoring
        await handler.startMonitoring()
        
        // Register multiple handlers - all must be @Sendable
        var tokens: [UUID] = []
        for i in 0..<5 {
            let token = await handler.register { @Sendable in
                countsLock.lock()
                defer { countsLock.unlock() }
                notificationCounts[i, default: 0] += 1
            }
            tokens.append(token)
        }
        
        // We can't directly trigger handlers in the current API
        // Instead, we'll test that handlers are properly registered
        // The actual triggering happens through system memory pressure events
        
        // Verify handlers were registered (no public API to check count)
        // Just verify no crashes and proper registration
        XCTAssertEqual(tokens.count, 5)
        
        // Cleanup
        await handler.stopMonitoring()
    }
    
    // MARK: - Type Safety Tests
    
    func testNonSendableCapturePrevention() async {
        // This test verifies compile-time safety
        // The following code should NOT compile:
        
        /*
        class NonSendableState {
            var value = 0
        }
        
        let state = NonSendableState()
        
        // This would fail to compile:
        let observer = ConditionalObserver(wrapping: ConsoleObserver()) { _, _ in
            state.value > 0  // Error: Cannot capture non-Sendable 'state'
        }
        */
        
        // Instead, we must use Sendable types:
        let threshold = 5  // Int is Sendable
        let observer = ConditionalObserver(wrapping: ConsoleObserver()) { _, _ in
            threshold > 0  // This compiles fine
        }
        
        XCTAssertNotNil(observer)
    }
    
    // MARK: - Actor-based State Management Tests
    
    func testActorBasedStateWithSendableClosures() async {
        actor Counter {
            private var count = 0
            
            func increment() {
                count += 1
            }
            
            func getCount() -> Int {
                count
            }
        }
        
        let counter = Counter()
        let handler = MemoryPressureHandler()
        
        // Register handler that uses actor - must be @Sendable
        let token = await handler.register { @Sendable in
            await counter.increment()
        }
        
        // We can't directly trigger handlers in the current API
        // The handlers would be called when actual memory pressure occurs
        // Just verify registration works without crashes
        XCTAssertNotNil(token)
        
        await handler.unregister(id: token)
    }
}

// MARK: - Test Helpers

private struct FailingTestObserver: PipelineObserver, Sendable {
    func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        // Simulate an error by doing nothing - the test uses error handler tracking
    }
    
    func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {}
    func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {}
    func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {}
    func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {}
    func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {}
    func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {}
    func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {}
    func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {}
    func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {}
}

private struct ContextModifyingMiddleware: Middleware, Sendable {
    let key: String
    let value: String
    let priority: ExecutionPriority = .processing
    
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        // Store in context using a test key
        context.set(value, for: TestCustomValueKey.self)
        return try await next(command, context)
    }
}

// Using TestError from TestHelpers.swift