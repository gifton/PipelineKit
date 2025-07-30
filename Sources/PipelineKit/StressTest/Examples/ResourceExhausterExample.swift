import Foundation

/// Example usage of the new ResourceExhauster API.
///
/// This example demonstrates how to use the clean ResourceExhauster API
/// to exhaust various system resources in a controlled manner.
public struct ResourceExhausterExample {
    
    public static func runExamples() async throws {
        let safetyMonitor = DefaultSafetyMonitor()
        let exhauster = ResourceExhauster(safetyMonitor: safetyMonitor)
        
        print("=== ResourceExhauster Examples ===\n")
        
        // Example 1: Exhaust file descriptors by count
        print("Example 1: Exhausting 100 file descriptors...")
        let fdRequest = ExhaustionRequest(
            resource: .fileDescriptors,
            amount: .count(100),
            duration: 2.0
        )
        
        let fdResult = try await exhauster.exhaust(fdRequest)
        print("Result: Allocated \(fdResult.actualCount) of \(fdResult.requestedCount) file descriptors")
        print("Status: \(fdResult.status), Duration: \(fdResult.duration)s\n")
        
        // Example 2: Exhaust memory mappings by percentage
        print("Example 2: Exhausting 10% of available memory mappings...")
        let memRequest = ExhaustionRequest(
            resource: .memoryMappings,
            amount: .percentage(0.1),
            duration: 1.0
        )
        
        let memResult = try await exhauster.exhaust(memRequest)
        print("Result: Allocated \(memResult.actualCount) of \(memResult.requestedCount) memory mappings")
        print("Peak usage: \(memResult.peakUsage)%, Status: \(memResult.status)\n")
        
        // Example 3: Exhaust disk space by bytes
        print("Example 3: Exhausting 50MB of disk space...")
        let diskRequest = ExhaustionRequest(
            resource: .diskSpace,
            amount: .absolute(50),  // 50 files (disk space is tracked by file count)
            duration: 1.5
        )
        
        let diskResult = try await exhauster.exhaust(diskRequest)
        print("Result: Created \(diskResult.actualCount) resources")
        print("Status: \(diskResult.status), Duration: \(diskResult.duration)s\n")
        
        // Example 4: Exhaust multiple resources simultaneously
        print("Example 4: Exhausting multiple resources...")
        let requests = [
            ExhaustionRequest(resource: .fileDescriptors, amount: .absolute(50), duration: 3.0),
            ExhaustionRequest(resource: .networkSockets, amount: .absolute(30), duration: 3.0),
            ExhaustionRequest(resource: .threads, amount: .absolute(10), duration: 3.0)
        ]
        
        let multiResults = try await exhauster.exhaustMultiple(requests)
        print("Results:")
        for result in multiResults {
            print("  - \(result.resource): \(result.actualCount)/\(result.requestedCount) allocated")
        }
        
        // Check current stats
        let stats = await exhauster.currentStats()
        print("\nCurrent Stats:")
        print("  - Active allocations: \(stats.activeAllocations)")
        print("  - Resources by type: \(stats.resourcesByType)")
        print("  - Current state: \(stats.currentState)")
        
        // Clean up
        await exhauster.stopAll()
        print("\nAll resources released.")
    }
    
    // Example: Custom resource exhaustion pattern
    public static func customPattern() async throws {
        let safetyMonitor = DefaultSafetyMonitor()
        let exhauster = ResourceExhauster(safetyMonitor: safetyMonitor)
        
        print("=== Custom Resource Exhaustion Pattern ===\n")
        
        // Gradually increase resource usage
        for percentage in stride(from: 0.1, through: 0.5, by: 0.1) {
            print("Exhausting \(Int(percentage * 100))% of file descriptors...")
            
            let request = ExhaustionRequest(
                resource: .fileDescriptors,
                amount: .percentage(percentage),
                duration: 0.5
            )
            
            do {
                let result = try await exhauster.exhaust(request)
                print("  - Allocated: \(result.actualCount)")
                print("  - Duration: \(String(format: "%.2f", result.duration))s")
            } catch {
                print("  - Error: \(error)")
            }
        }
        
        await exhauster.stopAll()
    }
    
    // Example: Error handling
    public static func errorHandlingExample() async throws {
        let safetyMonitor = DefaultSafetyMonitor()
        let exhauster = ResourceExhauster(safetyMonitor: safetyMonitor)
        
        print("=== Error Handling Example ===\n")
        
        // Try to exhaust too many resources
        let request = ExhaustionRequest(
            resource: .fileDescriptors,
            amount: .percentage(1.0),  // 100% - likely to fail
            duration: 1.0
        )
        
        do {
            let result = try await exhauster.exhaust(request)
            print("Unexpected success: \(result)")
        } catch ResourceExhausterError.safetyLimitExceeded(requested: let requested, reason: let reason) {
            print("Expected error: Safety limit exceeded")
            print("  - Requested: \(requested)")
            print("  - Reason: \(reason)")
        } catch {
            print("Unexpected error: \(error)")
        }
    }
}