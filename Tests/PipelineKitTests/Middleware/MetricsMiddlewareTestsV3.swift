import XCTest
@testable import PipelineKit

final class MetricsMiddlewareTestsV3: XCTestCase {
    
    func testMetricsCollection() async throws {
        // Given
        let collector = StandardAdvancedMetricsCollector()
        let middleware = MetricsMiddleware(
            collector: collector,
            namespace: "test"
        )
        
        let command = MetricsTestCommand(value: "test")
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            // Simulate some work
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            return cmd.value
        }
        
        // Then
        XCTAssertEqual(result, "test")
        
        // Verify metrics were collected
        let metrics = await collector.getMetrics()
        
        // Should have active request increment
        let activeIncrements = metrics.filter { $0.name == "test.requests.active" && $0.type == .counter }
        XCTAssertGreaterThanOrEqual(activeIncrements.count, 1)
        
        // Should have success counter
        let successMetrics = metrics.filter { $0.name == "test.requests.success" && $0.type == .counter }
        XCTAssertEqual(successMetrics.count, 1)
        XCTAssertEqual(successMetrics.first?.value, 1)
        
        // Should have duration latency
        let durationMetrics = metrics.filter { $0.name == "test.requests.duration" && $0.type == .latency }
        XCTAssertEqual(durationMetrics.count, 1)
        XCTAssertGreaterThan(durationMetrics.first?.value ?? 0, 0.01) // At least 10ms
        
        // Verify tags
        let successMetric = successMetrics.first!
        XCTAssertEqual(successMetric.tags["command"], "MetricsTestCommand")
    }
    
    func testMetricsFailure() async throws {
        // Given
        let collector = StandardAdvancedMetricsCollector()
        let middleware = MetricsMiddleware(collector: collector)
        
        let command = MetricsTestCommand(value: "fail")
        let context = CommandContext()
        
        // When
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                throw MetricsTestError.intentional
            }
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
        
        // Then
        let metrics = await collector.getMetrics()
        
        // Should have failure counter
        let failureMetrics = metrics.filter { $0.name == "requests.failure" && $0.type == .counter }
        XCTAssertEqual(failureMetrics.count, 1)
        XCTAssertEqual(failureMetrics.first?.value, 1)
        
        // Should have error tag
        let failureMetric = failureMetrics.first!
        XCTAssertEqual(failureMetric.tags["error"], "MetricsTestError")
        
        // Should still have duration
        let durationMetrics = metrics.filter { $0.name == "requests.duration" && $0.type == .latency }
        XCTAssertEqual(durationMetrics.count, 1)
    }
    
    func testCustomTags() async throws {
        // Given
        let collector = StandardAdvancedMetricsCollector()
        let middleware = MetricsMiddleware(
            collector: collector,
            customTags: [
                "environment": "test",
                "version": "1.0"
            ]
        )
        
        let command = MetricsTestCommand(value: "tagged")
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            cmd.value
        }
        
        // Then
        let metrics = await collector.getMetrics()
        let successMetric = metrics.first { $0.name == "requests.success" }!
        
        XCTAssertEqual(successMetric.tags["environment"], "test")
        XCTAssertEqual(successMetric.tags["version"], "1.0")
        XCTAssertEqual(successMetric.tags["command"], "MetricsTestCommand")
    }
    
    func testMetricsProviderCommand() async throws {
        // Given
        let collector = StandardAdvancedMetricsCollector()
        let middleware = MetricsMiddleware(collector: collector)
        
        let command = MetricsProviderCommand(
            value: "provider",
            customMetrics: [
                "items_processed": 42,
                "cache_hit_ratio": 0.85
            ]
        )
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            cmd.value
        }
        
        // Then
        let metrics = await collector.getMetrics()
        
        // Should have custom metrics as gauges
        let itemsMetric = metrics.first { $0.name == "command.items_processed" && $0.type == .gauge }
        XCTAssertNotNil(itemsMetric)
        XCTAssertEqual(itemsMetric?.value, 42)
        
        let cacheMetric = metrics.first { $0.name == "command.cache_hit_ratio" && $0.type == .gauge }
        XCTAssertNotNil(cacheMetric)
        XCTAssertEqual(cacheMetric?.value, 0.85)
    }
    
    func testNamespacedMetrics() async throws {
        // Given
        let collector = StandardAdvancedMetricsCollector()
        let middleware = MetricsMiddleware(
            collector: collector,
            namespace: "api.v1"
        )
        
        let command = MetricsTestCommand(value: "namespaced")
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            cmd.value
        }
        
        // Then
        let metrics = await collector.getMetrics()
        
        // All metrics should be namespaced
        XCTAssertTrue(metrics.contains { $0.name == "api.v1.requests.active" })
        XCTAssertTrue(metrics.contains { $0.name == "api.v1.requests.success" })
        XCTAssertTrue(metrics.contains { $0.name == "api.v1.requests.duration" })
        
        // Should not have non-namespaced metrics
        XCTAssertFalse(metrics.contains { $0.name == "requests.success" })
    }
    
    func testConcurrentMetrics() async throws {
        // Given
        let collector = StandardAdvancedMetricsCollector()
        let middleware = MetricsMiddleware(collector: collector)
        
        let context = CommandContext()
        
        // When - execute multiple commands concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let command = MetricsTestCommand(value: "concurrent-\(i)")
                    _ = try? await middleware.execute(command, context: context) { cmd, _ in
                        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        return cmd.value
                    }
                }
            }
        }
        
        // Then
        let metrics = await collector.getMetrics()
        
        // Should have 10 success metrics
        let successMetrics = metrics.filter { $0.name == "requests.success" && $0.type == .counter }
        let totalSuccess = successMetrics.last?.value ?? 0
        XCTAssertEqual(totalSuccess, 10)
        
        // All durations should be recorded
        let durationMetrics = metrics.filter { $0.name == "requests.duration" && $0.type == .latency }
        XCTAssertEqual(durationMetrics.count, 10)
    }
    
    func testMetricsCollectorFiltering() async throws {
        // Given
        let collector = StandardAdvancedMetricsCollector()
        
        // Add various metrics
        await collector.incrementCounter("test.counter", value: 1, tags: [:])
        await collector.recordGauge("test.gauge", value: 42, tags: [:])
        await collector.recordLatency("test.latency", value: 0.5, tags: [:])
        await collector.incrementCounter("other.counter", value: 2, tags: [:])
        
        // When - filter by name
        let testMetrics = await collector.getMetrics(name: "test")
        XCTAssertEqual(testMetrics.count, 3)
        
        // When - filter by type
        let counterMetrics = await collector.getMetrics(type: .counter)
        XCTAssertEqual(counterMetrics.count, 2)
        
        // When - filter by both
        let testCounters = await collector.getMetrics(name: "test", type: .counter)
        XCTAssertEqual(testCounters.count, 1)
        XCTAssertEqual(testCounters.first?.name, "test.counter")
    }
}

// Test support types
private struct MetricsTestCommand: Command {
    typealias Result = String
    let value: String
    
    func execute() async throws -> String {
        value
    }
}

private struct MetricsProviderCommand: Command, MetricsProvider {
    typealias Result = String
    let value: String
    let customMetrics: [String: Double]
    
    func execute() async throws -> String {
        value
    }
    
    var metrics: [String: Double] {
        customMetrics
    }
}

private enum MetricsTestError: Error {
    case intentional
}