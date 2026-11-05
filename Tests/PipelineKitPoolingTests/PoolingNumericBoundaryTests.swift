import Foundation
import XCTest
@testable import PipelineKitPooling

final class PoolingNumericBoundaryTests: XCTestCase {
    func testRegistryPreservesFractionalIntervals() {
        let cleanup = PoolRegistry.cleanupInterval
        let shrink = PoolRegistry.minimumShrinkInterval
        defer {
            PoolRegistry.cleanupInterval = cleanup
            PoolRegistry.minimumShrinkInterval = shrink
        }
        PoolRegistry.cleanupInterval = 0.125
        PoolRegistry.minimumShrinkInterval = 0.25
        XCTAssertEqual(PoolRegistry.cleanupInterval, 0.125)
        XCTAssertEqual(PoolRegistry.minimumShrinkInterval, 0.25)
    }

    func testNumericConfigurationProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let entry = environment["PIPELINEKIT_NUMERIC_ENTRY"],
              let raw = environment["PIPELINEKIT_NUMERIC_VALUE"], let value = Double(raw) else { return }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_REACHED\n".utf8))
        switch entry {
        case "pool-cleanup": PoolRegistry.cleanupInterval = value
        case "pool-shrink":
            PoolRegistry.minimumShrinkInterval = value
            let pool = ObjectPool<Int>(
                name: "numeric-shrink-\(UUID())",
                configuration: try ObjectPoolConfiguration(maxSize: 2),
                factory: { 1 }, registerMetrics: false
            )
            await pool.preallocate(count: 2)
            await PoolRegistry.shared.register(pool)
            await PoolRegistry.shared.shrinkPool(name: pool.name, to: 1)
            let first = await pool.statistics
            XCTAssertEqual(first.currentlyAvailable, 1)
            await PoolRegistry.shared.shrinkPool(name: pool.name, to: 0)
            let second = await pool.statistics
            if value >= 86_400 {
                XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime, 30,
                                           "Throttle probe requires the existing startup exemption to have elapsed")
                XCTAssertEqual(second.currentlyAvailable, 1, "Second nonforced shrink must be throttled")
            } else if value == 0 {
                XCTAssertEqual(second.currentlyAvailable, 0, "Zero interval permits the second shrink")
            }
            PoolRegistry.shared.unregister(id: ObjectIdentifier(pool))
        case "pool-collector": _ = PoolMetricsCollector(collectionInterval: value)
        case "pool-export":
            await PoolObservability.shared.startExporting(interval: value)
            await PoolObservability.shared.stopExporting()
        case "pool-history": _ = PoolMetricsCollector(maxHistorySize: Int(raw)!)
        default: XCTFail("Unknown pool numeric probe \(entry)")
        }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_ACCEPTED\n".utf8))
    }
}
