import XCTest
@testable import PipelineKit
import PipelineKitCore

/// Tests for SimpleSemaphore cancellation behavior.
/// 
/// These tests verify that SimpleSemaphore properly handles task cancellation
/// by resuming continuations with CancellationError rather than leaving them
/// suspended indefinitely.
final class SimpleSemaphoreCancellationTests: XCTestCase {
    
    // MARK: - Basic Cancellation Tests
    
    func testCancelledTaskThrowsCancellationError() async throws {
        let semaphore = SimpleSemaphore(permits: 1)
        
        // Acquire the only permit
        let token1 = try await semaphore.acquire()
        
        // Start a task that will wait for a permit
        let task = Task {
            try await semaphore.acquire()
        }
        
        // Give the task time to start waiting
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Cancel the waiting task
        task.cancel()
        
        // The task should throw CancellationError
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError but task succeeded")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError but got \(error)")
        }
        
        // Clean up
        token1.release()
    }
    
    func testCancellationDoesNotAffectOtherWaiters() async throws {
        let semaphore = SimpleSemaphore(permits: 1)
        
        // Acquire the only permit
        let token1 = try await semaphore.acquire()
        
        // Start multiple waiting tasks
        let cancelledTask = Task {
            try await semaphore.acquire()
        }
        
        let normalTask = Task {
            try await semaphore.acquire()
        }
        
        // Give tasks time to start waiting
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Cancel one task
        cancelledTask.cancel()
        
        // Verify cancelled task throws
        do {
            _ = try await cancelledTask.value
            XCTFail("Cancelled task should have thrown")
        } catch is CancellationError {
            // Expected
        }
        
        // Release the permit
        token1.release()
        
        // The normal task should succeed
        let token2 = try await normalTask.value
        XCTAssertNotNil(token2)
        token2.release()
    }
    
    func testMultipleConcurrentCancellations() async throws {
        let semaphore = SimpleSemaphore(permits: 1)
        
        // Acquire the only permit
        let token1 = try await semaphore.acquire()
        
        // Create many waiting tasks
        let tasks = (0..<10).map { _ in
            Task {
                try await semaphore.acquire()
            }
        }
        
        // Give tasks time to start waiting
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Cancel all tasks
        for task in tasks {
            task.cancel()
        }
        
        // All tasks should throw CancellationError
        for task in tasks {
            do {
                _ = try await task.value
                XCTFail("Cancelled task should have thrown")
            } catch is CancellationError {
                // Expected
            }
        }
        
        // Release the permit
        token1.release()
        
        // Semaphore should still be usable
        let token2 = try await semaphore.acquire()
        XCTAssertNotNil(token2)
        token2.release()
    }
    
    // MARK: - Edge Case Tests
    
    func testCancellationDuringRelease() async throws {
        let semaphore = SimpleSemaphore(permits: 1)
        
        // Acquire the permit
        let token1 = try await semaphore.acquire()
        
        // Start a waiting task
        let task = Task {
            try await semaphore.acquire()
        }
        
        // Give task time to start waiting
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Cancel and release simultaneously
        task.cancel()
        token1.release()
        
        // Task should throw CancellationError
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
        
        // The permit should be available again
        let token2 = try await semaphore.acquire()
        XCTAssertNotNil(token2)
        token2.release()
    }
    
    func testImmediateCancellation() async throws {
        let semaphore = SimpleSemaphore(permits: 1)
        
        // Acquire the permit first
        let token = try await semaphore.acquire()
        
        // Start and immediately cancel a task
        let task = Task {
            try await semaphore.acquire()
        }
        task.cancel()
        
        // Task should throw CancellationError
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
        
        token.release()
    }
    
    func testCancellationWithMultiplePermits() async throws {
        let semaphore = SimpleSemaphore(permits: 3)
        
        // Acquire all permits
        let tokens = try await withThrowingTaskGroup(of: SemaphoreToken.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await semaphore.acquire()
                }
            }
            
            var tokens: [SemaphoreToken] = []
            for try await token in group {
                tokens.append(token)
            }
            return tokens
        }
        
        // Create waiting tasks
        let waitingTasks = (0..<5).map { _ in
            Task {
                try await semaphore.acquire()
            }
        }
        
        // Give tasks time to start waiting
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Cancel some tasks
        waitingTasks[0].cancel()
        waitingTasks[2].cancel()
        waitingTasks[4].cancel()
        
        // Release all permits
        for token in tokens {
            token.release()
        }
        
        // Check cancelled tasks threw errors
        for i in [0, 2, 4] {
            do {
                _ = try await waitingTasks[i].value
                XCTFail("Task \(i) should have thrown CancellationError")
            } catch is CancellationError {
                // Expected
            }
        }
        
        // Check non-cancelled tasks succeeded
        for i in [1, 3] {
            let token = try await waitingTasks[i].value
            XCTAssertNotNil(token)
            token.release()
        }
    }
    
    // MARK: - Resource Consistency Tests
    
    func testPermitCountAfterCancellation() async throws {
        let semaphore = SimpleSemaphore(permits: 2)
        
        // Acquire both permits
        let token1 = try await semaphore.acquire()
        let token2 = try await semaphore.acquire()
        
        let availablePermits = await semaphore.availablePermits
        XCTAssertEqual(availablePermits, 0)
        
        // Create and cancel waiting tasks
        let tasks = (0..<5).map { _ in
            Task {
                try await semaphore.acquire()
            }
        }
        
        // Give tasks time to queue
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Cancel all tasks
        for task in tasks {
            task.cancel()
        }
        
        // Wait for cancellations to process
        for task in tasks {
            _ = try? await task.value
        }
        
        // Release permits
        token1.release()
        token2.release()
        
        // Give time for releases to process
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // All permits should be available again
        let finalPermits = await semaphore.availablePermits
        XCTAssertEqual(finalPermits, 2)
    }
    
    func testWaitingCountAfterCancellation() async throws {
        let semaphore = SimpleSemaphore(permits: 1)
        
        // Acquire the permit
        let token = try await semaphore.acquire()
        
        // Create waiting tasks
        let tasks = (0..<3).map { _ in
            Task {
                try await semaphore.acquire()
            }
        }
        
        // Give tasks time to queue
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Should have 3 waiters
        let waitingCount = await semaphore.waitingCount
        XCTAssertEqual(waitingCount, 3)
        
        // Cancel all tasks
        for task in tasks {
            task.cancel()
        }
        
        // Wait for cancellations to process
        for task in tasks {
            _ = try? await task.value
        }
        
        // Give time for cancellation to fully process
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // No waiters should remain
        let finalWaitingCount = await semaphore.waitingCount
        XCTAssertEqual(finalWaitingCount, 0)
        
        token.release()
    }
    
    // MARK: - Integration Tests
    
    func testCancellationInPipelineScenario() async throws {
        let semaphore = SimpleSemaphore(permits: 2)
        
        // Simulate a pipeline with limited concurrency
        let pipeline = { (id: Int) -> Task<Int?, Error> in
            Task {
                do {
                    let token = try await semaphore.acquire()
                    defer { token.release() }
                    
                    // Simulate work
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    return id * 2
                } catch is CancellationError {
                    return nil
                }
            }
        }
        
        // Start multiple pipeline tasks
        let tasks = (0..<5).map { pipeline($0) }
        
        // Cancel some tasks
        tasks[1].cancel()
        tasks[3].cancel()
        
        // Collect results
        let results = await withTaskGroup(of: Int?.self) { group in
            for task in tasks {
                group.addTask {
                    try? await task.value
                }
            }
            
            var results: [Int?] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        // Verify some tasks completed and some were cancelled
        let nonNilCount = results.compactMap { $0 }.count
        XCTAssertGreaterThan(nonNilCount, 0)
        XCTAssertLessThan(nonNilCount, 5)
    }
}