import XCTest
import Foundation
@testable import PipelineKit

final class MetricsMiddlewareTestsV2: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    func testSuccessfulMetricsCollection() async throws {
        // Given
        var collectedMetrics: [(name: String, duration: TimeInterval)] = []
        let middleware = SimpleMetricsMiddleware { name, duration in
            collectedMetrics.append((name: name, duration: duration))
        }
        
        let command = MetricsTestCommandV2(value: "test")
        let context = CommandContext()
        context.set(Date(), for: RequestStartTimeKey.self)
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            // Simulate some work
            await synchronizer.shortDelay()
            return cmd.value
        }
        
        // Then
        XCTAssertEqual(result, "test")
        XCTAssertEqual(collectedMetrics.count, 1)
        XCTAssertEqual(collectedMetrics[0].name, "MetricsTestCommandV2")
        XCTAssertGreaterThan(collectedMetrics[0].duration, 0.01) // At least 10ms
    }
    
    func testFailureMetricsCollection() async throws {
        // Given
        var collectedMetrics: [(name: String, duration: TimeInterval)] = []
        let middleware = SimpleMetricsMiddleware { name, duration in
            collectedMetrics.append((name: name, duration: duration))
        }
        
        let command = MetricsTestCommandV2(value: "fail")
        let context = CommandContext()
        context.set(Date(), for: RequestStartTimeKey.self)
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                await self.synchronizer.shortDelay()
                throw MetricsTestErrorV2.intentionalFailure
            }
            XCTFail("Should have thrown error")
        } catch {
            // Expected
        }
        
        // Verify failure metrics
        XCTAssertEqual(collectedMetrics.count, 1)
        XCTAssertEqual(collectedMetrics[0].name, "MetricsTestCommandV2.error")
        XCTAssertGreaterThan(collectedMetrics[0].duration, 0.005) // At least 5ms
    }
    
    func testMetricsWithoutStartTime() async throws {
        // Given
        var collectedMetrics: [(name: String, duration: TimeInterval)] = []
        let middleware = SimpleMetricsMiddleware { name, duration in
            collectedMetrics.append((name: name, duration: duration))
        }
        
        let command = MetricsTestCommandV2(value: "test")
        let context = CommandContext()
        // No start time set - should use current time
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
            return cmd.value
        }
        
        // Then
        XCTAssertEqual(result, "test")
        XCTAssertEqual(collectedMetrics.count, 1)
        XCTAssertGreaterThan(collectedMetrics[0].duration, 0.005)
        XCTAssertLessThan(collectedMetrics[0].duration, 0.1) // Reasonable upper bound
    }
    
    func testMetricsPriority() {
        let middleware = SimpleMetricsMiddleware { _, _ in }
        XCTAssertEqual(middleware.priority, .postProcessing)
    }
    
    func testConcurrentMetricsCollection() async throws {
        // Given
        actor MetricsAccumulator {
            var metrics: [(name: String, duration: TimeInterval)] = []
            
            func add(name: String, duration: TimeInterval) {
                metrics.append((name: name, duration: duration))
            }
            
            func getMetrics() -> [(name: String, duration: TimeInterval)] {
                metrics
            }
        }
        
        let accumulator = MetricsAccumulator()
        let middleware = SimpleMetricsMiddleware { name, duration in
            await accumulator.add(name: name, duration: duration)
        }
        
        // When - Execute multiple commands concurrently
        let tasks = (0..<10).map { i in
            Task {
                let command = MetricsTestCommandV2(value: "test-\(i)")
                let context = CommandContext()
                context.set(Date(), for: RequestStartTimeKey.self)
                
                return try await middleware.execute(command, context: context) { cmd, _ in
                    // Vary execution time
                    await self.synchronizer.shortDelay()
                    return cmd.value
                }
            }
        }
        
        // Then - All should complete with metrics
        for task in tasks {
            _ = try await task.value
        }
        
        let metrics = await accumulator.getMetrics()
        XCTAssertEqual(metrics.count, 10)
        
        // Verify each metric has appropriate duration
        for (i, metric) in metrics.enumerated() {
            XCTAssertEqual(metric.name, "MetricsTestCommandV2")
            // Duration should be at least i milliseconds
            let expectedMinDuration = Double(i) / 1000.0
            if expectedMinDuration > 0 {
                XCTAssertGreaterThanOrEqual(metric.duration, expectedMinDuration * 0.9) // Allow 10% tolerance
            }
        }
    }
}

// Test support types
private struct MetricsTestCommandV2: Command {
    typealias Result = String
    let value: String
    
    func execute() async throws -> String {
        return value
    }
}

private enum MetricsTestErrorV2: Error {
    case intentionalFailure
}