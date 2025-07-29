import XCTest
@testable import PipelineKitBenchmarks

final class StatisticsTests: XCTestCase {
    
    func testBasicStatisticsCalculation() {
        // Given
        let measurements = [
            BenchmarkMeasurement(duration: 0.001, memoryUsed: nil, allocations: nil, peakMemory: nil),
            BenchmarkMeasurement(duration: 0.002, memoryUsed: nil, allocations: nil, peakMemory: nil),
            BenchmarkMeasurement(duration: 0.003, memoryUsed: nil, allocations: nil, peakMemory: nil),
            BenchmarkMeasurement(duration: 0.004, memoryUsed: nil, allocations: nil, peakMemory: nil),
            BenchmarkMeasurement(duration: 0.005, memoryUsed: nil, allocations: nil, peakMemory: nil)
        ]
        
        // When
        let stats = Statistics.calculate(from: measurements)
        
        // Then
        XCTAssertEqual(stats.count, 5)
        XCTAssertEqual(stats.mean, 0.003, accuracy: 0.0001)
        XCTAssertEqual(stats.median, 0.003, accuracy: 0.0001)
        XCTAssertEqual(stats.min, 0.001, accuracy: 0.0001)
        XCTAssertEqual(stats.max, 0.005, accuracy: 0.0001)
        XCTAssertGreaterThan(stats.standardDeviation, 0)
    }
    
    func testPercentileCalculation() {
        // Given - 100 measurements from 1ms to 100ms
        let measurements = (1...100).map { i in
            BenchmarkMeasurement(
                duration: Double(i) * 0.001,
                memoryUsed: nil,
                allocations: nil,
                peakMemory: nil
            )
        }
        
        // When
        let stats = Statistics.calculate(from: measurements)
        
        // Then
        XCTAssertNotNil(stats.p95)
        XCTAssertNotNil(stats.p99)
        
        if let p95 = stats.p95 {
            XCTAssertEqual(p95, 0.095, accuracy: 0.001)
        }
        
        if let p99 = stats.p99 {
            XCTAssertEqual(p99, 0.099, accuracy: 0.001)
        }
    }
    
    func testOutlierRemoval() {
        // Given - Normal distribution with outliers
        var measurements: [BenchmarkMeasurement] = []
        
        // Add normal measurements around 10ms
        for _ in 0..<18 {
            measurements.append(BenchmarkMeasurement(
                duration: 0.010 + Double.random(in: -0.002...0.002),
                memoryUsed: nil,
                allocations: nil,
                peakMemory: nil
            ))
        }
        
        // Add outliers
        measurements.append(BenchmarkMeasurement(duration: 0.100, memoryUsed: nil, allocations: nil, peakMemory: nil)) // 100ms
        measurements.append(BenchmarkMeasurement(duration: 0.001, memoryUsed: nil, allocations: nil, peakMemory: nil)) // 1ms
        
        // When
        let cleaned = Statistics.removeOutliers(from: measurements)
        
        // Then
        XCTAssertLessThan(cleaned.count, measurements.count)
        XCTAssertEqual(cleaned.count, 18, "Should remove the 2 outliers")
        
        // All remaining values should be close to 10ms
        for measurement in cleaned {
            XCTAssertLessThan(abs(measurement.duration - 0.010), 0.005)
        }
    }
    
    func testStatisticalSignificance() {
        // Given - Two different distributions
        let baseline = BenchmarkStatistics(
            count: 100,
            mean: 0.010,
            median: 0.010,
            standardDeviation: 0.001,
            min: 0.008,
            max: 0.012,
            p95: 0.011,
            p99: 0.012
        )
        
        let current = BenchmarkStatistics(
            count: 100,
            mean: 0.012, // 20% slower
            median: 0.012,
            standardDeviation: 0.001,
            min: 0.010,
            max: 0.014,
            p95: 0.013,
            p99: 0.014
        )
        
        // When
        let isDifferent = Statistics.areStatisticallyDifferent(
            baseline: baseline,
            current: current
        )
        
        // Then
        XCTAssertTrue(isDifferent, "20% difference should be statistically significant")
    }
    
