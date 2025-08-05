import XCTest
@testable import PipelineKit
import PipelineKitTestSupport
import PipelineKitTestSupport

// Test counter actor
actor ResilientTestCounter {
    private var value: Int
    
    init(_ value: Int = 0) {
        self.value = value
    }
    
    func increment() {
        value += 1
    }
    
    func get() -> Int {
        value
    }
}

// Test times tracking actor
actor TestTimesActor {
    private var times: [Date] = []
    
    func recordAttempt() {
        times.append(Date())
    }
    
    func getTimes() -> [Date] {
        times
    }
}

final class ResilientMiddlewareTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    func testSuccessfulExecutionWithoutRetry() async throws {
        // Given
        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: RetryPolicy(maxAttempts: 3)
        )
        
        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()
        
        var executionCount = 0
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            executionCount += 1
            return cmd.value
        }
        
        // Then
        XCTAssertEqual(result, "test")
        XCTAssertEqual(executionCount, 1) // Should not retry on success
    }
    
    func testRetryOnTransientFailure() async throws {
        // Given
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            delayStrategy: .fixed(0.01), // 10ms delay
            shouldRetry: { error in
                error is TransientError
            }
        )
        
        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: retryPolicy
        )
        
        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()
        
        let attemptTracker = ResilientTestCounter(0)
        
        // When
        let result = try await middleware.execute(command, context: context) { _, _ in
            await attemptTracker.increment()
            let count = await attemptTracker.get()
            
            if count < 3 {
                throw TransientError.temporaryFailure
            }
            
            return "success-\(count)"
        }
        
        // Then
        XCTAssertEqual(result, "success-3")
        let finalCount = await attemptTracker.get()
        XCTAssertEqual(finalCount, 3) // Should retry twice before succeeding
    }
    
    func testRetryExhaustion() async throws {
        // Given
        let retryPolicy = RetryPolicy(
            maxAttempts: 2,
            delayStrategy: .fixed(0.01)
        )
        
        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: retryPolicy
        )
        
        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()
        
        let attemptTracker = ResilientTestCounter(0)
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                await attemptTracker.increment()
                throw TransientError.temporaryFailure
            }
            XCTFail("Should throw after retry exhaustion")
        } catch {
            XCTAssertTrue(error is TransientError)
            let finalCount = await attemptTracker.get()
            XCTAssertEqual(finalCount, 2) // Should attempt maxAttempts times
        }
    }
    
    func testNoRetryOnNonRetriableError() async throws {
        // Given
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            shouldRetry: { error in
                !(error is PermanentError)
            }
        )
        
        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: retryPolicy
        )
        
        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()
        
        let attemptTracker = ResilientTestCounter(0)
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                await attemptTracker.increment()
                throw PermanentError.unrecoverable
            }
            XCTFail("Should throw permanent error")
        } catch {
            XCTAssertTrue(error is PermanentError)
            let finalCount = await attemptTracker.get()
            XCTAssertEqual(finalCount, 1) // Should not retry
        }
    }
    
    func testCircuitBreakerOpen() async throws {
        // Given
        let circuitBreaker = CircuitBreaker(
            failureThreshold: 2,
            successThreshold: 1,
            timeout: 60,
            resetTimeout: 1
        )
        
        // Force circuit breaker open
        await circuitBreaker.recordFailure()
        await circuitBreaker.recordFailure()
        
        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: .default,
            circuitBreaker: circuitBreaker
        )
        
        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                XCTFail("Should not execute with open circuit")
                return cmd.value
            }
            XCTFail("Should throw circuit open error")
        } catch let error as PipelineError {
            if case .resilience(let reason) = error,
               case .circuitBreakerOpen = reason {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    func testCircuitBreakerRecovery() async throws {
        // Given
        let circuitBreaker = CircuitBreaker(
            failureThreshold: 2,
            successThreshold: 1,
            timeout: 0.1, // 100ms timeout for open->half-open transition
            resetTimeout: 60
        )
        
        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: RetryPolicy(maxAttempts: 1),
            circuitBreaker: circuitBreaker
        )
        
        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()
        
        // Trip the circuit
        for _ in 0..<2 {
            do {
                _ = try await middleware.execute(command, context: context) { _, _ in
                    throw TransientError.temporaryFailure
                }
            } catch {
                // Expected failures
            }
        }
        
        // Circuit should be open
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Should not execute")
                return ""
            }
            XCTFail("Should throw circuit open")
        } catch {
            if let pipelineError = error as? PipelineError,
               case .resilience = pipelineError {
                // Expected
            } else {
                XCTFail("Expected resilience error")
            }
        }
        
        // Wait for reset timeout (with some buffer)
        // Circuit breaker timeout is 100ms, so we need to wait at least that long
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        
        // Circuit should be half-open, allowing one attempt
        let result = try await middleware.execute(command, context: context) { _, _ in
            "recovered"
        }
        
        XCTAssertEqual(result, "recovered")
    }
    
    func testExponentialBackoffRetry() async throws {
        // Given
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            delayStrategy: .exponentialBackoff(base: 0.01, multiplier: 2.0, maxDelay: 0.1)
        )
        
        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: retryPolicy
        )
        
        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()
        
        let attemptTimesActor = TestTimesActor()
        let attemptTracker = ResilientTestCounter(0)
        
        // When
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                await attemptTracker.increment()
                await attemptTimesActor.recordAttempt()
                throw TransientError.temporaryFailure
            }
        } catch {
            // Expected
        }
        
        // Then
        let finalCount = await attemptTracker.get()
        XCTAssertEqual(finalCount, 3)
        let attemptTimes = await attemptTimesActor.getTimes()
        XCTAssertEqual(attemptTimes.count, 3)
        
        // Verify exponential delays (with some tolerance)
        if attemptTimes.count >= 3 {
            let delay1 = attemptTimes[1].timeIntervalSince(attemptTimes[0])
            let delay2 = attemptTimes[2].timeIntervalSince(attemptTimes[1])
            
            // First retry after ~10ms
            XCTAssertGreaterThan(delay1, 0.009)
            XCTAssertLessThan(delay1, 0.02)
            
            // Second retry after ~20ms (2x multiplier)
            XCTAssertGreaterThan(delay2, 0.018)
            XCTAssertLessThan(delay2, 0.03)
        }
    }
    
    func testObservabilityEvents() async throws {
        // Given
        let eventCollector = TestEventCollector()
        let observerRegistry = ObserverRegistry(observers: [eventCollector])
        
        let middleware = ResilientMiddleware(
            name: "test-middleware",
            retryPolicy: RetryPolicy(maxAttempts: 2)
        )
        
        let command = ResilientTestCommand(value: "test")
        let metadata = TestCommandMetadata(userId: "user-123")
        let context = CommandContext(metadata: metadata)
        await context.setObserverRegistry(observerRegistry)
        
        let attemptTracker = ResilientTestCounter(0)
        
        // When - Fail once then succeed
        let result = try await middleware.execute(command, context: context) { _, _ in
            await attemptTracker.increment()
            let count = await attemptTracker.get()
            
            if count == 1 {
                throw TransientError.temporaryFailure
            }
            
            return "success"
        }
        
        // Then
        XCTAssertEqual(result, "success")
        
        // Verify events were emitted
        await eventCollector.waitForEvents(count: 2) // retry.failed and retry.attempt
        
        let events = await eventCollector.getEvents()
        
        // Should have retry failed event
        let failedEvent = events.first { $0.name == "resilience.retry.failed" }
        XCTAssertNotNil(failedEvent)
        XCTAssertEqual(failedEvent?.properties["middleware"] as? String, "test-middleware")
        XCTAssertEqual(failedEvent?.properties["attempt"] as? Int, 1)
        XCTAssertEqual(failedEvent?.properties["userId"] as? String, "user-123")
        
        // Should have retry attempt event
        let attemptEvent = events.first { $0.name == "resilience.retry.attempt" }
        XCTAssertNotNil(attemptEvent)
        XCTAssertEqual(attemptEvent?.properties["attempt"] as? Int, 2)
    }
}

// Test support types
private struct ResilientTestCommand: Command {
    typealias Result = String
    let value: String
    
    func execute() async throws -> String {
        return value
    }
}

private enum TransientError: Error {
    case temporaryFailure
}

private enum PermanentError: Error {
    case unrecoverable
}

private actor TestEventCollector: PipelineObserver {
    private var events: [(name: String, properties: [String: Sendable])] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    
    func getEvents() -> [(name: String, properties: [String: Sendable])] {
        events
    }
    
    func waitForEvents(count: Int) async {
        while events.count < count {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }
    
    private func notifyWaiters() {
        let waiters = continuations
        continuations.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }
    
    // PipelineObserver conformance
    func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {}
    func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {}
    func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {}
    func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {}
    func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {}
    func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {}
    func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {}
    func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {}
    func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {}
    
    func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        events.append((name: eventName, properties: properties))
        notifyWaiters()
    }
}
