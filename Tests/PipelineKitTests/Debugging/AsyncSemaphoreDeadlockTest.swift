import XCTest
@testable import PipelineKit

// DISABLED: AsyncSemaphore debugging tests are temporarily disabled due to Swift compiler issues
// with actor method visibility in test targets. Re-enable once the compiler issue is resolved.
/*
/// Test to reproduce the deadlock with actor interaction
final class AsyncSemaphoreDeadlockTest: XCTestCase {
    private let synchronizer = TestSynchronizer()
    
    func testDeadlockScenario() async {
        print("🔍 Testing potential deadlock scenario")
        
        let semaphore = AsyncSemaphore(value: 3)
        
        // Acquire all resources
        await semaphore.wait()
        await semaphore.wait()
        await semaphore.wait()
        
        print("📝 All resources acquired, testing blocking scenario...")
        
        // This is the pattern from the failing test
        let isBlocked = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                print("🔄 Task 1: Attempting to wait (should block)...")
                await semaphore.wait()
                print("❌ Task 1: Got semaphore (shouldn't happen!)")
                return false
            }
            
            group.addTask {
                print("🔄 Task 2: Starting delay...")
                // THIS LINE CAUSES THE DEADLOCK!
                await self.synchronizer.shortDelay()
                print("✅ Task 2: Delay completed")
                return true
            }
            
            print("⏳ Waiting for first task to complete...")
            let result = await group.next()!
            print("🛑 Cancelling remaining tasks...")
            group.cancelAll()
            return result
        }
        
        print("✅ Test completed, isBlocked: \(isBlocked)")
    }
    
    func testSimplifiedDeadlock() async {
        print("🔍 Testing simplified deadlock")
        
        let semaphore = AsyncSemaphore(value: 0) // No resources available
        
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                print("🔄 Task: Waiting for semaphore...")
                await semaphore.wait() // This will block forever
                print("✅ Task: Got semaphore")
            }
            
            // Without synchronizer access, let's just wait a bit
            group.addTask {
                print("⏱️ Timer task starting...")
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                print("⏱️ Timer task done")
            }
            
            // Wait for any task - this will timeout
            if let _ = await group.next() {
                print("✅ A task completed")
            }
            
            group.cancelAll()
        }
        
        print("✅ Simplified test completed")
    }
}
*/
