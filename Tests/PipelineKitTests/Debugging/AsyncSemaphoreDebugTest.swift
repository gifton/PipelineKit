// DISABLED: AsyncSemaphore debugging tests are temporarily disabled due to Swift compiler issues
// with actor method visibility in test targets. Re-enable once the compiler issue is resolved.
/*
import XCTest
@testable import PipelineKit

/// Debug test to understand the deadlock
final class AsyncSemaphoreDebugTest: XCTestCase {
    
    func testSimpleBlocking() async {
        print("🔍 Testing simple blocking behavior")
        
        let semaphore = AsyncSemaphore(value: 0) // No resources
        var taskCompleted = false
        
        // Start a task that will block
        let blockingTask = Task {
            print("📝 Task starting wait...")
            await semaphore.wait()
            print("✅ Task got semaphore!")
            taskCompleted = true
        }
        
        // Give it time to start
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        print("🔄 Checking if task is blocked...")
        XCTAssertFalse(taskCompleted, "Task should be blocked")
        
        print("📢 Signaling semaphore...")
        await semaphore.signal()
        
        // Give it time to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        print("✅ Checking if task completed...")
        XCTAssertTrue(taskCompleted, "Task should complete after signal")
        
        blockingTask.cancel()
    }
    
    func testTaskGroupWithoutActor() async {
        print("🔍 Testing TaskGroup without actor interaction")
        
        let semaphore = AsyncSemaphore(value: 3)
        
        // Acquire all resources
        await semaphore.wait()
        await semaphore.wait()
        await semaphore.wait()
        
        print("📝 All resources acquired")
        
        let result = await withTaskGroup(of: String.self) { group in
            group.addTask {
                print("🔄 Task 1: Attempting to wait...")
                await semaphore.wait()
                print("❌ Task 1: Got semaphore (shouldn't happen!)")
                return "task1-completed"
            }
            
            group.addTask {
                print("⏱️ Task 2: Waiting 200ms...")
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                print("✅ Task 2: Wait completed")
                return "task2-completed"
            }
            
            // Wait for first completion
            if let first = await group.next() {
                print("📊 First completed: \(first)")
                group.cancelAll()
                return first
            }
            
            return "none"
        }
        
        print("✅ Result: \(result)")
        XCTAssertEqual(result, "task2-completed", "Task 2 should complete first")
        
        // Clean up
        await semaphore.signal()
        await semaphore.signal()
        await semaphore.signal()
    }
    
    func testIsolatedActorAccess() async {
        print("🔍 Testing isolated actor access")
        
        let synchronizer = TestSynchronizer()
        
        // Just test that we can access the actor
        print("📝 Accessing synchronizer...")
        await synchronizer.shortDelay()
        print("✅ Synchronizer access completed")
    }
}
*/