    func testTDistributionCriticalValues() {
        // Test that our t-distribution implementation gives reasonable values
        
        // Small degrees of freedom
        let smallDf = BenchmarkStatistics(
            count: 5, // df = 4
            mean: 10.0,
            median: 10.0,
            standardDeviation: 1.0,
            min: 8.0,
            max: 12.0,
            p95: nil,
            p99: nil
        )
        
        let smallDfSimilar = BenchmarkStatistics(
            count: 5,
            mean: 10.5, // Small difference
            median: 10.5,
            standardDeviation: 1.0,
            min: 8.5,
            max: 12.5,
            p95: nil,
            p99: nil
        )
        
        // Large degrees of freedom
        let largeDf = BenchmarkStatistics(
            count: 200, // df >> 120
            mean: 10.0,
            median: 10.0,
            standardDeviation: 1.0,
            min: 8.0,
            max: 12.0,
            p95: 11.0,
            p99: 12.0
        )
        
        let largeDfSimilar = BenchmarkStatistics(
            count: 200,
            mean: 10.1, // Very small difference
            median: 10.1,
            standardDeviation: 1.0,
            min: 8.1,
            max: 12.1,
            p95: 11.1,
            p99: 12.1
        )
        
        // Small df requires larger difference to be significant
        let smallDfSignificant = Statistics.areStatisticallyDifferent(
            baseline: smallDf,
            current: smallDfSimilar
        )
        XCTAssertFalse(smallDfSignificant, "Small difference with few samples should not be significant")
        
        // Large df can detect smaller differences
        let largeDfSignificant = Statistics.areStatisticallyDifferent(
            baseline: largeDf,
            current: largeDfSimilar
        )
        // This might or might not be significant depending on exact calculation
    }
    
    func testMemoryStatistics() {
        // Given
        let measurements = [
            BenchmarkMeasurement(duration: 0.001, memoryUsed: 1024, allocations: 10, peakMemory: 2048),
            BenchmarkMeasurement(duration: 0.002, memoryUsed: 2048, allocations: 20, peakMemory: 3072),
            BenchmarkMeasurement(duration: 0.003, memoryUsed: 1536, allocations: 15, peakMemory: 2560)
        ]
        
        // When
        let memStats = Statistics.calculateMemory(from: measurements)
        
        // Then
        XCTAssertNotNil(memStats)
        if let stats = memStats {
            XCTAssertEqual(stats.averageMemory, 1536, accuracy: 1)
            XCTAssertEqual(stats.peakMemory, 3072)
            XCTAssertEqual(stats.totalAllocations, 45)
            XCTAssertEqual(stats.averageAllocations, 15, accuracy: 0.1)
        }
    }
    
    func testBenchmarkComparison() {
        // Given
        let baseline = createMockResult(name: "Test", mean: 0.010, median: 0.010)
        let faster = createMockResult(name: "Test", mean: 0.008, median: 0.008) // 20% faster
        let slower = createMockResult(name: "Test", mean: 0.015, median: 0.015) // 50% slower
        
        // When
        let fasterComparison = BenchmarkComparison(baseline: baseline, current: faster)
        let slowerComparison = BenchmarkComparison(baseline: baseline, current: slower)
        
        // Then
        XCTAssertLessThan(fasterComparison.percentageChange, 0)
        XCTAssertTrue(fasterComparison.message.contains("faster"))
        XCTAssertFalse(fasterComparison.isRegression)
        
        XCTAssertGreaterThan(slowerComparison.percentageChange, 0)
        XCTAssertTrue(slowerComparison.isRegression)
        XCTAssertTrue(slowerComparison.message.contains("regression"))
    }
    
    // MARK: - Helpers
    
    private func createMockResult(name: String, mean: Double, median: Double) -> BenchmarkResult {
        let stats = BenchmarkStatistics(
            count: 100,
            mean: mean,
            median: median,
            standardDeviation: mean * 0.1,
            min: mean * 0.8,
            max: mean * 1.2,
            p95: mean * 1.15,
            p99: mean * 1.18
        )
        
        let measurements = (0..<100).map { _ in
            BenchmarkMeasurement(
                duration: mean + Double.random(in: -mean*0.1...mean*0.1),
                memoryUsed: nil,
                allocations: nil,
                peakMemory: nil
            )
        }
        
        return BenchmarkResult(
            name: name,
            measurements: measurements,
            statistics: stats,
            memoryStatistics: nil,
            metadata: BenchmarkMetadata(),
            warnings: []
        )
    }
}