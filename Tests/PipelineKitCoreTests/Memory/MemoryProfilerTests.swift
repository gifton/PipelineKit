import XCTest
@testable import PipelineKit

final class MemoryProfilerTests: XCTestCase {
    private var profiler: MemoryProfiler!
    
    override func setUp() async throws {
        try await super.setUp()
        profiler = MemoryProfiler()
    }
    
    override func tearDown() async throws {
        // Ensure profiler is stopped
        _ = await profiler.stopRecording()
        profiler = nil
        try await super.tearDown()
    }
    
    // MARK: - Recording Control Tests
    
    func testStartRecording() async throws {
        // Given
        let result = await profiler.stopRecording()
        XCTAssertNil(result, "Should return nil when not recording")
        
        // When
        await profiler.startRecording()
        
        // Then
        let report = await profiler.stopRecording()
        XCTAssertNotNil(report, "Should return report after recording")
        XCTAssertGreaterThan(report!.snapshots.count, 0, "Should have at least baseline snapshot")
        XCTAssertEqual(report!.snapshots.first?.label, "Baseline")
    }
    
    func testStopRecordingWithoutStart() async throws {
        // Given - No startRecording called
        
        // When
        let report = await profiler.stopRecording()
        
        // Then
        XCTAssertNil(report, "Should return nil when not recording")
    }
    
    func testDoubleStartRecording() async throws {
        // Given
        await profiler.startRecording()
        await profiler.captureSnapshot(label: "First")
        
        // When - Start again
        await profiler.startRecording()
        
        // Then - Should reset
        let report = await profiler.stopRecording()
        XCTAssertNotNil(report)
        // Should not have "First" snapshot from previous recording
        XCTAssertFalse(report!.snapshots.contains { $0.label == "First" })
    }
    
    // MARK: - Snapshot Tests
    
