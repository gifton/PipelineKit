import XCTest
@testable import PipelineKitObservability
import Foundation

final class MetricsStorageTests: XCTestCase {
    
    // MARK: - Basic Operations
    
    func testRecordAndRetrieve() async {
        let storage = MetricsStorage()
        let snapshot = MetricSnapshot.counter("test.counter", value: 1.0)
        
        await storage.record(snapshot)
        
        let all = await storage.getAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "test.counter")
    }
    
    func testGetByName() async {
        let storage = MetricsStorage()
        
        await storage.record(MetricSnapshot.counter("counter.a", value: 1.0))
        await storage.record(MetricSnapshot.counter("counter.b", value: 2.0))
        await storage.record(MetricSnapshot.counter("counter.a", value: 3.0))
        
        let snapshots = await storage.get(name: "counter.a")
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].value, 1.0)
        XCTAssertEqual(snapshots[1].value, 3.0)
    }
    
    func testGetLatest() async {
        let storage = MetricsStorage()
        
        await storage.record(MetricSnapshot.counter("test", value: 1.0))
        await storage.record(MetricSnapshot.counter("test", value: 2.0))
        await storage.record(MetricSnapshot.counter("test", value: 3.0))
        
        let latest = await storage.getLatest(name: "test")
        XCTAssertEqual(latest?.value, 3.0)
    }
    
    func testDrain() async {
        let storage = MetricsStorage()
        
        await storage.record(MetricSnapshot.counter("test1", value: 1.0))
        await storage.record(MetricSnapshot.counter("test2", value: 2.0))
        
        let drained = await storage.drain()
        XCTAssertEqual(drained.count, 2)
        
        let remaining = await storage.getAll()
        XCTAssertEqual(remaining.count, 0)
    }
    
    func testClear() async {
        let storage = MetricsStorage()
        
        await storage.record(MetricSnapshot.counter("test", value: 1.0))
        await storage.clear()
        
        let all = await storage.getAll()
        XCTAssertEqual(all.count, 0)
        let count = await storage.count
        XCTAssertEqual(count, 0)
    }
    
    // MARK: - Capacity Management
    
    func testMaxSnapshotsPerMetric() async {
        let storage = MetricsStorage(maxSnapshotsPerMetric: 3)
        
        // Record 5 snapshots for the same metric
        for i in 1...5 {
            await storage.record(MetricSnapshot.counter("test", value: Double(i)))
        }
        
        let snapshots = await storage.get(name: "test")
        XCTAssertEqual(snapshots.count, 3)
        // Should keep the last 3
        XCTAssertEqual(snapshots[0].value, 3.0)
        XCTAssertEqual(snapshots[1].value, 4.0)
        XCTAssertEqual(snapshots[2].value, 5.0)
    }
    
    func testTotalMetricCount() async {
        let storage = MetricsStorage()
        
        await storage.record(MetricSnapshot.counter("a", value: 1.0))
        await storage.record(MetricSnapshot.counter("b", value: 2.0))
        await storage.record(MetricSnapshot.counter("a", value: 3.0))
        
        let count = await storage.count
        XCTAssertEqual(count, 3)
        let uniqueCount = await storage.uniqueMetricCount
        XCTAssertEqual(uniqueCount, 2)
    }
    
    // MARK: - Aggregation Tests
    
    func testCounterAggregation() async {
        let storage = MetricsStorage()
        
        await storage.record(MetricSnapshot.counter("requests", value: 10.0))
        await storage.record(MetricSnapshot.counter("requests", value: 20.0))
        await storage.record(MetricSnapshot.counter("requests", value: 30.0))
        
        let aggregated = await storage.aggregate()
        
        let counter = aggregated.first { $0.name == "requests" }
        XCTAssertNotNil(counter)
        XCTAssertEqual(counter?.value, 60.0) // Sum of all values
        XCTAssertEqual(counter?.type, "counter")
    }
    
    func testGaugeAggregation() async {
        let storage = MetricsStorage()
        
        await storage.record(MetricSnapshot.gauge("memory", value: 100.0))
        await storage.record(MetricSnapshot.gauge("memory", value: 150.0))
        await storage.record(MetricSnapshot.gauge("memory", value: 120.0))
        
        let aggregated = await storage.aggregate()
        
        let gauge = aggregated.first { $0.name == "memory" }
        XCTAssertNotNil(gauge)
        XCTAssertEqual(gauge?.value, 120.0) // Latest value
        XCTAssertEqual(gauge?.type, "gauge")
    }
    
    func testTimerAggregation() async {
        let storage = MetricsStorage()
        
        // Add timer values
        for duration in [0.01, 0.02, 0.03, 0.04, 0.05] {
            await storage.record(MetricSnapshot.timer("api.latency", duration: duration))
        }
        
        let aggregated = await storage.aggregate()
        
        // Should generate percentiles
        let p50 = aggregated.first { $0.name == "api.latency.p50" }
        let p95 = aggregated.first { $0.name == "api.latency.p95" }
        let p99 = aggregated.first { $0.name == "api.latency.p99" }
        
        XCTAssertNotNil(p50)
        XCTAssertNotNil(p95)
        XCTAssertNotNil(p99)
        
        // P50 should be around the median value (30ms)
        XCTAssertEqual(p50?.value ?? 0.0, 30.0, accuracy: 5.0)
    }
    
    // MARK: - Pruning Tests
    
    func testPruneOlderThan() async {
        let storage = MetricsStorage()
        
        // Create old and new snapshots
        let oldTimestamp = UInt64((Date().timeIntervalSince1970 - 3600) * 1000) // 1 hour ago
        let newTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        
        let oldSnapshot = MetricSnapshot(
            name: "old.metric",
            type: "counter",
            value: 1.0,
            timestamp: oldTimestamp
        )
        
        let newSnapshot = MetricSnapshot(
            name: "new.metric",
            type: "counter",
            value: 2.0,
            timestamp: newTimestamp
        )
        
        await storage.record(oldSnapshot)
        await storage.record(newSnapshot)
        
        // Prune metrics older than 30 minutes
        await storage.pruneOlderThan(1800) // 30 minutes in seconds
        
        let remaining = await storage.getAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.name, "new.metric")
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentRecording() async {
        let storage = MetricsStorage()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await storage.record(
                        MetricSnapshot.counter("concurrent.\(i % 10)", value: Double(i))
                    )
                }
            }
        }
        
        let count = await storage.count
        XCTAssertEqual(count, 100)
        
        let uniqueCount = await storage.uniqueMetricCount
        XCTAssertEqual(uniqueCount, 10)
    }
    
    func testConcurrentDraining() async {
        let storage = MetricsStorage()
        
        // Record some metrics
        for i in 0..<50 {
            await storage.record(MetricSnapshot.counter("test", value: Double(i)))
        }
        
        var allDrained: [MetricSnapshot] = []
        
        await withTaskGroup(of: [MetricSnapshot].self) { group in
            // Multiple concurrent drains
            for _ in 0..<5 {
                group.addTask {
                    await storage.drain()
                }
            }
            
            for await drained in group {
                allDrained.append(contentsOf: drained)
            }
        }
        
        // Only the first drain should get all metrics
        XCTAssertEqual(allDrained.count, 50)
        
        // Storage should be empty
        let finalCount = await storage.count
        XCTAssertEqual(finalCount, 0)
    }
    
    func testConcurrentReadWrite() async {
        let storage = MetricsStorage()
        
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<50 {
                group.addTask {
                    await storage.record(
                        MetricSnapshot.counter("metric.\(i % 5)", value: Double(i))
                    )
                }
            }
            
            // Readers
            for _ in 0..<10 {
                group.addTask {
                    _ = await storage.getAll()
                    _ = await storage.count
                    _ = await storage.uniqueMetricCount
                }
            }
        }
        
        // Final state should be consistent
        let finalCount = await storage.count
        XCTAssertEqual(finalCount, 50)
    }
}