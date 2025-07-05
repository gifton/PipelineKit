import XCTest
import PipelineKit

/// Benchmarks comparing original and optimized implementations
final class OptimizationComparisons: XCTestCase {
    
    // MARK: - Pipeline Comparison
    
    func testStandardVsOptimizedPipeline() async throws {
        let handler = BenchmarkHandler()
        let config = BenchmarkConfiguration.default
        
        // Create both pipelines
        let standardPipeline = StandardPipeline(handler: handler)
        let optimizedPipeline = OptimizedStandardPipeline(handler: handler)
        
        // Add same middleware to both
        let middleware: [any Middleware] = [
            PerformanceMiddleware(),
            ValidationMiddleware(),
            AuthenticationMiddleware(authenticator: { _ in true })
        ]
        
        for mw in middleware {
            try await standardPipeline.addMiddleware(mw)
            try await optimizedPipeline.addMiddleware(mw)
        }
        
        // Warmup both
        for _ in 0..<config.warmupIterations {
            _ = try await standardPipeline.execute(
                BenchmarkCommand(payload: "warmup"),
                context: CommandContext()
            )
            _ = try await optimizedPipeline.execute(
                BenchmarkCommand(payload: "warmup"),
                context: CommandContext()
            )
        }
        
        // Measure standard pipeline
        let standardStart = Date()
        for i in 0..<config.measurementIterations {
            _ = try await standardPipeline.execute(
                BenchmarkCommand(payload: "test-\(i)"),
                context: CommandContext()
            )
        }
        let standardDuration = Date().timeIntervalSince(standardStart)
        
        // Measure optimized pipeline
        let optimizedStart = Date()
        for i in 0..<config.measurementIterations {
            _ = try await optimizedPipeline.execute(
                BenchmarkCommand(payload: "test-\(i)"),
                context: CommandContext()
            )
        }
        let optimizedDuration = Date().timeIntervalSince(optimizedStart)
        
        // Calculate improvement
        let improvement = ((standardDuration - optimizedDuration) / standardDuration) * 100
        
        print("""
        Pipeline Performance Comparison:
          Standard: \(String(format: "%.3f", standardDuration))s
          Optimized: \(String(format: "%.3f", optimizedDuration))s
          Improvement: \(String(format: "%.1f", improvement))%
        """)
        
        // Get pool statistics
        if let poolStats = await optimizedPipeline.poolStatistics() {
            print("  Pool stats: \(poolStats)")
        }
        
        XCTAssertLessThan(optimizedDuration, standardDuration, "Optimized should be faster")
    }
    
    // MARK: - Context Comparison
    
    func testStandardVsOptimizedContext() async throws {
        let iterations = 10000
        
        // Test standard context
        let standardStart = Date()
        let standardContext = CommandContext()
        
        for i in 0..<iterations {
            await standardContext.set("value-\(i)", for: TestKey.self)
            _ = await standardContext.get(TestKey.self)
            await standardContext.remove(TestKey.self)
        }
        
        let standardDuration = Date().timeIntervalSince(standardStart)
        
        // Test optimized context
        let optimizedStart = Date()
        let optimizedContext = OptimizedCommandContext()
        
        for i in 0..<iterations {
            await optimizedContext.set("value-\(i)", for: TestKey.self)
            _ = await optimizedContext.get(TestKey.self)
            await optimizedContext.remove(TestKey.self)
        }
        
        let optimizedDuration = Date().timeIntervalSince(optimizedStart)
        
        // Calculate improvement
        let improvement = ((standardDuration - optimizedDuration) / standardDuration) * 100
        
        print("""
        Context Performance Comparison:
          Standard: \(String(format: "%.3f", standardDuration))s
          Optimized: \(String(format: "%.3f", optimizedDuration))s
          Improvement: \(String(format: "%.1f", improvement))%
        """)
        
        XCTAssertLessThan(optimizedDuration, standardDuration, "Optimized context should be faster")
    }
    
    // MARK: - Memory Allocation Comparison
    
    func testMemoryAllocationComparison() async throws {
        let handler = MemoryIntensiveHandler()
        
        // Standard pipeline memory test
        let standardPipeline = StandardPipeline(handler: handler)
        let standardMemory = await BenchmarkUtilities.measureMemory(iterations: 50) {
            _ = try await standardPipeline.execute(
                MemoryIntensiveCommand(size: 1024 * 1024), // 1MB
                context: CommandContext()
            )
        }
        
        // Optimized pipeline memory test
        let optimizedPipeline = OptimizedStandardPipeline(handler: handler)
        let optimizedMemory = await BenchmarkUtilities.measureMemory(iterations: 50) {
            _ = try await optimizedPipeline.execute(
                MemoryIntensiveCommand(size: 1024 * 1024), // 1MB
                context: CommandContext()
            )
        }
        
        print("""
        Memory Allocation Comparison:
        
        Standard Pipeline:
        \(standardMemory)
        
        Optimized Pipeline:
        \(optimizedMemory)
        """)
        
        // Calculate improvement
        let memoryReduction = Double(standardMemory.averageAllocation - optimizedMemory.averageAllocation) / 
                             Double(standardMemory.averageAllocation) * 100
        
        print("Memory reduction: \(String(format: "%.1f", memoryReduction))%")
        
        XCTAssertLessThan(
            optimizedMemory.averageAllocation,
            standardMemory.averageAllocation,
            "Optimized should allocate less memory"
        )
    }
    
