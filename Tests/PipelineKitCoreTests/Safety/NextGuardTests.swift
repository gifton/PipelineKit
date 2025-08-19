import XCTest
@testable import PipelineKitCore
import Atomics

final class NextGuardTests: XCTestCase {
    
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
        
        func execute() async throws -> String {
            return value
        }
    }
    
    // MARK: - Basic Functionality Tests
    
    func testSingleExecutionSucceeds() async throws {
        // Given
        let expectation = XCTestExpectation(description: "next called")
        let nextGuard = NextGuard<TestCommand>({ command, _ in
            expectation.fulfill()
            return command.value + "-processed"
        })
        
        // When
        let command = TestCommand(value: "test")
        let context = CommandContext()
        let result = try await nextGuard(command, context)
        
        // Then
        XCTAssertEqual(result, "test-processed")
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    func testMultipleCallsThrowError() async throws {
        // Given
        let nextGuard = NextGuard<TestCommand>({ command, _ in
            return command.value
        })
        
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        // When - First call succeeds
        _ = try await nextGuard(command, context)
        
        // Then - Second call throws
        do {
            _ = try await nextGuard(command, context)
            XCTFail("Should have thrown nextAlreadyCalled")
        } catch let error as PipelineError {
            if case .nextAlreadyCalled = error {
                // Success
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }
    
    func testConcurrentCallsThrowError() async throws {
        // Given
        let nextGuard = NextGuard<TestCommand>({ command, _ in
            // Simulate slow operation
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            return command.value
        })
        
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        // When - Start two concurrent calls
        async let result1 = nextGuard(command, context)
        async let result2 = nextGuard(command, context)
        
        // Then - One succeeds, one fails
        var successCount = 0
        var errorCount = 0
        
        do {
            _ = try await result1
            successCount += 1
        } catch {
            errorCount += 1
            XCTAssertTrue(error is PipelineError)
        }
        
        do {
            _ = try await result2
            successCount += 1
        } catch {
            errorCount += 1
            XCTAssertTrue(error is PipelineError)
        }
        
        XCTAssertEqual(successCount, 1, "Exactly one call should succeed")
        XCTAssertEqual(errorCount, 1, "Exactly one call should fail")
    }
    
    // MARK: - Cancellation Tests
    
    func testCancellationHandling() async throws {
        // Given
        let nextGuard = NextGuard<TestCommand>({ command, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            return command.value
        })
        
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        // When
        let task = Task {
            try await nextGuard(command, context)
        }
        
        // Give it time to start
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Cancel the task
        task.cancel()
        
        // Then - Should throw CancellationError
        do {
            _ = try await task.value
            XCTFail("Should have been cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        
        // Verify guard is in completed state even after cancellation
        XCTAssertTrue(nextGuard.hasCompleted || nextGuard.hasBeenCalled)
    }
    
    func testStateTransitionsCorrectly() async throws {
        // Given
        let semaphore = AsyncSemaphore(value: 0)
        
        let nextGuard = NextGuard<TestCommand>({ command, _ in
            await semaphore.wait()
            return command.value
        })
        
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        // Initial state
        XCTAssertEqual(nextGuard.currentState, "pending")
        XCTAssertFalse(nextGuard.hasBeenCalled)
        XCTAssertFalse(nextGuard.hasCompleted)
        
        // Start execution
        let task = Task {
            try await nextGuard(command, context)
        }
        
        // Give it time to transition to executing
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Should be executing
        XCTAssertEqual(nextGuard.currentState, "executing")
        XCTAssertTrue(nextGuard.hasBeenCalled)
        XCTAssertFalse(nextGuard.hasCompleted)
        
        // Let it complete
        await semaphore.signal()
        _ = try await task.value
        
        // Should be completed
        XCTAssertEqual(nextGuard.currentState, "completed")
        XCTAssertTrue(nextGuard.hasBeenCalled)
        XCTAssertTrue(nextGuard.hasCompleted)
    }
    
    // MARK: - Stress Tests
    
    func testHighConcurrencyStress() async throws {
        let iterations = 10_000
        let nextGuard = NextGuard<TestCommand>({ command, _ in
            return command.value
        })
        
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        // Launch many concurrent attempts
        let results = await withTaskGroup(of: Result<String, Error>.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    do {
                        return .success(try await nextGuard(command, context))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var outcomes: [Result<String, Error>] = []
            for await result in group {
                outcomes.append(result)
            }
            return outcomes
        }
        
        // Exactly one should succeed
        let successes = results.filter { if case .success = $0 { return true } else { return false } }
        let failures = results.filter { if case .failure = $0 { return true } else { return false } }
        
        XCTAssertEqual(successes.count, 1, "Exactly one call should succeed")
        XCTAssertEqual(failures.count, iterations - 1, "All other calls should fail")
        
        // All failures should be the correct error type
        for case .failure(let error) in failures {
            XCTAssertTrue(error is PipelineError)
        }
    }
    
    func testAlternateExecuteMethod() async throws {
        // Given
        let nextGuard = NextGuard<TestCommand>({ command, _ in
            return command.value + "-executed"
        })
        
        // When
        let command = TestCommand(value: "test")
        let context = CommandContext()
        let result = try await nextGuard.execute(command, context: context)
        
        // Then
        XCTAssertEqual(result, "test-executed")
    }
    
    // MARK: - Error Message Tests
    
    func testErrorMessagesAreDescriptive() async throws {
        // Test nextAlreadyCalled message
        let nextGuard = NextGuard<TestCommand>({ command, _ in command.value })
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        _ = try await nextGuard(command, context)
        
        do {
            _ = try await nextGuard(command, context)
            XCTFail("Should throw")
        } catch let error as PipelineError {
            let description = error.errorDescription ?? ""
            XCTAssertTrue(description.contains("multiple times"))
            XCTAssertTrue(description.contains("exactly once"))
        }
    }
    
    #if DEBUG
    func testDebugAssertionOnMissingCall() async throws {
        // This test verifies that the debug assertion is present
        // We can't actually test assertionFailure in XCTest
        // So we just verify the guard can be created with an identifier
        
        // Create a guard with identifier for debugging
        let nextGuard = NextGuard<TestCommand>({ _, _ in "unused" }, identifier: "test-guard")
        
        // We must call it to avoid the assertion
        let command = TestCommand(value: "test")
        let context = CommandContext()
        _ = try await nextGuard.callAsFunction(command, context)
        
        // The assertion is there in deinit, but we can't test it directly
        // without causing a crash
    }
    #endif
}

// MARK: - Helper Types

private actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(value: Int) {
        self.value = value
    }
    
    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            value += 1
        }
    }
}