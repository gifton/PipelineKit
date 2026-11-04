import XCTest
@testable import PipelineKitObservability
import Foundation

final class MetricsStorageTests: XCTestCase {
    func testSeriesCapacityRetainsExistingIdentitiesUntilClear() async {
        let storage = MetricsStorage(maxSeries: 2)
        await storage.record(.counter("requests", value: 1, tags: ["tenant": "a"]))
        await storage.record(.counter("requests", value: 2, tags: ["tenant": "b"]))
        await storage.record(.counter("requests", value: 100, tags: ["tenant": "c"]))
        _ = await storage.drain()
        await storage.record(.counter("requests", value: 100, tags: ["tenant": "c"]))
        await storage.record(.counter("requests", value: 3, tags: ["tenant": "a"]))

        let count = await storage.seriesCount
        let diagnostics = await storage.diagnostics
        XCTAssertEqual(count, 2)
        XCTAssertEqual(diagnostics.droppedSeries, 2)
        let raw = await storage.getAll()
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.tags["tenant"], "a")
        await storage.clear()
        await storage.record(.counter("requests", value: 7, tags: ["tenant": "c"]))
        let reset = await storage.getAll()
        XCTAssertEqual(reset.first?.tags["tenant"], "c")
        let resetDiagnostics = await storage.diagnostics
        XCTAssertEqual(resetDiagnostics.droppedSeries, 0)
    }

    func testZeroLimitsDisableTheirRespectiveViews() async {
        for limit in [0] {
            let noHistory = MetricsStorage(maxSnapshotsPerMetric: limit)
            await noHistory.record(.counter("requests", value: 3))
            let historyCount = await noHistory.count
            let scrape = await PrometheusExporter(metricsStorage: noHistory).export()
            XCTAssertEqual(historyCount, 0)
            XCTAssertTrue(scrape.contains("requests_total 3\n"))

            let disabled = MetricsStorage(maxSeries: limit)
            await disabled.record(.counter("requests", value: 3))
            let seriesCount = await disabled.seriesCount
            let diagnostics = await disabled.diagnostics
            XCTAssertEqual(seriesCount, 0)
            XCTAssertEqual(diagnostics.droppedSeries, 1)
        }
    }

    func testNonFiniteAndMissingNumericValuesAreRejectedBeforeAdmission() async {
        let storage = MetricsStorage(maxSeries: 1)
        for kind in ["counter", "gauge", "histogram", "timer"] {
            for value in [Double.nan, .infinity, -.infinity] {
                await storage.record(.init(name: "invalid", type: kind, value: value))
            }
        }
        await storage.record(.init(name: "invalid", type: "gauge"))
        await storage.record(.counter("valid", value: 2))
        let raw = await storage.getAll()
        let diagnostics = await storage.diagnostics
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.name, "valid")
        XCTAssertEqual(diagnostics.rejectedValues, 13)
        XCTAssertEqual(diagnostics.droppedSeries, 0)
    }

    func testPreEpochPruneAgeRetainsHistory() async {
        let storage = MetricsStorage()
        await storage.record(.init(name: "old", type: "counter", value: 1, timestamp: 0))
        for age in [Double.greatestFiniteMagnitude] {
            await storage.pruneOlderThan(age)
            let count = await storage.count
            XCTAssertEqual(count, 1)
        }
    }

    func testLatestByNameUsesRecordOrderAcrossSeriesAndCallerTimestamps() async {
        let storage = MetricsStorage()
        await storage.record(.init(name: "g", type: "gauge", value: 1, timestamp: 100, tags: ["id": "a"]))
        await storage.record(.init(name: "g", type: "gauge", value: 2, timestamp: 1, tags: ["id": "b"]))
        let latest = await storage.getLatest(name: "g")
        XCTAssertEqual(latest?.value, 2)
        let snapshots = await storage.get(name: "g")
        XCTAssertEqual(snapshots.map(\.value), [1, 2])
    }

    func testAggregationPreservesCompleteSeriesIdentity() async throws {
        let storage = MetricsStorage()
        let inputs: [MetricSnapshot] = [
            .init(name: "shared", type: "counter", value: 2, tags: ["tenant": "a"], unit: "bytes"),
            .init(name: "shared", type: "counter", value: 3, tags: ["tenant": "a"], unit: "bytes"),
            .init(name: "shared", type: "counter", value: 7, tags: ["tenant": "b"], unit: "bytes"),
            .init(name: "shared", type: "counter", value: 11, tags: ["tenant": "a"], unit: "items"),
            .init(name: "shared", type: "gauge", value: 13, tags: ["tenant": "a"], unit: "bytes")
        ]
        for snapshot in inputs { await storage.record(snapshot) }

        let aggregated = await storage.aggregate()
        XCTAssertEqual(aggregated.count, 4)
        let values = aggregated.map { ($0.type, $0.tags["tenant"], $0.unit, $0.value) }
        XCTAssertTrue(values.contains { $0.0 == "counter" && $0.1 == "a" && $0.2 == "bytes" && $0.3 == 5 })
        XCTAssertTrue(values.contains { $0.0 == "counter" && $0.1 == "b" && $0.2 == "bytes" && $0.3 == 7 })
        XCTAssertTrue(values.contains { $0.0 == "counter" && $0.1 == "a" && $0.2 == "items" && $0.3 == 11 })
        XCTAssertTrue(values.contains { $0.0 == "gauge" && $0.1 == "a" && $0.2 == "bytes" && $0.3 == 13 })
    }

    func testAggregationPreservesDelimiterAndEmptyTagValues() async {
        let storage = MetricsStorage()
        let tags: [[String: String]] = [
            ["a": "b,c:d"], ["a": "b", "c": "d"], ["a": ""], [:],
            ["a:b": "c"], ["a": "b:c"], ["a": "line\n\\\"value"]
        ]
        for (index, dimensions) in tags.enumerated() {
            await storage.record(.counter("shared", value: Double(index + 1), tags: dimensions))
        }

        let aggregated = await storage.aggregate()
        XCTAssertEqual(aggregated.count, tags.count)
        for (index, dimensions) in tags.enumerated() {
            let match = aggregated.filter { $0.tags == dimensions }
            XCTAssertEqual(match.count, 1)
            XCTAssertEqual(match.first?.value, Double(index + 1))
        }
    }

    func testAggregationCountsNilCounterAsOneIncrement() async {
        let storage = MetricsStorage()
        await storage.record(.init(name: "requests", type: "counter"))
        await storage.record(.counter("requests", value: 2))

        let aggregated = await storage.aggregate()
        XCTAssertEqual(aggregated.count, 1)
        XCTAssertEqual(aggregated.first?.value, 3)
    }

    func testSnapshotCapacityAppliesIndependentlyToEachSeries() async {
        let storage = MetricsStorage(maxSnapshotsPerMetric: 1)
        await storage.record(.counter("requests", value: 1, tags: ["tenant": "a"]))
        await storage.record(.counter("requests", value: 2, tags: ["tenant": "b"]))
        await storage.record(.counter("requests", value: 3, tags: ["tenant": "a"]))

        let snapshots = await storage.get(name: "requests")
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.first { $0.tags["tenant"] == "a" }?.value, 3)
        XCTAssertEqual(snapshots.first { $0.tags["tenant"] == "b" }?.value, 2)
        let uniqueNames = await storage.uniqueMetricCount
        XCTAssertEqual(uniqueNames, 1)
    }

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