    // MARK: - Object Pool Effectiveness
    
    func testObjectPoolEffectiveness() async throws {
        let pool = CommandContextPool(maxSize: 100)
        
        // Pre-warm the pool
        await pool.pool.prewarm(count: 50)
        
        // Measure with pooling
        let pooledStart = Date()
        for _ in 0..<10000 {
            let context = await pool.acquire()
            await context.set("test", for: TestKey.self)
            await pool.release(context)
        }
        let pooledDuration = Date().timeIntervalSince(pooledStart)
        
        // Measure without pooling
        let unpooledStart = Date()
        for _ in 0..<10000 {
            let context = CommandContext()
            await context.set("test", for: TestKey.self)
        }
        let unpooledDuration = Date().timeIntervalSince(unpooledStart)
        
        // Get pool statistics
        let stats = await pool.statistics()
        
        print("""
        Object Pool Effectiveness:
          With pooling: \(String(format: "%.3f", pooledDuration))s
          Without pooling: \(String(format: "%.3f", unpooledDuration))s
          Pool statistics: \(stats)
        """)
        
        XCTAssertGreaterThan(stats.hitRate, 90, "Pool hit rate should be > 90%")
        XCTAssertLessThan(pooledDuration, unpooledDuration, "Pooling should be faster")
    }
    
    // MARK: - High Throughput Comparison
    
    func testHighThroughputComparison() async throws {
        let handler = BenchmarkHandler()
        let operationCount = 100000
        
        // Standard pipeline throughput
        let standardPipeline = StandardPipeline(handler: handler, maxConcurrency: 100)
        let standardThroughput = await BenchmarkUtilities.measureThroughput(
            operations: operationCount,
            timeout: 30
        ) {
            _ = try await standardPipeline.execute(
                BenchmarkCommand(payload: "throughput"),
                context: CommandContext()
            )
        }
        
        // Optimized pipeline throughput
        let optimizedPipeline = OptimizedStandardPipeline(handler: handler, maxConcurrency: 100)
        let optimizedThroughput = await BenchmarkUtilities.measureThroughput(
            operations: operationCount,
            timeout: 30
        ) {
            _ = try await optimizedPipeline.execute(
                BenchmarkCommand(payload: "throughput"),
                context: CommandContext()
            )
        }
        
        print("""
        High Throughput Comparison:
        
        Standard Pipeline:
        \(standardThroughput)
        
        Optimized Pipeline:
        \(optimizedThroughput)
        
        Throughput improvement: \(String(format: "%.1fx", optimizedThroughput.throughputPerSecond / standardThroughput.throughputPerSecond))
        """)
        
        XCTAssertGreaterThan(
            optimizedThroughput.throughputPerSecond,
            standardThroughput.throughputPerSecond,
            "Optimized should have higher throughput"
        )
    }
    
    // MARK: - Middleware Chain Caching
    
    func testMiddlewareChainCaching() async throws {
        let handler = BenchmarkHandler()
        let pipeline = OptimizedStandardPipeline(handler: handler)
        
        // Add many middleware
        for i in 0..<20 {
            try await pipeline.addMiddleware(MockMiddleware(id: i))
        }
        
        // First execution (builds chain)
        let firstStart = Date()
        _ = try await pipeline.execute(
            BenchmarkCommand(payload: "first"),
            context: CommandContext()
        )
        let firstDuration = Date().timeIntervalSince(firstStart)
        
        // Subsequent executions (uses cached chain)
        var subsequentDurations: [TimeInterval] = []
        for i in 0..<100 {
            let start = Date()
            _ = try await pipeline.execute(
                BenchmarkCommand(payload: "subsequent-\(i)"),
                context: CommandContext()
            )
            subsequentDurations.append(Date().timeIntervalSince(start))
        }
        
        let avgSubsequent = subsequentDurations.reduce(0, +) / Double(subsequentDurations.count)
        
        print("""
        Middleware Chain Caching:
          First execution: \(String(format: "%.3f", firstDuration * 1000))ms
          Average subsequent: \(String(format: "%.3f", avgSubsequent * 1000))ms
          Speedup: \(String(format: "%.1fx", firstDuration / avgSubsequent))
        """)
        
        XCTAssertLessThan(avgSubsequent, firstDuration, "Cached executions should be faster")
    }
}

// MARK: - Test Helpers

private struct TestKey: ContextKey {
    typealias Value = String
}