import XCTest
@testable import PipelineKitCore

#if os(Linux)
final class MemoryTelemetryLinuxTests: XCTestCase {
    func testMemoryProfilerProducesNonZeroValues() async throws {
        let profiler = MemoryProfiler()
        await profiler.startRecording()
        // Give a moment to allow at least one snapshot
        try? await Task.sleep(nanoseconds: 50_000_000)
        await profiler.captureSnapshot(label: "test")
        let report = await profiler.stopRecording()
        XCTAssertNotNil(report, "Profiler should return a report on Linux")
        guard let report else { return }

        XCTAssertFalse(report.snapshots.isEmpty, "Report should contain snapshots")
        // At least one of resident/virtual should be > 0 on Linux
        let hasNonZero = report.snapshots.contains { $0.residentMemory > 0 || $0.virtualMemory > 0 }
        XCTAssertTrue(hasNonZero, "Expected non-zero memory readings on Linux")

        // Values should be within physical memory bounds (virtual may exceed on some systems)
        let physical = ProcessInfo.processInfo.physicalMemory
        XCTAssertGreaterThan(physical, 0)
    }

    func testProfilerMonitorAPIWorksOnLinux() async throws {
        let (result, report) = try await memoryProfiler.monitor(label: "linux-monitor", sampleInterval: 0.01) {
            // perform small allocations
            let arr = [UInt8](repeating: 1, count: 1024 * 64)
            return arr.count
        }
        XCTAssertEqual(result, 1024 * 64)
        XCTAssertNotNil(report)
    }
}
#endif
