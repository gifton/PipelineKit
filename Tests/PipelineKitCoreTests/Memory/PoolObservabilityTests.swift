import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

/// Tests for pool observability metrics
final class PoolObservabilityTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    final class TestObject: Sendable {
        let id = UUID()
    }
    
    override func setUp() async throws {
        // Reset observability for clean test state
        await PoolObservability.shared.reset()
    }
    
    // MARK: - Counter Tests
    
    func testCounterMetrics() async {
        // Given
        let observability = PoolObservability.shared
        
        // When
        await observability.incrementCounter("test_counter")
        await observability.incrementCounter("test_counter", by: 5)
        await observability.incrementCounter("test_counter", labels: ["env": "test"])
        
        // Then
        let count1 = await observability.getCounter("test_counter")
        XCTAssertEqual(count1, 6)
        
        let count2 = await observability.getCounter("test_counter", labels: ["env": "test"])
        XCTAssertEqual(count2, 1)
    }
    
    // MARK: - Gauge Tests
    
    func testGaugeMetrics() async {
        // Given
        let observability = PoolObservability.shared
        
        // When
        await observability.setGauge("test_gauge", value: 42.5)
        await observability.incrementGauge("test_gauge", by: 7.5)
        await observability.decrementGauge("test_gauge", by: 10.0)
        
        // Then
        let value = await observability.getGauge("test_gauge")
        XCTAssertEqual(value, 40.0)
    }
    
    // MARK: - Histogram Tests
    
    func testHistogramMetrics() async {
        // Given
        let observability = PoolObservability.shared
        
        // When
        for i in 1...100 {
            await observability.recordHistogram("test_histogram", value: Double(i))
        }
        
        // Then
        let stats = await observability.getHistogram("test_histogram")
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.count, 100)
        XCTAssertEqual(stats?.min, 1.0)
        XCTAssertEqual(stats?.max, 100.0)
        XCTAssertEqual(stats?.p50, 50.0)
        XCTAssertGreaterThan(stats?.p95 ?? 0, 94.0)
        XCTAssertLessThanOrEqual(stats?.p95 ?? 0, 95.0)
    }
    
    // MARK: - Summary Tests
    
    func testSummaryMetrics() async {
        // Given
        let observability = PoolObservability.shared
        
        // When
        for i in 1...1000 {
            await observability.recordSummary("test_summary", value: Double(i))
        }
        
        // Then
        let stats = await observability.getSummary("test_summary")
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.count, 1000)
        XCTAssertEqual(stats?.p50, 500.0)
        XCTAssertGreaterThan(stats?.p99 ?? 0, 989.0)
    }
    
    // MARK: - Pool Integration Tests
    
    func testPoolAcquisitionMetrics() async {
        // Given
        let observability = PoolObservability.shared
        let pool = ObjectPool<TestObject>(
            name: "metrics-test",
            configuration: ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // Pre-allocate some objects
        await pool.preallocate(count: 5)
        
        // When - Acquire from pool (hit)
        let obj1 = await pool.acquire()
        await pool.release(obj1)
        
        // Give metrics time to record
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Acquire again (should be a hit)
        let _ = await pool.acquire()
        
        // Give metrics time to record
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Then
        let hits = await observability.getCounter("pool_hits_total", labels: ["pool": "metrics-test"])
        XCTAssertGreaterThan(hits, 0, "Should record pool hits")
        
        let latencyStats = await observability.getHistogram("pool_acquisition_latency_ms", labels: ["pool": "metrics-test"])
        XCTAssertNotNil(latencyStats)
        XCTAssertGreaterThan(latencyStats?.count ?? 0, 0)
    }
    
    func testPoolReleaseMetrics() async {
        // Given
        let observability = PoolObservability.shared
        let pool = ObjectPool<TestObject>(
            name: "release-test",
            configuration: ObjectPoolConfiguration(maxSize: 2),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // When - Fill pool to capacity
        let obj1 = await pool.acquire()
        let obj2 = await pool.acquire()
        let obj3 = await pool.acquire()
        
        await pool.release(obj1)
        await pool.release(obj2)
        await pool.release(obj3) // This should be evicted
        
        // Give metrics time to record
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Then
        let evictions = await observability.getCounter("pool_evictions_total", labels: ["pool": "release-test"])
        XCTAssertGreaterThan(evictions, 0, "Should record evictions when pool is full")
        
        let sizeGauge = await observability.getGauge("pool_available_objects", labels: ["pool": "release-test"])
        XCTAssertNotNil(sizeGauge)
    }
    
    func testPoolShrinkMetrics() async {
        // Given
        let observability = PoolObservability.shared
        let pool = ObjectPool<TestObject>(
            name: "shrink-test",
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 100)
        
        // When
        await pool.shrink(to: 50)
        
        // Give metrics time to record
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Then
        let shrinkOps = await observability.getCounter("pool_shrink_operations_total", labels: [
            "pool": "shrink-test",
            "reason": "manual",
            "throttled": "false"
        ])
        XCTAssertEqual(shrinkOps, 1)
        
        let objectsRemoved = await observability.getCounter("pool_objects_shrunk_total", labels: ["pool": "shrink-test"])
        XCTAssertEqual(objectsRemoved, 50)
    }
    
    func testMemoryPressureMetrics() async {
        // Given
        let observability = PoolObservability.shared
        
        // When
        await observability.recordMemoryPressure(
            level: .warning,
            poolsAffected: 5,
            totalObjectsRemoved: 250
        )
        
        await observability.recordMemoryPressure(
            level: .critical,
            poolsAffected: 10,
            totalObjectsRemoved: 800
        )
        
        // Then
        let warningEvents = await observability.getCounter("memory_pressure_events_total", labels: ["level": "warning"])
        XCTAssertEqual(warningEvents, 1)
        
        let criticalEvents = await observability.getCounter("memory_pressure_events_total", labels: ["level": "critical"])
        XCTAssertEqual(criticalEvents, 1)
        
        let poolsAffected = await observability.getHistogram("memory_pressure_pools_affected", labels: ["level": "critical"])
        XCTAssertNotNil(poolsAffected)
        XCTAssertEqual(poolsAffected?.max, 10.0)
    }
    
    // MARK: - Export Tests
    
    func testMetricsExport() async {
        // Given
        let observability = PoolObservability.shared
        let expectation = XCTestExpectation(description: "Metrics exported")
        
        // Use actor to safely capture snapshot
        actor SnapshotCapture {
            var snapshot: MetricsSnapshot?
            func set(_ s: MetricsSnapshot) { snapshot = s }
            func get() -> MetricsSnapshot? { snapshot }
        }
        let capture = SnapshotCapture()
        
        // Register exporter
        let exporterID = await observability.registerExporter { snapshot in
            await capture.set(snapshot)
            expectation.fulfill()
        }
        
        // When - Record some metrics
        await observability.incrementCounter("export_test", by: 42)
        await observability.setGauge("export_gauge", value: 3.14)
        await observability.recordHistogram("export_histogram", value: 100.0)
        
        // Trigger export
        await observability.exportMetrics()
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        
        let exportedSnapshot = await capture.get()
        XCTAssertNotNil(exportedSnapshot)
        XCTAssertEqual(exportedSnapshot?.counters["export_test"], 42)
        XCTAssertEqual(exportedSnapshot?.gauges["export_gauge"], 3.14)
        XCTAssertNotNil(exportedSnapshot?.histograms["export_histogram"])
        
        // Cleanup
        await observability.unregisterExporter(id: exporterID)
    }
    
    func testPrometheusFormat() async {
        // Given
        let observability = PoolObservability.shared
        
        // Record metrics
        await observability.incrementCounter("requests_total", by: 100)
        await observability.setGauge("temperature_celsius", value: 22.5)
        await observability.recordHistogram("request_duration", value: 0.25)
        
        // When
        let snapshot = await observability.captureSnapshot()
        let prometheus = snapshot.prometheusFormat()
        
        // Then
        XCTAssertTrue(prometheus.contains("requests_total 100"))
        XCTAssertTrue(prometheus.contains("temperature_celsius 22.5"))
        XCTAssertTrue(prometheus.contains("request_duration_count"))
        XCTAssertTrue(prometheus.contains("request_duration{quantile=\"0.5\"}"))
    }
    
    func testStatsDFormat() async {
        // Given
        let observability = PoolObservability.shared
        
        // Record metrics
        await observability.incrementCounter("api.calls", by: 50)
        await observability.setGauge("memory.usage", value: 1024.0)
        
        // When
        let snapshot = await observability.captureSnapshot()
        let statsd = snapshot.statsdFormat()
        
        // Then
        XCTAssertTrue(statsd.contains("api.calls:50|c"))
        XCTAssertTrue(statsd.contains("memory.usage:1024.0|g"))
    }
    
    func testPeriodicExport() async {
        // Given
        let observability = PoolObservability.shared
        let expectation = XCTestExpectation(description: "Periodic export")
        expectation.expectedFulfillmentCount = 2 // Expect at least 2 exports
        
        // Register exporter
        let exporterID = await observability.registerExporter { _ in
            expectation.fulfill()
        }
        
        // When - Start periodic export with short interval
        await observability.startExporting(interval: 0.1)
        
        // Wait for exports
        await fulfillment(of: [expectation], timeout: 0.5)
        
        // Then - Stop exporting
        await observability.stopExporting()
        
        // Cleanup
        await observability.unregisterExporter(id: exporterID)
    }
    
    func testLabeledMetrics() async {
        // Given
        let observability = PoolObservability.shared
        
        // When - Record metrics with different labels
        await observability.incrementCounter("http_requests", labels: ["method": "GET", "status": "200"])
        await observability.incrementCounter("http_requests", labels: ["method": "GET", "status": "404"])
        await observability.incrementCounter("http_requests", labels: ["method": "POST", "status": "201"])
        
        // Then
        let get200 = await observability.getCounter("http_requests", labels: ["method": "GET", "status": "200"])
        let get404 = await observability.getCounter("http_requests", labels: ["method": "GET", "status": "404"])
        let post201 = await observability.getCounter("http_requests", labels: ["method": "POST", "status": "201"])
        
        XCTAssertEqual(get200, 1)
        XCTAssertEqual(get404, 1)
        XCTAssertEqual(post201, 1)
    }
}