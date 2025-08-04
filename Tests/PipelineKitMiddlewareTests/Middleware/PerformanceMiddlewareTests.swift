import XCTest
import Foundation
@testable import PipelineKit
@testable import PipelineKitMiddleware
import PipelineKitTests

final class PerformanceMiddlewareTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    func testSuccessfulPerformanceTracking() async throws {
        // Given
        let collector = TestPerformanceCollector()
        let middleware = PerformanceMiddleware(
            collector: collector,
            includeDetailedMetrics: true
        )
        
        let command = PerfTestCommand(value: "test")
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            // Simulate some work
            await synchronizer.mediumDelay()
            return cmd.value
        }
        
        // Then
        XCTAssertEqual(result, "test")
        
        await collector.waitForMeasurements(count: 1)
        let measurements = await collector.getMeasurements()
        
        XCTAssertEqual(measurements.count, 1)
        let measurement = measurements[0]
        XCTAssertEqual(measurement.commandName, "PerfTestCommand")
        XCTAssertGreaterThanOrEqual(measurement.executionTime, 0.05) // At least 50ms
        XCTAssertLessThan(measurement.executionTime, 0.1) // Less than 100ms
        XCTAssertTrue(measurement.isSuccess)
        XCTAssertNil(measurement.errorMessage)
    }
    
    func testPerformanceTrackingWithFailure() async throws {
        // Given
        let collector = TestPerformanceCollector()
        let middleware = PerformanceMiddleware(collector: collector)
        
        let command = PerfTestCommand(value: "fail")
        let context = CommandContext()
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                await self.synchronizer.shortDelay()
                throw PerfTestError.intentionalFailure
            }
            XCTFail("Should have thrown error")
        } catch {
            // Expected
        }
        
        // Performance should still be tracked for failed commands
        await collector.waitForMeasurements(count: 1)
        let measurements = await collector.getMeasurements()
        
        XCTAssertEqual(measurements.count, 1)
        let measurement = measurements[0]
        XCTAssertEqual(measurement.commandName, "PerfTestCommand")
        XCTAssertGreaterThanOrEqual(measurement.executionTime, 0.005) // At least 5ms
        XCTAssertFalse(measurement.isSuccess)
        XCTAssertNotNil(measurement.errorMessage)
    }
    
    func testPerformanceMetadataCollection() async throws {
        // Given
        let collector = TestPerformanceCollector()
        let middleware = PerformanceMiddleware(
            collector: collector,
            includeDetailedMetrics: true
        )
        
        let command = PerfTestCommand(value: "test")
        let metadata = StandardCommandMetadata(userId: "user-123")
        let context = CommandContext(metadata: metadata)
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            cmd.value
        }
        
        // Then
        await collector.waitForMeasurements(count: 1)
        let measurements = await collector.getMeasurements()
        
        let measurement = measurements[0]
        // When includeDetailedMetrics is true, metrics should be included
        XCTAssertTrue(measurement.metrics.keys.contains("memoryUsage"))
        XCTAssertTrue(measurement.metrics.keys.contains("processId"))
    }
    
    func testPerformancePriority() {
        let middleware = PerformanceMiddleware()
        XCTAssertEqual(middleware.priority, .postProcessing)
    }
    
    func testConcurrentPerformanceTracking() async throws {
        // Given
        let collector = TestPerformanceCollector()
        let middleware = PerformanceMiddleware(collector: collector)
        
        // When - Execute multiple commands with varying performance
        let tasks = (0..<10).map { i in
            Task {
                let command = PerfTestCommand(value: "test-\(i)")
                let context = CommandContext()
                
                return try await middleware.execute(command, context: context) { cmd, _ in
                    // Vary execution time
                    let sleepTime = UInt64(i * 10_000_000) // i * 10ms
                    await self.synchronizer.shortDelay()
                    return cmd.value
                }
            }
        }
        
        // Then - All should complete with performance tracking
        for task in tasks {
            _ = try await task.value
        }
        
        await collector.waitForMeasurements(count: 10)
        let measurements = await collector.getMeasurements()
        
        XCTAssertEqual(measurements.count, 10)
        
        // All should be successful
        XCTAssertTrue(measurements.allSatisfy { $0.isSuccess })
    }
    
    func testPerformanceWithoutCollector() async throws {
        // Given - No collector provided
        let middleware = PerformanceMiddleware()
        
        let command = PerfTestCommand(value: "test")
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            cmd.value
        }
        
        // Then - Should still execute successfully
        XCTAssertEqual(result, "test")
        
        // Performance measurement should be stored in context
        let performanceData = context.get(PerformanceMeasurementKey.self)
        XCTAssertNotNil(performanceData)
        
        // Extract the actual measurement from the wrapper
        let measurement: PerformanceMeasurement? = performanceData?.get()
        XCTAssertNotNil(measurement)
        XCTAssertEqual(measurement?.commandName, "PerfTestCommand")
        XCTAssertTrue(measurement?.isSuccess ?? false)
    }
}

// Test support types
private struct PerfTestCommand: Command {
    typealias Result = String
    let value: String
    
    func execute() async throws -> String {
        return value
    }
}

private enum PerfTestError: Error {
    case intentionalFailure
}

private actor TestPerformanceCollector: PerformanceCollector {
    private var measurements: [PerformanceMeasurement] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    
    func record(_ measurement: PerformanceMeasurement) async {
        measurements.append(measurement)
        notifyWaiters()
    }
    
    func getMeasurements() -> [PerformanceMeasurement] {
        measurements
    }
    
    func waitForMeasurements(count: Int) async {
        while measurements.count < count {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }
    
    private func notifyWaiters() {
        let waiters = continuations
        continuations.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }
}