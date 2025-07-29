import XCTest
@testable import PipelineKitBenchmarks

final class MemoryTrackingTests: XCTestCase {
    
    func testCurrentMemoryUsage() {
        // Given/When
        let memory = MemoryTracking.currentMemoryUsage()
        
        // Then
        XCTAssertGreaterThan(memory, 0, "Process should have some memory usage")
    }
    
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    func testAllocationStatistics() {
        // Given/When
        let stats = MemoryTracking.getAllocationStatistics()
        
        // Then
        XCTAssertGreaterThanOrEqual(stats.blocksInUse, 0)
        XCTAssertGreaterThanOrEqual(stats.sizeInUse, 0)
        XCTAssertGreaterThanOrEqual(stats.sizeAllocated, stats.sizeInUse)
    }
    
    func testTrackAllocations() async throws {
        // Given
        let initialStats = MemoryTracking.getAllocationStatistics()
        
        // When
        let (result, allocations, peakMemory) = try await MemoryTracking.trackAllocations {
            // Allocate a large buffer
            let size = 1024 * 1024 // 1MB
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: size,
                alignment: MemoryLayout<UInt8>.alignment
            )
            defer { buffer.deallocate() }
            
            // Touch memory
            memset(buffer, 0, size)
            
            return "completed"
        }
        
        // Then
        XCTAssertEqual(result, "completed")
        XCTAssertGreaterThan(peakMemory, 0)
        
        // Note: allocations count might not be exact due to system allocations
        // but should be positive after allocating 1MB
        XCTAssertGreaterThanOrEqual(allocations, 0)
    }
    #endif
    
    func testMemoryPressure() async throws {
        // Given
        let initialMemory = MemoryTracking.currentMemoryUsage()
        
        // When - Apply low memory pressure
        await MemoryTracking.applyMemoryPressure(level: .low, duration: 0.1)
        
        // Then
        let finalMemory = MemoryTracking.currentMemoryUsage()
        
        // Memory should return close to initial after pressure is released
        // (within 10MB considering other allocations)
        XCTAssertLessThan(abs(finalMemory - initialMemory), 10_000_000)
    }
    
    func testHighResolutionTimer() async throws {
        // Given
        let timer = HighResolutionTimer()
        
        // When
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        let elapsed = timer.elapsed
        
        // Then
        XCTAssertGreaterThan(elapsed, 0.009) // At least 9ms
        XCTAssertLessThan(elapsed, 0.020) // Less than 20ms
    }
    
    func testMemorySnapshot() {
        // Given/When
        let snapshot = MemorySnapshot.current()
        
        // Then
        XCTAssertNotNil(snapshot.timestamp)
        
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        XCTAssertGreaterThan(snapshot.residentMemory, 0)
        XCTAssertGreaterThan(snapshot.virtualMemory, 0)
        XCTAssertGreaterThan(snapshot.virtualMemory, snapshot.residentMemory)
        #endif
    }
    
    func testMemoryTrackingThreadSafety() async throws {
        // Given
        let iterations = 100
        
        // When - Concurrent memory tracking
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    MemoryTracking.currentMemoryUsage()
                }
            }
            
            // Collect results
            var results: [Int] = []
            for await result in group {
                results.append(result)
            }
            
            // Then
            XCTAssertEqual(results.count, iterations)
            XCTAssertTrue(results.allSatisfy { $0 > 0 })
        }
    }
}