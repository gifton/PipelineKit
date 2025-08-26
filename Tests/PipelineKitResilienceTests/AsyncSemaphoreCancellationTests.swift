import XCTest
@testable import PipelineKitResilience
import PipelineKitTestSupport

/// Tests specifically for AsyncSemaphore cancellation behavior
/// These tests verify the fix for the critical bug where cancelling one task
/// would release ALL waiting tasks.
final class AsyncSemaphoreCancellationTests: XCTestCase {
    // MARK: - Single Task Cancellation
    
    func testSingleTaskCancellationDoesNotAffectOthers() async throws {
        // Given: A semaphore with 1 resource
        let semaphore = AsyncSemaphore(value: 1)
        let task1Started = TestCounter()
        let task1Completed = TestCounter()
        let task2Completed = TestCounter()
        let task3Completed = TestCounter()
        
        // Task 1: Acquire and hold the resource
        let holder = Task {
            try? await semaphore.wait()
            await task1Started.increment()
            // Hold for a while
            try? await Task.sleep(for: .seconds(1))
            await task1Completed.increment()
            await semaphore.signal()
        }
        
        // Wait for task 1 to acquire
        try? await Task.sleep(for: .milliseconds(50))
        let started = await task1Started.get()
        XCTAssertEqual(started, 1, "Task 1 should have acquired the resource")
        
        // Task 2: Wait but then cancel
        let cancelledTask = Task {
            do {
                try await semaphore.wait()
                await task2Completed.increment()
            } catch {
                // Expected cancellation
            }
        }
        
        // Task 3: Should wait and eventually succeed
        let waitingTask = Task {
            do {
                try await semaphore.wait()
                await task3Completed.increment()
                await semaphore.signal()
            } catch {
                XCTFail("Task 3 should not be cancelled")
            }
        }
        
        // Give tasks time to start waiting
        try? await Task.sleep(for: .milliseconds(50))
        
        // Cancel ONLY task 2
        cancelledTask.cancel()
        
        // Wait for everything to complete
        await holder.value
        await waitingTask.value
        _ = await cancelledTask.result
        
        // Verify results
        let task2Count = await task2Completed.get()
        let task3Count = await task3Completed.get()
        
        XCTAssertEqual(task2Count, 0, "Task 2 should have been cancelled and not completed")
        XCTAssertEqual(task3Count, 1, "Task 3 should have completed successfully")
    }
    
    // MARK: - Resource Restoration
    
    func testResourceRestorationOnCancellation() async throws {
        // Given: A semaphore with 2 resources
        let semaphore = AsyncSemaphore(value: 2)
        
        // Check initial resources
        let initialResources = await semaphore.availableResourcesCount()
        XCTAssertEqual(initialResources, 2)
        
        // Acquire both resources
        try? await semaphore.wait()
        try? await semaphore.wait()
        
        let afterAcquire = await semaphore.availableResourcesCount()
        XCTAssertEqual(afterAcquire, 0)
        
        // Start a task that will wait and then be cancelled
        let waitingTask = Task {
            try await semaphore.wait()
        }
        
        // Give it time to start waiting
        try? await Task.sleep(for: .milliseconds(50))
        
        // Cancel the waiting task
        waitingTask.cancel()
        _ = await waitingTask.result
        
        // Small delay to ensure cancellation is processed
        try? await Task.sleep(for: .milliseconds(50))
        
        // Resources should still be 0 (cancellation doesn't create new resources)
        let afterCancel = await semaphore.availableResourcesCount()
        XCTAssertEqual(afterCancel, 0, "Cancellation should not create phantom resources")
        
        // Release one resource
        await semaphore.signal()
        
        // Should have 1 available resource
        let afterSignal = await semaphore.availableResourcesCount()
        XCTAssertEqual(afterSignal, 1, "Should have 1 resource available")
        
        // Should be able to acquire it
        try? await semaphore.wait()
        let afterReacquire = await semaphore.availableResourcesCount()
        XCTAssertEqual(afterReacquire, 0, "Resource should be acquired")
    }
    
    // MARK: - FIFO Ordering with Cancellation
    
