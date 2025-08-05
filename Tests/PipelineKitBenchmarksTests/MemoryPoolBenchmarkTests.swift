import XCTest
@testable import PipelineKit

/// Benchmarks to measure memory pool performance and hit rates
final class MemoryPoolBenchmarkTests: XCTestCase {
    // MARK: - Test Types
    
    private struct StringKey: ContextKey {
        typealias Value = String
    }
    
    private struct IntKey: ContextKey {
        typealias Value = Int
    }
    
    // MARK: - Current Implementation Baseline
    
    // REMOVED: CommandContext pool test removed as pooling degrades performance
    // Direct allocation is 19-51% faster than pooling for lightweight objects
    
    func testPerformanceMeasurementPoolPerformance() async throws {
        let pool = PerformanceMeasurementPool.shared
        
        // Clear and warm up
        await pool.clear()
        await pool.warmUp(count: 50)
        
        let iterations = 10_000
        let concurrentTasks = 50
        
        // Get baseline stats
        let baselineStats = await pool.getStatistics()
        print("\n=== Baseline PerformanceMeasurement Pool ===")
        print("Pre-warmed objects: \(baselineStats.currentSize)")
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrentTasks {
                group.addTask {
                    for i in 0..<(iterations / concurrentTasks) {
                        _ = await pool.createMeasurement(
                            commandName: "TestCommand-\(i)",
                            executionTime: 0.001,
                            isSuccess: !i.isMultiple(of: 10),
                            errorMessage: i.isMultiple(of: 10) ? "Test error" : nil,
                            metrics: ["iteration": .int(i)]
                        )
                    }
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        let stats = await pool.getStatistics()
        
        print("\n=== PerformanceMeasurement Pool Performance ===")
        print("Duration: \(String(format: "%.3f", duration))s")
        print("Measurements/sec: \(String(format: "%.1f", Double(iterations) / duration / 1000))K")
        print("Total created: \(stats.totalCreated)")
        print("High water mark: \(stats.highWaterMark)")
        
        // Calculate hit rate manually
        let hitRate = stats.totalBorrows > 0
            ? Double(stats.totalBorrows - stats.totalCreated) / Double(stats.totalBorrows)
            : 0.0
        print("Hit rate: \(String(format: "%.1f", hitRate * 100))%")
        print("Pool efficiency: \(String(format: "%.1f", Double(stats.totalCreated) / Double(iterations) * 100))%")
    }
    
    func testPoolWithAndWithoutWarmup() async throws {
        // Test with warmup
        let warmPool = PerformanceMeasurementPool(maxSize: 100)
        await warmPool.warmUp(count: 50)
        
        let iterations = 5_000
        
        let warmStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            _ = await warmPool.createMeasurement(
                commandName: "Test-\(i)",
                executionTime: 0.001,
                isSuccess: true
            )
        }
        let warmDuration = CFAbsoluteTimeGetCurrent() - warmStart
        let warmStats = await warmPool.getStatistics()
        
        // Test without warmup
        let coldPool = PerformanceMeasurementPool(maxSize: 100)
        
        let coldStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            _ = await coldPool.createMeasurement(
                commandName: "Test-\(i)",
                executionTime: 0.001,
                isSuccess: true
            )
        }
        let coldDuration = CFAbsoluteTimeGetCurrent() - coldStart
        let coldStats = await coldPool.getStatistics()
        
        print("\n=== Pool Warmup Comparison ===")
        print("With warmup:")
        print("  Duration: \(String(format: "%.3f", warmDuration))s")
        print("  Total created: \(warmStats.totalCreated)")
        print("  Hit rate: \(String(format: "%.1f", Double(warmStats.totalBorrows - warmStats.totalCreated) / Double(warmStats.totalBorrows) * 100))%")
        
        print("\nWithout warmup:")
        print("  Duration: \(String(format: "%.3f", coldDuration))s")
        print("  Total created: \(coldStats.totalCreated)")
        print("  Hit rate: \(String(format: "%.1f", Double(coldStats.totalBorrows - coldStats.totalCreated) / Double(coldStats.totalBorrows) * 100))%")
        
        let improvement = ((coldDuration - warmDuration) / coldDuration) * 100
        print("\nWarmup improvement: \(String(format: "%.1f", improvement))%")
    }
}
