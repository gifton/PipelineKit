import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class RateLimiterTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    // MARK: - Token Bucket Tests
    
    func testTokenBucketBasicOperation() async throws {
        let limiter = RateLimiter(
            strategy: .tokenBucket(capacity: 10, refillRate: 1),
            scope: .perUser
        )
        
        // Should allow initial requests up to capacity
        for _ in 0..<10 {
            let allowed = try await limiter.allowRequest(identifier: "user1")
            XCTAssertTrue(allowed)
        }
        
        // Should deny when bucket is empty
        let denied = try await limiter.allowRequest(identifier: "user1")
        XCTAssertFalse(denied)
        
        // Different user should have their own bucket
        let allowedUser2 = try await limiter.allowRequest(identifier: "user2")
        XCTAssertTrue(allowedUser2)
    }
    
    func testTokenBucketRefill() async throws {
        let limiter = RateLimiter(
            strategy: .tokenBucket(capacity: 5, refillRate: 10), // 10 tokens per second
            scope: .perUser
        )
        
        // Consume all tokens
        for _ in 0..<5 {
            _ = try await limiter.allowRequest(identifier: "user1")
        }
        
        // Should be denied immediately
        let denied = try await limiter.allowRequest(identifier: "user1")
        XCTAssertFalse(denied)
        
        // Wait for refill
        await synchronizer.mediumDelay() // Simulate time for token replenishment
        
        // Should allow 2 requests after refill
        let allowed1 = try await limiter.allowRequest(identifier: "user1")
        XCTAssertTrue(allowed1)
        let allowed2 = try await limiter.allowRequest(identifier: "user1")
        XCTAssertTrue(allowed2)
        let denied2 = try await limiter.allowRequest(identifier: "user1")
        XCTAssertFalse(denied2)
    }
    
    func testTokenBucketWithCost() async throws {
        let limiter = RateLimiter(
            strategy: .tokenBucket(capacity: 10, refillRate: 1),
            scope: .perUser
        )
        
        // Request with cost 5
        let allowed1 = try await limiter.allowRequest(identifier: "user1", cost: 5)
        XCTAssertTrue(allowed1)
        
        // Request with cost 5 (total would be 10)
        let allowed2 = try await limiter.allowRequest(identifier: "user1", cost: 5)
        XCTAssertTrue(allowed2)
        
        // Any further request should be denied
        let denied = try await limiter.allowRequest(identifier: "user1", cost: 1)
        XCTAssertFalse(denied)
    }
    
    // MARK: - Sliding Window Tests
    
    func testSlidingWindowBasicOperation() async throws {
        let limiter = RateLimiter(
            strategy: .slidingWindow(windowSize: 1.0, maxRequests: 3),
            scope: .perUser
        )
        
        // Should allow up to maxRequests
        for _ in 0..<3 {
            let allowed = try await limiter.allowRequest(identifier: "user1")
            XCTAssertTrue(allowed)
        }
        
        // Should deny when limit reached
        let denied = try await limiter.allowRequest(identifier: "user1")
        XCTAssertFalse(denied)
    }
    
    func testSlidingWindowReset() async throws {
        let limiter = RateLimiter(
            strategy: .slidingWindow(windowSize: 0.5, maxRequests: 2),
            scope: .perUser
        )
        
        // Use up the limit
        _ = try await limiter.allowRequest(identifier: "user1")
        _ = try await limiter.allowRequest(identifier: "user1")
        
        // Should be denied
        let denied = try await limiter.allowRequest(identifier: "user1")
        XCTAssertFalse(denied)
        
        // Wait for window to pass
        await synchronizer.longDelay() // Simulate longer wait for reset
        
        // Should allow new requests
        let allowed = try await limiter.allowRequest(identifier: "user1")
        XCTAssertTrue(allowed)
    }
    
    // MARK: - Adaptive Rate Limiting Tests
    
    func testAdaptiveRateLimiting() async throws {
        let loadActor = LoadActor()
        
        let limiter = RateLimiter(
            strategy: .adaptive(
                baseRate: 10,
                loadFactor: { await loadActor.getLoad() }
            ),
            scope: .global
        )
        
        // With load 0.0, capacity should be 20 (10 * (2.0 - 0.0))
        await loadActor.setLoad(0.0)
        var allowedCount = 0
        for _ in 0..<25 {
            if try await limiter.allowRequest(identifier: "global") {
                allowedCount += 1
            }
        }
        XCTAssertEqual(allowedCount, 20)
        
        // Reset limiter
        await limiter.reset()
        
        // With load 0.5, capacity should be 15 (10 * (2.0 - 0.5))
        await loadActor.setLoad(0.5)
        allowedCount = 0
        for _ in 0..<20 {
            if try await limiter.allowRequest(identifier: "global") {
                allowedCount += 1
            }
        }
        XCTAssertEqual(allowedCount, 15)
        
        // Reset limiter
        await limiter.reset()
        
        // With load 1.0, capacity should be 10 (10 * (2.0 - 1.0))
        await loadActor.setLoad(1.0)
        allowedCount = 0
        for _ in 0..<15 {
            if try await limiter.allowRequest(identifier: "global") {
                allowedCount += 1
            }
        }
        XCTAssertEqual(allowedCount, 10)
    }
    
    // MARK: - Rate Limit Status Tests
    
    func testRateLimitStatus() async throws {
        let limiter = RateLimiter(
            strategy: .tokenBucket(capacity: 10, refillRate: 1),
            scope: .perUser
        )
        
        // Initial status
        let initialStatus = await limiter.getStatus(identifier: "user1")
        XCTAssertEqual(initialStatus.remaining, 10)
        XCTAssertEqual(initialStatus.limit, 10)
        
        // After some requests
        for _ in 0..<3 {
            _ = try await limiter.allowRequest(identifier: "user1")
        }
        
        let afterStatus = await limiter.getStatus(identifier: "user1")
        XCTAssertEqual(afterStatus.remaining, 7)
        XCTAssertEqual(afterStatus.limit, 10)
    }
    
    // MARK: - Rate Limiting Middleware Tests
    
    func testRateLimitingMiddleware() async throws {
        let limiter = RateLimiter(
            strategy: .tokenBucket(capacity: 5, refillRate: 1),
            scope: .perUser
        )
        
        let middleware = RateLimitingMiddleware(limiter: limiter)
        
        let command = TestCommand(value: "test")
        let context = await CommandContext.test(userId: "user1")
        
        // Should allow up to capacity
        for i in 0..<5 {
            let result = try await middleware.execute(command, context: context) { cmd, _ in
                "\(cmd.value)-\(i)"
            }
            XCTAssertEqual(result, "test-\(i)")
        }
        
        // Should throw rate limit error
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                "should not reach"
            }
            XCTFail("Expected rate limit error")
        } catch let error as PipelineError {
            if case .rateLimitExceeded(_, _, _) = error {
                // Expected
            } else {
                XCTFail("Expected rate limit error, got \(error)")
            }
        }
    }
    
    func testRateLimitingMiddlewareWithCostCalculator() async throws {
        let limiter = RateLimiter(
            strategy: .tokenBucket(capacity: 10, refillRate: 1),
            scope: .perCommand
        )
        
        let middleware = RateLimitingMiddleware(
            limiter: limiter,
            identifierExtractor: { command, _ in
                String(describing: type(of: command))
            },
            costCalculator: { command in
                if command is ExpensiveCommand {
                    return 5.0
                }
                return 1.0
            }
        )
        
        let cheapCommand = TestCommand(value: "cheap")
        let expensiveCommand = ExpensiveCommand()
        
        // Should allow 10 cheap commands
        let context = CommandContext.test()
        for _ in 0..<10 {
            _ = try await middleware.execute(cheapCommand, context: context) { _, _ in "ok" }
        }
        
        // Should deny next cheap command
        do {
            _ = try await middleware.execute(cheapCommand, context: context) { _, _ in "fail" }
            XCTFail("Expected rate limit")
        } catch is PipelineError {
            // Expected
        }
        
        // Reset for expensive command test
        await limiter.reset()
        
        // Should allow only 2 expensive commands (cost 5 each)
        for _ in 0..<2 {
            _ = try await middleware.execute(expensiveCommand, context: context) { _, _ in print("ok") }
        }
        
        // Should deny next expensive command
        do {
            _ = try await middleware.execute(expensiveCommand, context: context) { _, _ in print("fail") }
            XCTFail("Expected rate limit")
        } catch is PipelineError {
            // Expected
        }
    }
    
    // MARK: - Circuit Breaker Tests
    
    func testCircuitBreakerBasicOperation() async throws {
        let breaker = CircuitBreaker(
            failureThreshold: 3,
            successThreshold: 2,
            timeout: 0.5,
            resetTimeout: 1.0
        )
        
        // Initially closed
        let state1 = await breaker.getState()
        if case .closed = state1 {} else {
            XCTFail("Expected closed state")
        }
        let shouldAllow1 = await breaker.shouldAllow()
        XCTAssertTrue(shouldAllow1)
        
        // Record failures
        await breaker.recordFailure()
        await breaker.recordFailure()
        let shouldAllow2 = await breaker.shouldAllow()
        XCTAssertTrue(shouldAllow2) // Still closed
        
        // Third failure opens the circuit
        await breaker.recordFailure()
        let state2 = await breaker.getState()
        if case .open = state2 {} else {
            XCTFail("Expected open state")
        }
        let shouldAllow3 = await breaker.shouldAllow()
        XCTAssertFalse(shouldAllow3)
        
        // Wait for timeout
        await synchronizer.longDelay() // Simulate longer wait for reset
        
        // Should be half-open
        let shouldAllow4 = await breaker.shouldAllow()
        XCTAssertTrue(shouldAllow4)
        let state3 = await breaker.getState()
        if case .halfOpen = state3 {} else {
            XCTFail("Expected half-open state")
        }
        
        // Success in half-open
        await breaker.recordSuccess()
        await breaker.recordSuccess()
        
        // Should be closed again
        let state4 = await breaker.getState()
        if case .closed = state4 {} else {
            XCTFail("Expected closed state")
        }
    }
    
    func testCircuitBreakerHalfOpenFailure() async throws {
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            timeout: 0.3
        )
        
        // Open the circuit
        await breaker.recordFailure()
        await breaker.recordFailure()
        let shouldAllow5 = await breaker.shouldAllow()
        XCTAssertFalse(shouldAllow5)
        
        // Wait for half-open
        await synchronizer.mediumDelay() // Simulate token regeneration
        let shouldAllow6 = await breaker.shouldAllow()
        XCTAssertTrue(shouldAllow6)
        
        // Failure in half-open should re-open
        await breaker.recordFailure()
        let shouldAllow7 = await breaker.shouldAllow()
        XCTAssertFalse(shouldAllow7)
        
        let state = await breaker.getState()
        if case .open = state {} else {
            XCTFail("Expected open state after half-open failure")
        }
    }
    
    // MARK: - Test Helpers
    
    struct TestCommand: Command {
        let value: String
        typealias Result = String
        
        func execute() async throws -> String {
            return value
        }
    }
    
    struct ExpensiveCommand: Command {
        typealias Result = Void
        
        func execute() async throws -> Void {
            return ()
        }
    }
    
    actor LoadActor {
        private var load: Double = 0.0
        
        func setLoad(_ newLoad: Double) {
            load = newLoad
        }
        
        func getLoad() -> Double {
            load
        }
    }
}