    func testFIFOOrderingMaintainedWithCancellation() async throws {
        // Given: A semaphore with 1 resource
        let semaphore = AsyncSemaphore(value: 1)
        let executionOrder = ExecutionOrderTracker()
        
        // Task 0: Hold the resource initially
        let holder = Task {
            try? await semaphore.wait()
            try? await Task.sleep(for: .milliseconds(200))
            await semaphore.signal()
        }
        
        // Wait for holder to acquire
        try? await Task.sleep(for: .milliseconds(50))
        
        // Start tasks in order
        let task1 = Task {
            try await semaphore.wait()
            await executionOrder.recordExecution("task1")
            await semaphore.signal()
        }
        
        try? await Task.sleep(for: .milliseconds(10))
        
        let task2 = Task {
            try await semaphore.wait()
            await executionOrder.recordExecution("task2")
            await semaphore.signal()
        }
        
        try? await Task.sleep(for: .milliseconds(10))
        
        let task3 = Task {
            try await semaphore.wait()
            await executionOrder.recordExecution("task3")
            await semaphore.signal()
        }
        
        try? await Task.sleep(for: .milliseconds(10))
        
        // Cancel task2 (middle of the queue)
        task2.cancel()
        
        // Wait for all to complete
        await holder.value
        _ = await task1.result
        _ = await task2.result
        _ = await task3.result
        
        // Check execution order
        let order = await executionOrder.getExecutionOrder()
        
        // Task1 and Task3 should execute in order, Task2 should not execute
        XCTAssertEqual(order, ["task1", "task3"], "FIFO order should be maintained, skipping cancelled task")
    }
    
    // MARK: - Concurrent Cancellations
    
    func testConcurrentCancellations() async throws {
        // Given: A semaphore with 1 resource
        let semaphore = AsyncSemaphore(value: 1)
        let completedCount = TestCounter()
        let cancelledCount = TestCounter()
        
        // Hold the resource
        let holder = Task {
            try? await semaphore.wait()
            try? await Task.sleep(for: .milliseconds(300))
            await semaphore.signal()
        }
        
        // Wait for holder to acquire
        try? await Task.sleep(for: .milliseconds(50))
        
        // Create many waiting tasks
        var tasks: [Task<Void, Never>] = []
        for i in 0..<20 {
            let task = Task {
                do {
                    try await semaphore.wait()
                    await completedCount.increment()
                    await semaphore.signal()
                } catch {
                    _ = await cancelledCount.increment()
                }
            }
            tasks.append(task)
            
            // Cancel every other task
            if i % 2 == 1 {
                task.cancel()
            }
        }
        
        // Wait for holder to release
        await holder.value
        
        // Wait for all tasks
        for task in tasks {
            await task.value
        }
        
        // Verify counts
        let completed = await completedCount.get()
        let cancelled = await cancelledCount.get()
        
        XCTAssertEqual(completed, 10, "10 tasks should complete")
        XCTAssertEqual(cancelled, 10, "10 tasks should be cancelled")
        
        // Verify semaphore is still functional
        let finalResources = await semaphore.availableResourcesCount()
        XCTAssertEqual(finalResources, 1, "Semaphore should have 1 resource available")
    }
    
    // MARK: - Edge Cases
    
    func testCancellationDuringSignal() async throws {
        // Given: A semaphore with 0 resources
        let semaphore = AsyncSemaphore(value: 0)
        
        // Start a waiting task
        let waitingTask = Task {
            try await semaphore.wait()
        }
        
        // Give it time to start waiting
        try? await Task.sleep(for: .milliseconds(50))
        
        // Signal and immediately cancel
        await semaphore.signal()
        waitingTask.cancel()
        
        // Task should complete (signal wins over cancellation)
        do {
            try await waitingTask.value
            // Success - signal was processed before cancellation
        } catch {
            // Also acceptable - cancellation was processed first
        }
        
        // Semaphore should be in consistent state
        let resources = await semaphore.availableResourcesCount()
        XCTAssertGreaterThanOrEqual(resources, 0, "Resources should not be negative")
        XCTAssertLessThanOrEqual(resources, 1, "Resources should not exceed maximum")
    }
    
    func testRapidCancellations() async throws {
        // Given: A semaphore with 1 resource
        let semaphore = AsyncSemaphore(value: 1)
        
        // Acquire the resource
        try? await semaphore.wait()
        
        // Rapidly create and cancel tasks
        for _ in 0..<100 {
            let task = Task {
                try await semaphore.wait()
            }
            task.cancel()
            _ = await task.result
        }
        
        // Release the resource
        await semaphore.signal()
        
        // Semaphore should still be functional
        let canAcquire = await semaphore.acquire(timeout: 0.1)
        XCTAssertTrue(canAcquire, "Should be able to acquire resource")
        
        await semaphore.signal()
        
        // Verify final state
        let finalResources = await semaphore.availableResourcesCount()
        XCTAssertEqual(finalResources, 1, "Should have exactly 1 resource")
    }
}