    func testCaptureSnapshot() async throws {
        // Given
        await profiler.startRecording()
        
        // When
        await profiler.captureSnapshot(label: "Test Snapshot")
        
        // Then
        let report = await profiler.stopRecording()
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.snapshots.contains { $0.label == "Test Snapshot" })
    }
    
    func testCaptureMultipleSnapshots() async throws {
        // Given
        await profiler.startRecording()
        
        // When
        for i in 0..<5 {
            await profiler.captureSnapshot(label: "Snapshot \(i)")
        }
        
        // Then
        let report = await profiler.stopRecording()
        XCTAssertNotNil(report)
        // Should have baseline + 5 + final = 7 snapshots
        XCTAssertEqual(report!.snapshots.count, 7)
    }
    
    func testCaptureSnapshotWithoutRecording() async throws {
        // Given - Not recording
        
        // When
        await profiler.captureSnapshot(label: "Should not capture")
        
        // Then - Start recording and check
        await profiler.startRecording()
        let report = await profiler.stopRecording()
        XCTAssertFalse(report!.snapshots.contains { $0.label == "Should not capture" })
    }
    
    // MARK: - Allocation Tracking Tests
    
    func testTrackAllocation() async throws {
        // Given
        await profiler.startRecording()
        
        // When
        await profiler.trackAllocation(type: "TestObject", size: 1024)
        await profiler.trackAllocation(type: "TestObject", size: 2048)
        await profiler.trackAllocation(type: "OtherObject", size: 512)
        
        // Then
        let report = await profiler.stopRecording()
        XCTAssertNotNil(report)
        
        let testObjectAlloc = report!.allocations.first { $0.type == "TestObject" }
        XCTAssertNotNil(testObjectAlloc)
        XCTAssertEqual(testObjectAlloc!.count, 2)
        XCTAssertEqual(testObjectAlloc!.totalSize, 3072)
        XCTAssertEqual(testObjectAlloc!.averageSize, 1536)
        
        let otherObjectAlloc = report!.allocations.first { $0.type == "OtherObject" }
        XCTAssertNotNil(otherObjectAlloc)
        XCTAssertEqual(otherObjectAlloc!.count, 1)
        XCTAssertEqual(otherObjectAlloc!.totalSize, 512)
    }
    
    func testTrackAllocationWithoutRecording() async throws {
        // Given - Not recording
        
        // When
        await profiler.trackAllocation(type: "TestObject", size: 1024)
        
        // Then - Start recording and check
        await profiler.startRecording()
        let report = await profiler.stopRecording()
        XCTAssertTrue(report!.allocations.isEmpty, "Should not track allocations when not recording")
    }
    
    // MARK: - Monitoring Tests
    
    func testMonitorBlock() async throws {
        // Given/When
        let (result, report) = await profiler.monitor(label: "Test Operation") {
            // Simulate some work
            var data = [Int]()
            for i in 0..<1000 {
                data.append(i)
            }
            return data.count
        }
        
        // Then
        XCTAssertEqual(result, 1000)
        XCTAssertNotNil(report)
        XCTAssertGreaterThan(report!.snapshots.count, 2, "Should have multiple snapshots")
    }
    
    func testMonitorBlockWithError() async throws {
        // Given
        enum TestError: Error { case test }
        
        // When/Then
        do {
            let (_, _) = try await profiler.monitor(label: "Error Operation") {
                throw TestError.test
            }
            XCTFail("Should throw error")
        } catch {
            // Expected
            XCTAssertTrue(error is TestError)
        }
    }
    
    func testMonitorWithCustomInterval() async throws {
        // Given/When
        let synchronizer = TestSynchronizer()
        let (_, report) = await profiler.monitor(
            label: "Custom Interval",
            sampleInterval: 0.05 // 50ms
        ) {
            // Simulate work with multiple yields
            for _ in 0..<10 {
                await synchronizer.mediumDelay()
            }
            return true
        }
        
        // Then
        XCTAssertNotNil(report)
        // Should have multiple samples
        XCTAssertGreaterThan(report!.snapshots.count, 2)
    }
    
    // MARK: - Report Generation Tests
    
    func testReportStatistics() async throws {
        // Given
        await profiler.startRecording()
        
        // Capture some snapshots
        let synchronizer = TestSynchronizer()
        for i in 0..<5 {
            await profiler.captureSnapshot(label: "Snapshot \(i)")
            // Small delay between snapshots
            await synchronizer.shortDelay()
        }
        
        // When
        let report = await profiler.stopRecording()
        
        // Then
        XCTAssertNotNil(report)
        XCTAssertGreaterThan(report!.duration, 0)
        XCTAssertGreaterThan(report!.peakMemory, 0)
        XCTAssertGreaterThan(report!.averageMemory, 0)
        XCTAssertEqual(report!.snapshots.last?.label, "Final")
    }
    
    func testReportRecommendations() async throws {
        // Given
        await profiler.startRecording()
        
        // Simulate large allocations
        for _ in 0..<10 {
            await profiler.trackAllocation(type: "LargeObject", size: 11 * 1024 * 1024) // 11MB each
        }
        
        // Simulate frequent small allocations
        for _ in 0..<2000 {
            await profiler.trackAllocation(type: "SmallObject", size: 512) // 512 bytes each
        }
        
        // When
        let report = await profiler.stopRecording()
        
        // Then
        XCTAssertNotNil(report)
        XCTAssertFalse(report!.recommendations.isEmpty)
        
        // Should have recommendations about large allocations
        let hasLargeAllocationWarning = report!.recommendations.contains { $0.contains("Large allocations") }
        XCTAssertTrue(hasLargeAllocationWarning)
        
        // Should have recommendations about frequent small allocations
        let hasSmallAllocationWarning = report!.recommendations.contains { $0.contains("Frequent small allocations") }
        XCTAssertTrue(hasSmallAllocationWarning)
    }
    
    func testReportDescription() async throws {
        // Given
        await profiler.startRecording()
        await profiler.trackAllocation(type: "TestObject", size: 1024 * 1024)
        
        // When
        let report = await profiler.stopRecording()
        let description = report!.description
        
        // Then
        XCTAssertTrue(description.contains("Memory Profile Report"))
        XCTAssertTrue(description.contains("Duration:"))
        XCTAssertTrue(description.contains("Peak Memory:"))
        XCTAssertTrue(description.contains("Average Memory:"))
        XCTAssertTrue(description.contains("Memory Growth:"))
        XCTAssertTrue(description.contains("Recommendations:"))
    }
    
    // MARK: - Pattern Analysis Tests
    
    func testAnalyzePatternsStable() async throws {
        // Given
        await profiler.startRecording()
        
        // Create stable memory pattern
        for _ in 0..<5 {
            await profiler.captureSnapshot()
        }
        
        // When
        let report = await profiler.stopRecording()
        let pattern = await profiler.analyzePatterns(from: report!.snapshots)
        
        // Then
        if case .stable = pattern {
            // Expected
        } else {
            XCTFail("Expected stable pattern")
        }
    }
    
    func testAnalyzePatternsEmpty() async throws {
        // Given
        let emptySnapshots: [MemoryProfiler.MemorySnapshot] = []
        
        // When
        let pattern = await profiler.analyzePatterns(from: emptySnapshots)
        
        // Then
        if case .stable = pattern {
            // Expected for empty
        } else {
            XCTFail("Expected stable pattern for empty snapshots")
        }
    }
    
    func testAnalyzePatternsSingle() async throws {
        // Given
        await profiler.startRecording()
        let report = await profiler.stopRecording()
        
        // When
        let pattern = await profiler.analyzePatterns(from: [report!.snapshots.first!])
        
        // Then
        if case .stable = pattern {
            // Expected for single snapshot
        } else {
            XCTFail("Expected stable pattern for single snapshot")
        }
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentSnapshots() async throws {
        // Given
        await profiler.startRecording()
        
        // When - Capture snapshots concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    await self.profiler.captureSnapshot(label: "Concurrent \(i)")
                }
            }
        }
        
        // Then
        let report = await profiler.stopRecording()
        XCTAssertNotNil(report)
        // Should have captured all snapshots
        let concurrentSnapshots = report!.snapshots.filter { $0.label?.starts(with: "Concurrent") ?? false }
        XCTAssertEqual(concurrentSnapshots.count, 20)
    }
    
    func testConcurrentAllocations() async throws {
        // Given
        await profiler.startRecording()
        
        // When - Track allocations concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await self.profiler.trackAllocation(
                        type: "ConcurrentObject",
                        size: (i + 1) * 1024
                    )
                }
            }
        }
        
        // Then
        let report = await profiler.stopRecording()
        XCTAssertNotNil(report)
        
        let concurrentAlloc = report!.allocations.first { $0.type == "ConcurrentObject" }
        XCTAssertNotNil(concurrentAlloc)
        XCTAssertEqual(concurrentAlloc!.count, 100)
        
        // Total size should be 1024 + 2048 + ... + 100*1024 = 1024 * (1+2+...+100) = 1024 * 5050
        XCTAssertEqual(concurrentAlloc!.totalSize, 1024 * 5050)
    }
    
    // MARK: - Global Profiler Tests
    
    func testGlobalProfiler() async throws {
        // Given/When
        await memoryProfiler.startRecording()
        await memoryProfiler.captureSnapshot(label: "Global Test")
        let report = await memoryProfiler.stopRecording()
        
        // Then
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.snapshots.contains { $0.label == "Global Test" })
    }
    
    // MARK: - Memory Pattern Tests
    
    func testMemoryPatternEnum() {
        // Test pattern cases
        switch MemoryPattern.stable {
        case .stable:
            break // Expected
        default:
            XCTFail("Wrong pattern")
        }
        
        switch MemoryPattern.growing(rate: 1.5) {
        case .growing(let rate):
            XCTAssertEqual(rate, 1.5)
        default:
            XCTFail("Wrong pattern")
        }
        
        switch MemoryPattern.leak(rate: 2.0) {
        case .leak(let rate):
            XCTAssertEqual(rate, 2.0)
        default:
            XCTFail("Wrong pattern")
        }
        
        switch MemoryPattern.fluctuating {
        case .fluctuating:
            break // Expected
        default:
            XCTFail("Wrong pattern")
        }
    }
}
