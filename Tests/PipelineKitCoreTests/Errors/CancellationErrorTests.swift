import XCTest
import PipelineKitTestSupport
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
    
    private func assertCancelled(contexts: [String?], file: StaticString = #filePath, line: UInt = #line) async {
        let synchronizer = TestSynchronizer()
        let task = Task { () -> (reached: Bool, errors: [any Error]) in
            await synchronizer.signal("entered")
            await synchronizer.wait(for: "release")
            var errors: [any Error] = []
            for context in contexts {
                do {
                    try Task<Never, Never>.checkCancellation(context: context)
                } catch {
                    errors.append(error)
                }
            }
            return (true, errors)
        }
        await synchronizer.wait(for: "entered")
        task.cancel()
        await synchronizer.signal("release")
        let result = await task.value
        await synchronizer.reset()
        XCTAssertTrue(result.reached, file: file, line: line)
        XCTAssertEqual(result.errors.count, contexts.count, file: file, line: line)
        for (error, expected) in zip(result.errors, contexts) {
            guard case PipelineError.cancelled(let actual) = error else {
                XCTFail("Wrong error type: \(error)", file: file, line: line)
                continue
            }
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    func testCheckCancellationWhenCancelled() async {
        await assertCancelled(contexts: [nil])
    }

    func testCheckCancellationWithContext() async {
        await assertCancelled(contexts: ["Processing user request"])
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
        await assertCancelled(contexts: (0..<5).map { "Check \($0)" })
    }

    // MARK: - Edge Cases

    func testCheckCancellationWithEmptyContext() async {
        await assertCancelled(contexts: [""])
    }

    func testCheckCancellationWithLongContext() async {
        await assertCancelled(contexts: [String(repeating: "a", count: 10000)])
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
                if i.isMultiple(of: 100) {
                    try Task.checkCancellation(context: "Processing batch \(i / 100)")
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
