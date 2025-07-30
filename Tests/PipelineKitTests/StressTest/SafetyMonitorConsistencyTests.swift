import XCTest
@testable import PipelineKit

final class SafetyMonitorConsistencyTests: XCTestCase {
    var monitor: DefaultSafetyMonitor!
    
    override func setUp() async throws {
        monitor = DefaultSafetyMonitor(resourceRegistryCapacity: 100)
    }
    
    func testConsistencyCheckWithNoResources() async throws {
        // Check consistency on empty monitor
        let report = await monitor.checkConsistency()
        
        XCTAssertTrue(report.isConsistent)
        XCTAssertTrue(report.inconsistencies.isEmpty)
        XCTAssertFalse(report.repaired)
    }
    
    func testConsistencyCheckWithResources() async throws {
        // Allocate some resources
        var handles: [ResourceHandle<Never>] = []
        
        handles.append(try await monitor.allocateActor())
        handles.append(try await monitor.allocateActor())
        handles.append(try await monitor.allocateTask())
        handles.append(try await monitor.allocateTask())
        handles.append(try await monitor.allocateTask())
        handles.append(try await monitor.allocateLock())
        
        // Check consistency
        let report = await monitor.checkConsistency()
        
        XCTAssertTrue(report.isConsistent)
        XCTAssertTrue(report.inconsistencies.isEmpty)
        XCTAssertFalse(report.repaired)
        
        // Verify counts match
        let usage = await monitor.currentResourceUsage()
        XCTAssertEqual(usage.actors, 2)
        XCTAssertEqual(usage.tasks, 3)
        XCTAssertEqual(usage.locks, 1)
        XCTAssertEqual(usage.fileDescriptors, 0)
    }
    
    func testConsistencyRepair() async throws {
        // This test would need to artificially create an inconsistency
        // which is difficult without exposing internal state.
        // In a real scenario, we might use a test-specific subclass
        // or friend access pattern.
        
        // For now, we'll test that repair mode doesn't break anything
        let report = await monitor.checkConsistency(repair: true)
        
        XCTAssertTrue(report.isConsistent)
        XCTAssertFalse(report.repaired) // Nothing to repair
    }
    
    func testConsistencyAfterEviction() async throws {
        // Create a small-capacity monitor to force evictions
        let smallMonitor = DefaultSafetyMonitor(resourceRegistryCapacity: 3)
        
        // Allocate more resources than capacity
        var handles: [ResourceHandle<Never>] = []
        for _ in 0..<5 {
            handles.append(try await smallMonitor.allocateActor())
        }
        
        // Check consistency - should still be consistent
        // because eviction properly updates counters
        let report = await smallMonitor.checkConsistency()
        
        XCTAssertTrue(report.isConsistent)
        XCTAssertTrue(report.inconsistencies.isEmpty)
        
        // Release all resources
        handles.removeAll()
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Check consistency again
        let finalReport = await smallMonitor.checkConsistency()
        XCTAssertTrue(finalReport.isConsistent)
    }
    
    func testCoordinatedOperations() async throws {
        // Test that registry and counter operations remain coordinated
        // under concurrent access
        let operationCount = 100
        
        await withTaskGroup(of: Void.self) { group in
            // Concurrent allocations
            for i in 0..<operationCount {
                group.addTask { [monitor] in
                    do {
                        if i % 4 == 0 {
                            let _ = try await monitor!.allocateActor()
                        } else if i % 4 == 1 {
                            let _ = try await monitor!.allocateTask()
                        } else if i % 4 == 2 {
                            let _ = try await monitor!.allocateLock()
                        } else {
                            let _ = try await monitor!.allocateFileDescriptor()
                        }
                    } catch {
                        // Some may fail due to limits, that's OK
                    }
                }
            }
        }
        
        // Check consistency after concurrent operations
        let report = await monitor.checkConsistency()
        
        XCTAssertTrue(report.isConsistent, "Inconsistencies found: \(report.inconsistencies.map { $0.description }.joined(separator: ", "))")
    }
}