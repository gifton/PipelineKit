import Foundation
import PipelineKit

/// Demonstrates resource tracking capabilities of SafetyMonitor
@main
struct ResourceTrackingDemo {
    static func main() async {
        print("=== PipelineKit Resource Tracking Demo ===\n")
        
        let monitor = DefaultSafetyMonitor()
        
        // Start leak detection
        await monitor.startLeakDetection(interval: 5) // Check every 5 seconds for demo
        
        print("1. Testing Actor Resource Tracking")
        do {
            var handles: [ResourceHandle<Never>] = []
            
            // Allocate some actors
            for i in 1...5 {
                let handle = try await monitor.allocateActor()
                handles.append(handle)
                print("  Allocated actor \(i)")
            }
            
            let usage1 = await monitor.currentResourceUsage()
            print("  Current usage: \(usage1.actors) actors")
            
            // Release some by clearing handles
            handles.removeLast(2)
            
            // Give time for cleanup
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            let usage2 = await monitor.currentResourceUsage()
            print("  After releasing 2: \(usage2.actors) actors")
            
            // Clear all
            handles.removeAll()
            try await Task.sleep(nanoseconds: 100_000_000)
            
            let usage3 = await monitor.currentResourceUsage()
            print("  After releasing all: \(usage3.actors) actors")
            
        } catch {
            print("  Error: \(error)")
        }
        
        print("\n2. Testing Task Resource Tracking")
        do {
            var taskHandles: [ResourceHandle<Never>] = []
            
            // Create many tasks to test limits
            for i in 1...20 {
                let handle = try await monitor.allocateTask()
                taskHandles.append(handle)
                if i % 5 == 0 {
                    print("  Allocated \(i) tasks")
                }
            }
            
            let usage = await monitor.currentResourceUsage()
            print("  Total tasks allocated: \(usage.tasks)")
            
            // Clear and check
            taskHandles.removeAll()
            try await Task.sleep(nanoseconds: 200_000_000)
            
            let finalUsage = await monitor.currentResourceUsage()
            print("  Tasks after cleanup: \(finalUsage.tasks)")
            
        } catch {
            print("  Error: \(error)")
        }
        
        print("\n3. Testing Leak Detection")
        do {
            // Create a "leaked" resource by allocating without storing handle
            _ = try await monitor.allocateActor()
            print("  Created an actor without storing handle (potential leak)")
            
            // Wait for leak detection
            print("  Waiting for leak detection...")
            try await Task.sleep(nanoseconds: 6_000_000_000) // 6 seconds
            
            let leaks = await monitor.detectLeaks()
            print("  Detected \(leaks.count) potential leaks")
            for leak in leaks {
                print("    - \(leak.type) (age: \(Int(leak.age))s)")
            }
            
        } catch {
            print("  Error: \(error)")
        }
        
        print("\n4. Testing File Descriptor Tracking")
        do {
            let initialUsage = await monitor.currentResourceUsage()
            print("  Initial FDs: \(initialUsage.fileDescriptors)")
            
            var fdHandles: [ResourceHandle<Never>] = []
            
            // Allocate some file descriptors
            for i in 1...10 {
                if await monitor.canOpenFileDescriptors(count: 1) {
                    let handle = try await monitor.allocateFileDescriptor()
                    fdHandles.append(handle)
                    print("  Allocated FD \(i)")
                } else {
                    print("  Cannot allocate more FDs - limit reached")
                    break
                }
            }
            
            let usage = await monitor.currentResourceUsage()
            print("  Current FDs tracked: \(usage.fileDescriptors)")
            
            // Cleanup
            fdHandles.removeAll()
            try await Task.sleep(nanoseconds: 100_000_000)
            
            let finalUsage = await monitor.currentResourceUsage()
            print("  FDs after cleanup: \(finalUsage.fileDescriptors)")
            
        } catch {
            print("  Error: \(error)")
        }
        
        print("\n5. Testing ConcurrencyStressor with Resource Tracking")
        do {
            print("  Creating concurrency stressor...")
            let stressor = ConcurrencyStressor(safetyMonitor: monitor)
            
            print("  Initial resource state:")
            let initialUsage = await monitor.currentResourceUsage()
            print("    Actors: \(initialUsage.actors), Tasks: \(initialUsage.tasks)")
            
            print("  Running actor contention test...")
            try await stressor.createActorContention(
                actorCount: 10,
                messagesPerActor: 100,
                messageSize: 1024
            )
            
            print("  After contention test:")
            let finalUsage = await monitor.currentResourceUsage()
            print("    Actors: \(finalUsage.actors), Tasks: \(finalUsage.tasks)")
            
            // Cleanup
            await stressor.stopAll()
            try await Task.sleep(nanoseconds: 500_000_000)
            
            print("  After cleanup:")
            let cleanupUsage = await monitor.currentResourceUsage()
            print("    Actors: \(cleanupUsage.actors), Tasks: \(cleanupUsage.tasks)")
            
        } catch {
            print("  Error: \(error)")
        }
        
        print("\n=== Demo Complete ===")
    }
}