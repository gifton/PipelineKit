import XCTest
@testable import PipelineKitResilience
@testable import PipelineKitCore
import PipelineKitTestSupport

final class CircuitBreakerTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    // MARK: - State Transition Tests
    
    func testInitialStateIsClosed() async throws {
        // Given
        let breaker = CircuitBreaker()
        
        // When
        let state = await breaker.getState()
        
        // Then
        if case .closed = state {
            // Expected
        } else {
            XCTFail("Initial state should be closed, got \(state)")
        }
    }
    
    func testAllowsRequestsWhenClosed() async throws {
        // Given
        let breaker = CircuitBreaker()
        
        // When
        let shouldAllow = await breaker.allowRequest()
        
        // Then
        XCTAssertTrue(shouldAllow, "Should allow requests when closed")
    }
    
    func testOpensAfterFailureThreshold() async throws {
        // Given
        let failureThreshold = 3
        let breaker = CircuitBreaker(failureThreshold: failureThreshold)
        
        // When - Record failures up to threshold
        for i in 0..<failureThreshold {
            await breaker.recordFailure()
            
            if i < failureThreshold - 1 {
                // Should still be closed before threshold
                let state = await breaker.getState()
                if case .closed = state {
                    // Expected
                } else {
                    XCTFail("Should remain closed until threshold reached")
                }
            }
        }
        
        // Then - Should be open after threshold
        let finalState = await breaker.getState()
        if case .open = finalState {
            // Expected
        } else {
            XCTFail("Should be open after failure threshold, got \(finalState)")
        }
    }
    
    func testDoesNotAllowRequestsWhenOpen() async throws {
        // Given
        let breaker = CircuitBreaker(failureThreshold: 1, timeout: 60.0)
        
        // When - Force open state
        await breaker.recordFailure()
        
        // Then
        let shouldAllow = await breaker.allowRequest()
        XCTAssertFalse(shouldAllow, "Should not allow requests when open")
    }
    
    func testTransitionsToHalfOpenAfterTimeout() async throws {
        // Given
        let timeout: TimeInterval = 0.1 // Short timeout for testing
        let breaker = CircuitBreaker(failureThreshold: 1, timeout: timeout)
        let synchronizer = TestSynchronizer()
        
        // When - Open the breaker
        await breaker.recordFailure()
        
        // Create a task to check state after timeout
        Task {
            // Wait slightly longer than timeout
            await self.synchronizer.mediumDelay()
            await synchronizer.signal("timeout-elapsed")
        }
        
        // Wait for timeout to elapse
        await synchronizer.wait(for: "timeout-elapsed")
        
        // Then - Should transition to half-open
        let shouldAllow = await breaker.allowRequest()
        XCTAssertTrue(shouldAllow, "Should allow request after timeout (half-open state)")
        
        let state = await breaker.getState()
        if case .halfOpen = state {
            // Expected
        } else {
            XCTFail("Should be half-open after timeout, got \(state)")
        }
    }
    
    func testClosesAfterSuccessThresholdInHalfOpen() async throws {
        // Given
        let successThreshold = 2
        let timeout: TimeInterval = 0.1
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: successThreshold,
            timeout: timeout
        )
        
        // Open the breaker
        await breaker.recordFailure()
        
        // Wait for timeout to transition to half-open
        await synchronizer.mediumDelay()
        _ = await breaker.allowRequest() // Trigger transition
        
        // When - Record successes in half-open state
        for i in 0..<successThreshold {
            await breaker.recordSuccess()
            
            if i < successThreshold - 1 {
                // Should still be half-open
                let state = await breaker.getState()
                if case .halfOpen = state {
                    // Expected
                } else {
                    XCTFail("Should remain half-open until success threshold")
                }
            }
        }
        
        // Then - Should be closed after success threshold
        let finalState = await breaker.getState()
        if case .closed = finalState {
            // Expected
        } else {
            XCTFail("Should be closed after success threshold, got \(finalState)")
        }
    }
    
    func testReOpensOnFailureInHalfOpen() async throws {
        // Given
        let timeout: TimeInterval = 0.1
        let breaker = CircuitBreaker(failureThreshold: 1, timeout: timeout)
        
        // Open the breaker
        await breaker.recordFailure()
        
        // Wait for timeout to transition to half-open
        await synchronizer.mediumDelay()
        _ = await breaker.allowRequest() // Trigger transition
        
        // Verify half-open
        let halfOpenState = await breaker.getState()
        if case .halfOpen = halfOpenState {
            // Expected
        } else {
            XCTFail("Should be half-open before test")
        }
        
        // When - Record failure in half-open state
        await breaker.recordFailure()
        
        // Then - Should be open again
        let finalState = await breaker.getState()
        if case .open = finalState {
            // Expected
        } else {
            XCTFail("Should re-open on failure in half-open state, got \(finalState)")
        }
    }
    
    // MARK: - Success Recording Tests
    
    func testSuccessResetsFailureCountWhenClosed() async throws {
        // Given
        let breaker = CircuitBreaker(failureThreshold: 3)
        
        // Record some failures (but not enough to open)
        await breaker.recordFailure()
        await breaker.recordFailure()
        
        // When - Record success
        await breaker.recordSuccess()
        
        // Then - Next failure should not open breaker
        await breaker.recordFailure()
        await breaker.recordFailure()
        
        let state = await breaker.getState()
        if case .closed = state {
            // Expected - failure count was reset
        } else {
            XCTFail("Should remain closed after success reset failure count")
        }
    }
    
    func testSuccessIgnoredWhenOpen() async throws {
        // Given
        let breaker = CircuitBreaker(failureThreshold: 1)
        await breaker.recordFailure() // Open it
        
        // When - Record success while open
        await breaker.recordSuccess()
        
        // Then - Should remain open
        let state = await breaker.getState()
        if case .open = state {
            // Expected
        } else {
            XCTFail("Success should be ignored when open")
        }
    }
    
    // MARK: - Configuration Tests
    
    func testCustomFailureThreshold() async throws {
        // Given
        let customThreshold = 5
        let breaker = CircuitBreaker(failureThreshold: customThreshold)
        
        // When - Record failures less than threshold
        for _ in 0..<(customThreshold - 1) {
            await breaker.recordFailure()
        }
        
        // Then - Should still be closed
        var state = await breaker.getState()
        if case .closed = state {
            // Expected
        } else {
            XCTFail("Should remain closed below threshold")
        }
        
        // When - Reach threshold
        await breaker.recordFailure()
        
        // Then - Should open
        state = await breaker.getState()
        if case .open = state {
            // Expected
        } else {
            XCTFail("Should open at threshold")
        }
    }
    
    func testDefaultConfiguration() async throws {
        // Given - Default breaker
        let breaker = CircuitBreaker()
        
        // When - Record default threshold failures (5)
        for _ in 0..<4 {
            await breaker.recordFailure()
        }
        
        // Should still be closed
        var state = await breaker.getState()
        if case .closed = state {
            // Expected
        } else {
            XCTFail("Default threshold should be 5")
        }
        
        // One more to hit default threshold
        await breaker.recordFailure()
        
        // Should now be open
        state = await breaker.getState()
        if case .open = state {
            // Expected
        } else {
            XCTFail("Should open at default threshold of 5")
        }
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentFailureRecording() async throws {
        // Given
        let breaker = CircuitBreaker(failureThreshold: 10)
        let concurrentTasks = 20
        
        // When - Record failures concurrently
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrentTasks {
                group.addTask {
                    await breaker.recordFailure()
                }
            }
        }
        
        // Then - Should be open
        let state = await breaker.getState()
        if case .open = state {
            // Expected
        } else {
            XCTFail("Should handle concurrent failures correctly")
        }
    }
    
    func testConcurrentStateChecks() async throws {
        // Given
        let breaker = CircuitBreaker(failureThreshold: 1)
        let checkCount = 100
        
        // When - Check state concurrently while modifying
        await withTaskGroup(of: Bool.self) { group in
            // Add failure recording task
            group.addTask {
                await breaker.recordFailure()
                return true
            }
            
            // Add many concurrent state checks
            for _ in 0..<checkCount {
                group.addTask {
                    await breaker.allowRequest()
                }
            }
            
            // Collect results
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            
            // Should have consistent results
            XCTAssertEqual(results.count, checkCount + 1)
        }
    }
    
    // MARK: - Integration Pattern Tests
    
    func testCircuitBreakerPattern() async throws {
        // Given
        let breaker = CircuitBreaker(failureThreshold: 2, timeout: 0.1)
        var executionCount = 0
        var failureCount = 0
        
        // Simulated operation that fails initially then succeeds
        func performOperation() async throws -> String {
            executionCount += 1
            
            if executionCount <= 3 {
                failureCount += 1
                throw TestError.operationFailed
            }
            return "Success"
        }
        
        // When - Use circuit breaker pattern
        for attempt in 0..<10 {
            guard await breaker.allowRequest() else {
                continue // Circuit open, skip
            }
            
            do {
                let result = try await performOperation()
                await breaker.recordSuccess()
                XCTAssertEqual(result, "Success")
                break
            } catch {
                await breaker.recordFailure()
                
                // After 2 failures, circuit should open
                if attempt >= 1 {
                    let state = await breaker.getState()
                    if case .open = state {
                        // Wait for timeout
                        await self.synchronizer.mediumDelay()
                    }
                }
            }
        }
        
        // Then - Should eventually succeed
        XCTAssertGreaterThan(executionCount, failureCount)
    }
    
    // MARK: - Probe Window Tests
    
    func testHalfOpenAllowsOnlyOneProbeRequest() async throws {
        // Given
        let breaker = CircuitBreaker(failureThreshold: 1, timeout: 0.1)
        
        // Open the breaker
        await breaker.recordFailure()
        
        // Wait for timeout to transition to half-open
        await synchronizer.longDelay()  // Use longer delay to ensure timeout has passed
        
        // Verify we're in half-open state by checking state first
        let state = await breaker.getState()
        if case .halfOpen = state {
            // Expected
        } else {
            XCTFail("Should be in half-open state, but got \(state)")
        }
        
        // When - Multiple concurrent requests in half-open state
        let requestCount = 10
        var allowedCount = 0
        
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<requestCount {
                group.addTask {
                    await breaker.allowRequest()
                }
            }
            
            for await allowed in group {
                if allowed {
                    allowedCount += 1
                }
            }
        }
        
        // Then - Only one request should be allowed through
        XCTAssertEqual(allowedCount, 1, "Only one probe request should be allowed in half-open state")
    }
    
    func testProbeWindowResetsAfterSuccess() async throws {
        // Given
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 2,
            timeout: 0.1
        )
        
        // Open the breaker
        await breaker.recordFailure()
        await synchronizer.longDelay()
        
        // When - First probe succeeds
        let firstProbe = await breaker.allowRequest()
        XCTAssertTrue(firstProbe, "First probe should be allowed")
        await breaker.recordSuccess()
        
        // Then - Another probe should be allowed
        let secondProbe = await breaker.allowRequest()
        XCTAssertTrue(secondProbe, "Second probe should be allowed after success")
        
        // And state should still be half-open
        let state = await breaker.getState()
        if case .halfOpen = state {
            // Expected
        } else {
            XCTFail("Should remain half-open until success threshold reached")
        }
    }
    
    func testProbeWindowResetsAfterFailure() async throws {
        // Given
        let breaker = CircuitBreaker(failureThreshold: 1, timeout: 0.1)
        
        // Open the breaker
        await breaker.recordFailure()
        await synchronizer.longDelay()
        
        // When - First probe fails
        let firstProbe = await breaker.allowRequest()
        XCTAssertTrue(firstProbe, "First probe should be allowed")
        await breaker.recordFailure()
        
        // Then - Circuit should re-open
        let state = await breaker.getState()
        if case .open = state {
            // Expected
        } else {
            XCTFail("Should re-open after probe failure")
        }
        
        // And no more requests should be allowed until next timeout
        let afterFailure = await breaker.allowRequest()
        XCTAssertFalse(afterFailure, "No requests should be allowed after probe failure")
    }
    
    func testConcurrentProbesWithMixedResults() async throws {
        // Given
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 2,
            timeout: 0.1
        )
        
        // Open the breaker
        await breaker.recordFailure()
        await synchronizer.longDelay()
        
        // When - Race condition: concurrent probe + result recording
        await withTaskGroup(of: Void.self) { group in
            // Multiple threads trying to get probe
            for i in 0..<5 {
                group.addTask {
                    let allowed = await breaker.allowRequest()
                    if allowed {
                        // Simulate some succeeding, some failing
                        if i % 2 == 0 {
                            await breaker.recordSuccess()
                        } else {
                            await breaker.recordFailure()
                        }
                    }
                }
            }
        }
        
        // Then - State should be consistent (either open or half-open)
        let finalState = await breaker.getState()
        switch finalState {
        case .open, .halfOpen:
            // Both are valid outcomes depending on race condition resolution
            break
        case .closed:
            XCTFail("Should not transition to closed without reaching success threshold")
        }
    }
    
    // MARK: - Reset Timeout Tests
    
    func testResetTimeoutResetsFailureCount() async throws {
        // Given
        let resetTimeout: TimeInterval = 0.1
        let breaker = CircuitBreaker(
            failureThreshold: 3,
            resetTimeout: resetTimeout
        )
        
        // Record some failures (but not enough to open)
        await breaker.recordFailure()
        await breaker.recordFailure()
        
        // Wait for reset timeout
        await synchronizer.longDelay()  // Longer than reset timeout
        
        // When - Record another failure after reset timeout
        await breaker.recordFailure()
        
        // Then - Circuit should still be closed (failure count was reset)
        let state = await breaker.getState()
        if case .closed = state {
            // Expected
        } else {
            XCTFail("Should remain closed after reset timeout, got \(state)")
        }
        
        // And it should take 3 more failures to open (confirming reset)
        await breaker.recordFailure()
        await breaker.recordFailure()
        
        // Should now be open
        let finalState = await breaker.getState()
        if case .open = finalState {
            // Expected
        } else {
            XCTFail("Should be open after reaching threshold post-reset")
        }
    }
    
    func testIntermittentFailuresWithResetTimeout() async throws {
        // Given
        let resetTimeout: TimeInterval = 0.05
        let breaker = CircuitBreaker(
            failureThreshold: 2,
            resetTimeout: resetTimeout
        )
        
        // When - Intermittent failures with delays
        await breaker.recordFailure()
        await synchronizer.mediumDelay()  // 50ms - at the edge of reset timeout
        await breaker.recordFailure()
        
        // Then - Should still be closed (just at threshold)
        var state = await breaker.getState()
        if case .closed = state {
            // Expected
        } else {
            XCTFail("Should still be closed at threshold")
        }
        
        // One more failure should open it
        await breaker.recordFailure()
        state = await breaker.getState()
        if case .open = state {
            // Expected
        } else {
            XCTFail("Should be open after exceeding threshold")
        }
    }
    
    // MARK: - Edge Cases
    
    func testZeroFailureThreshold() async throws {
        // Given - Edge case configuration
        let breaker = CircuitBreaker(failureThreshold: 0)
        
        // When
        let shouldAllow = await breaker.allowRequest()
        
        // Then - Should handle gracefully
        XCTAssertTrue(shouldAllow, "Zero threshold should not break functionality")
    }
    
    func testRapidStateTransitions() async throws {
        // Given
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 1,
            timeout: 0.05
        )
        
        // When - Rapid transitions
        await breaker.recordFailure() // -> Open
        await synchronizer.shortDelay()
        _ = await breaker.allowRequest() // -> Half-open
        await breaker.recordSuccess() // -> Closed
        await breaker.recordFailure() // -> Open again
        
        // Then
        let finalState = await breaker.getState()
        if case .open = finalState {
            // Expected
        } else {
            XCTFail("Should handle rapid transitions correctly")
        }
    }
    
    // MARK: - Helper Types
    
    private enum TestError: Error {
        case operationFailed
    }
}

// MARK: - Test Extensions

extension CircuitBreakerTests {
    /// Helper to wait for state without using Task.sleep
    func waitForState(_ expectedState: CircuitBreaker.State, in breaker: CircuitBreaker, timeout: TimeInterval = 1.0) async throws {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            let currentState = await breaker.getState()
            
            switch (currentState, expectedState) {
            case (.closed, .closed), (.halfOpen, .halfOpen):
                return
            case (.open(let until), .open):
                if Date() < until {
                    return
                }
            default:
                // Continue waiting
                await Task.yield()
            }
        }
        
        XCTFail("Timeout waiting for state \(expectedState)")
    }
}
