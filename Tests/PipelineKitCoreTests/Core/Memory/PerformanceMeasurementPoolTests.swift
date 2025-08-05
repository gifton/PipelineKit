import XCTest
@testable import PipelineKit
@testable import PipelineKitMiddleware

final class PerformanceMeasurementPoolTests: XCTestCase {
    func testBasicCreateMeasurement() async {
        // Given
        let pool = PerformanceMeasurementPool(maxSize: 10)
        
        // When
        let measurement = await pool.createMeasurement(
            commandName: "TestCommand",
            executionTime: 0.123,
            isSuccess: true
        )
        
        // Then
        XCTAssertEqual(measurement.commandName, "TestCommand")
        XCTAssertEqual(measurement.executionTime, 0.123)
        XCTAssertTrue(measurement.isSuccess)
        XCTAssertNil(measurement.errorMessage)
        XCTAssertTrue(measurement.metrics.isEmpty)
    }
    
    func testMeasurementWithAllProperties() async {
        // Given
        let pool = PerformanceMeasurementPool()
        let metrics: [String: PerformanceMetricValue] = [
            "cpu": .double(45.5),
            "memory": .int(1024),
            "cache": .string("hit")
        ]
        
        // When
        let measurement = await pool.createMeasurement(
            commandName: "ComplexCommand",
            executionTime: 1.567,
            isSuccess: false,
            errorMessage: "Test error",
            metrics: metrics
        )
        
        // Then
        XCTAssertEqual(measurement.commandName, "ComplexCommand")
        XCTAssertEqual(measurement.executionTime, 1.567)
        XCTAssertFalse(measurement.isSuccess)
        XCTAssertEqual(measurement.errorMessage, "Test error")
        XCTAssertEqual(measurement.metrics.count, 3)
        XCTAssertEqual(measurement.metrics["cpu"], .double(45.5))
        XCTAssertEqual(measurement.metrics["memory"], .int(1024))
        XCTAssertEqual(measurement.metrics["cache"], .string("hit"))
    }
    
    func testPoolStatistics() async {
        // Given
        let pool = PerformanceMeasurementPool(maxSize: 5)
        await pool.warmUp(count: 3)
        
        // When - Use several measurements
        for i in 0..<10 {
            _ = await pool.createMeasurement(
                commandName: "Command\(i)",
                executionTime: Double(i) * 0.1,
                isSuccess: true
            )
        }
        
        // Then
        let stats = await pool.getStatistics()
        XCTAssertGreaterThan(stats.totalBorrows, 0)
        XCTAssertGreaterThan(stats.totalReturns, 0)
        XCTAssertLessThanOrEqual(stats.highWaterMark, 5) // Should not exceed max size
    }
    
    func testConcurrentAccess() async {
        // Given
        let pool = PerformanceMeasurementPool(maxSize: 50)
        await pool.warmUp(count: 20)
        let iterations = 100
        
        // When - Create measurements concurrently
        await withTaskGroup(of: PerformanceMeasurement.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    await pool.createMeasurement(
                        commandName: "ConcurrentCommand\(i)",
                        executionTime: 0.001,
                        isSuccess: true
                    )
                }
            }
            
            // Collect all results
            var measurements: [PerformanceMeasurement] = []
            for await measurement in group {
                measurements.append(measurement)
            }
            
            // Then
            XCTAssertEqual(measurements.count, iterations)
            for measurement in measurements {
                XCTAssertEqual(measurement.executionTime, 0.001)
                XCTAssertTrue(measurement.isSuccess)
            }
        }
        
        // Verify stats
        let stats = await pool.getStatistics()
        XCTAssertEqual(stats.totalBorrows, iterations)
        XCTAssertEqual(stats.totalReturns, iterations)
        XCTAssertLessThanOrEqual(stats.inUse, 0) // All should be returned
    }
    
    func testPoolWarmup() async {
        // Given
        let pool = PerformanceMeasurementPool(maxSize: 100)
        
        // When
        await pool.warmUp(count: 50)
        
        // Then
        let stats = await pool.getStatistics()
        XCTAssertGreaterThanOrEqual(stats.totalCreated, 50)
        XCTAssertGreaterThanOrEqual(stats.currentSize, 50)
    }
    
    func testClearPool() async {
        // Given
        let pool = PerformanceMeasurementPool(maxSize: 20)
        await pool.warmUp(count: 10)
        
        // Use some objects
        _ = await pool.createMeasurement(
            commandName: "BeforeClear",
            executionTime: 0.1,
            isSuccess: true
        )
        
        // When
        await pool.clear()
        let stats = await pool.getStatistics()
        
        // Then
        XCTAssertEqual(stats.currentSize, 0)
        XCTAssertEqual(stats.totalCreated, 0)
    }
    
    func testSharedPoolInstance() async {
        // Given
        let pool1 = PerformanceMeasurementPool.shared
        let pool2 = PerformanceMeasurementPool.shared
        
        // Then - Should be the same instance
        XCTAssertTrue(pool1 === pool2)
        
        // Verify it works
        let measurement = await pool1.createMeasurement(
            commandName: "SharedPoolCommand",
            executionTime: 0.5,
            isSuccess: true
        )
        
        XCTAssertEqual(measurement.commandName, "SharedPoolCommand")
    }
    
    func testIntegrationWithPerformanceMiddleware() async {
        // Given - Use the static method that uses the shared pool
        let metrics: [String: PerformanceMetricValue] = [
            "requestSize": .int(1024),
            "responseTime": .double(0.250)
        ]
        
        // When
        let measurement = await PerformanceMeasurementPool.shared.createMeasurement(
            commandName: "IntegrationTest",
            executionTime: 0.123,
            isSuccess: true,
            errorMessage: nil,
            metrics: metrics
        )
        
        // Then
        XCTAssertEqual(measurement.commandName, "IntegrationTest")
        XCTAssertEqual(measurement.executionTime, 0.123)
        XCTAssertTrue(measurement.isSuccess)
        XCTAssertEqual(measurement.metrics.count, 2)
    }
    
    func testPerformanceComparison() async {
        // Given
        let pool = PerformanceMeasurementPool(maxSize: 100)
        await pool.warmUp(count: 100)
        
        let iterations = 1000
        
        // When - Measure pooled performance
        let pooledStart = Date()
        for i in 0..<iterations {
            _ = await pool.createMeasurement(
                commandName: "PerfTest\(i)",
                executionTime: 0.001,
                isSuccess: true
            )
        }
        let pooledTime = Date().timeIntervalSince(pooledStart)
        
        // When - Measure direct allocation performance
        let unpooledStart = Date()
        for i in 0..<iterations {
            _ = PerformanceMeasurement(
                commandName: "PerfTest\(i)",
                executionTime: 0.001,
                isSuccess: true,
                errorMessage: nil,
                metrics: [:]
            )
        }
        let unpooledTime = Date().timeIntervalSince(unpooledStart)
        
        // Then
        let stats = await pool.getStatistics()
        print("Pooled time: \(pooledTime)s")
        print("Unpooled time: \(unpooledTime)s")
        print("Pool total borrows: \(stats.totalBorrows)")
        print("Pool total returns: \(stats.totalReturns)")
        
        // Pooling should have tracked all borrows and returns
        XCTAssertEqual(stats.totalBorrows, iterations) // Only counts actual usage
        XCTAssertEqual(stats.totalReturns, iterations)
    }
}
