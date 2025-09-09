import XCTest
@testable import PipelineKitCore

final class CancellationErrorTests: XCTestCase {
    
    // MARK: - Basic Functionality Tests
    
    func testCheckCancellationWhenNotCancelled() async throws {
        // When task is not cancelled, should not throw
        do {
            try Task.checkCancellation()
            try Task.checkCancellation(context: "test context")
            // Success - no error thrown
        } catch {
            XCTFail("Should not throw when task is not cancelled")
        }
    }
    
    func testCheckCancellationWhenCancelled() async throws {
        // Create a task that we can cancel
        let task = Task {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            // After cancellation, checkCancellation should throw
            do {
                try Task.checkCancellation()
                XCTFail("Should throw when task is cancelled")
            } catch {
                // Verify it's the correct error
                if case PipelineError.cancelled(let context) = error {
                    XCTAssertNil(context)
                } else {
                    XCTFail("Wrong error type: \(error)")
                }
            }
        }
        
        // Cancel the task
        task.cancel()
        
        // Wait for task to complete
        _ = try? await task.value
    }
    
    func testCheckCancellationWithContext() async throws {
        let testContext = "Processing user request"
        
        let task = Task {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            
            do {
                try Task.checkCancellation(context: testContext)
                XCTFail("Should throw when task is cancelled")
            } catch {
                if case PipelineError.cancelled(let context) = error {
                    XCTAssertEqual(context, testContext)
                } else {
                    XCTFail("Wrong error type: \(error)")
                }
            }
        }
        
        task.cancel()
        _ = try? await task.value
    }
    
    // MARK: - Integration Tests
    
    func testCheckCancellationInAsyncContext() async {
        let expectation = XCTestExpectation(description: "Task completes")
        
        let task = Task {
            defer { expectation.fulfill() }
            
            // Simulate some work
            for i in 0..<10 {
                // Check for cancellation periodically
                do {
                    try Task.checkCancellation(context: "Iteration \(i)")
                    
                    // Simulate work
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                } catch {
                    // Task was cancelled
                    if case PipelineError.cancelled(let context) = error {
                        XCTAssertNotNil(context)
                        XCTAssertTrue(context!.contains("Iteration"))
                        return
                    }
                }
            }
            
            XCTFail("Task should have been cancelled")
        }
        
        // Cancel after a short delay
        Task {
            try await Task.sleep(nanoseconds: 25_000_000) // 25ms
            task.cancel()
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    func testCheckCancellationMultipleTimes() async {
        let task = Task {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            
            var errorCount = 0
            
            // Check multiple times - should consistently throw
            for i in 0..<5 {
                do {
                    try Task.checkCancellation(context: "Check \(i)")
                } catch {
                    errorCount += 1
                    if case PipelineError.cancelled = error {
                        // Expected
                    } else {
                        XCTFail("Wrong error type")
                    }
                }
            }
            
            XCTAssertEqual(errorCount, 5, "Should throw every time when cancelled")
        }
        
        task.cancel()
        _ = try? await task.value
    }
    
    // MARK: - Edge Cases
    
    func testCheckCancellationWithEmptyContext() async {
        let task = Task {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            
            do {
                try Task.checkCancellation(context: "")
            } catch {
                if case PipelineError.cancelled(let context) = error {
                    XCTAssertEqual(context, "")
                } else {
                    XCTFail("Wrong error type")
                }
            }
        }
        
        task.cancel()
        _ = try? await task.value
    }
    
    func testCheckCancellationWithLongContext() async {
        let longContext = String(repeating: "a", count: 10000)
        
        let task = Task {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            
            do {
                try Task.checkCancellation(context: longContext)
            } catch {
                if case PipelineError.cancelled(let context) = error {
                    XCTAssertEqual(context?.count, 10000)
                } else {
                    XCTFail("Wrong error type")
                }
            }
        }
        
        task.cancel()
        _ = try? await task.value
    }
    
    // MARK: - Performance Tests
    
    func testCheckCancellationPerformance() async {
        // Measure performance of checking cancellation when not cancelled
        let start = Date()
        
        for _ in 0..<100000 {
            do {
                try Task.checkCancellation()
            } catch {
                XCTFail("Should not throw when not cancelled")
            }
        }
        
        let duration = Date().timeIntervalSince(start)
        print("100,000 cancellation checks in \(duration)s")
        
        // Should be very fast - just checking a flag
        XCTAssertLessThan(duration, 1.0)
    }
    
    // MARK: - Real-World Scenarios
    
    func testCancellationInLongRunningOperation() async {
        func longRunningOperation() async throws -> Int {
            var sum = 0
            
            for i in 0..<1000 {
                // Periodically check for cancellation
                if i % 100 == 0 {
                    try Task.checkCancellation(context: "Processing batch \(i/100)")
                }
                
                // Simulate work
                sum += i
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
            
            return sum
        }
        
        let task = Task {
            do {
                let result = try await longRunningOperation()
                XCTFail("Should have been cancelled, but got result: \(result)")
            } catch {
                // Cancellation may surface as our PipelineError.cancelled
                // or as Swift's native CancellationError from a suspension point (e.g., Task.sleep)
                if case PipelineError.cancelled(let context) = error {
                    XCTAssertNotNil(context)
                    XCTAssertTrue(context!.contains("Processing batch"))
                } else if error is CancellationError {
                    // Accept native cancellation as equivalent
                } else {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }
        
        // Cancel after 50ms
        Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            task.cancel()
        }
        
        _ = await task.result
    }
}
