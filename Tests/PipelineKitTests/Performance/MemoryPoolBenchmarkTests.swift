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
    
    func testCommandContextPoolPerformance() async throws {
        let pool = CommandContextPool.shared
        
        // Clear pool
        pool.clear()
        
        let iterations = 10_000
        let concurrentTasks = 50
        
        // Baseline stats
        let baselineStats = pool.getStatistics()
        print("\n=== Baseline Pool Stats ===")
        print("Hit rate: \(String(format: "%.1f", baselineStats.hitRate * 100))%")
        print("Total allocated: \(baselineStats.totalAllocated)")
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrentTasks {
                group.addTask {
                    for _ in 0..<(iterations / concurrentTasks) {
                        let metadata = StandardCommandMetadata(
                            id: UUID(),
                            timestamp: Date(),
                            correlationId: nil
                        )
                        let pooledContext = pool.borrow(metadata: metadata)
                        let context = pooledContext.value
                        
                        // Simulate usage
                        context.set("value", for: StringKey.self)
                        context.set(42, for: IntKey.self)
                        _ = context.get(StringKey.self)
                        _ = context.get(IntKey.self)
                        
                        // PooledCommandContext returns itself when deallocated
                    }
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        let stats = pool.getStatistics()
        
        print("\n=== CommandContext Pool Performance ===")
        print("Duration: \(String(format: "%.3f", duration))s")
        print("Contexts/sec: \(String(format: "%.1f", Double(iterations) / duration / 1000))K")
        print("Hit rate: \(String(format: "%.1f", stats.hitRate * 100))%")
        print("Total allocated: \(stats.totalAllocated)")
        print("Currently in use: \(stats.currentlyInUse)")
        print("Pool efficiency: \(String(format: "%.1f", Double(stats.totalAllocated) / Double(iterations) * 100))%")
    }
    
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
                            isSuccess: i % 10 != 0,
                            errorMessage: i % 10 == 0 ? "Test error" : nil,
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