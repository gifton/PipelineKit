import XCTest
@testable import PipelineKit

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
        let shouldAllow = await breaker.shouldAllow()
        
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
        let shouldAllow = await breaker.shouldAllow()
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
        let shouldAllow = await breaker.shouldAllow()
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
        _ = await breaker.shouldAllow() // Trigger transition
        
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
        _ = await breaker.shouldAllow() // Trigger transition
        
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
                    await breaker.shouldAllow()
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
            guard await breaker.shouldAllow() else {
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
    
    // MARK: - Edge Cases
    
    func testZeroFailureThreshold() async throws {
        // Given - Edge case configuration
        let breaker = CircuitBreaker(failureThreshold: 0)
        
        // When
        let shouldAllow = await breaker.shouldAllow()
        
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
        _ = await breaker.shouldAllow() // -> Half-open
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