import XCTest
@testable import PipelineKit

final class ConcurrencyBenchmarks: XCTestCase {
    
    struct BenchmarkCommand: Command {
        typealias Result = Int
        let value: Int
        let complexity: Int // Simulated work complexity
    }
    
    struct BenchmarkHandler: CommandHandler {
        typealias CommandType = BenchmarkCommand
        
        func handle(_ command: BenchmarkCommand) async throws -> Int {
            // Simulate work based on complexity
            if command.complexity > 0 {
                for _ in 0..<command.complexity {
                    _ = (0..<100).reduce(0, +)
                }
            }
            return command.value * 2
        }
    }
    
    func testBatchingPerformance() async throws {
        let pipeline = StandardPipeline(handler: BenchmarkHandler())
        let batchProcessor = BatchProcessor(pipeline: pipeline)
        
        let commands = (0..<10000).map { BenchmarkCommand(value: $0, complexity: 10) }
        
        // Measure batch processing
        let batchStart = CFAbsoluteTimeGetCurrent()
        
        let results = try await batchProcessor.submitBatch(commands)
        
        let batchTime = CFAbsoluteTimeGetCurrent() - batchStart
        
        // Measure sequential processing for comparison
        let sequentialStart = CFAbsoluteTimeGetCurrent()
        
        for command in commands.prefix(1000) { // Only 1000 for time
            _ = try await pipeline.execute(command)
        }
        
        let sequentialTime = (CFAbsoluteTimeGetCurrent() - sequentialStart) * 10 // Extrapolate
        
        print("Batch processing time: \(batchTime)s")
        print("Sequential processing time (estimated): \(sequentialTime)s")
        print("Speedup: \(sequentialTime / batchTime)x")
        
        XCTAssertLessThan(batchTime, sequentialTime * 0.4) // At least 2.5x faster
        XCTAssertEqual(results.count, commands.count)
    }
    
    func testParallelMiddlewarePerformance() async throws {
        // Create middleware that can run in parallel
        let middlewares: [any Middleware] = [
            LoggingMiddleware(),
            MetricsMiddleware(),
            TracingMiddleware(),
            ValidationMiddleware(),
            CacheMiddleware()
        ]
        
        // Test with sequential pipeline
        let sequentialPipeline = StandardPipeline(handler: BenchmarkHandler())
        for middleware in middlewares {
            try await sequentialPipeline.addMiddleware(middleware)
        }
        
        // Test with parallel pipeline
        let parallelPipeline = ParallelPipeline(handler: BenchmarkHandler())
        for middleware in middlewares {
            await parallelPipeline.addMiddleware(middleware)
        }
        
        let testCommand = BenchmarkCommand(value: 42, complexity: 100)
        let iterations = 1000
        
        // Measure sequential
        let sequentialStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try await sequentialPipeline.execute(testCommand)
        }
        let sequentialTime = CFAbsoluteTimeGetCurrent() - sequentialStart
        
        // Measure parallel
        let parallelStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try await parallelPipeline.execute(testCommand)
        }
        let parallelTime = CFAbsoluteTimeGetCurrent() - parallelStart
        
        print("Sequential middleware execution: \(sequentialTime)s")
        print("Parallel middleware execution: \(parallelTime)s")
        print("Speedup: \(sequentialTime / parallelTime)x")
        
        XCTAssertLessThan(parallelTime, sequentialTime * 0.7) // At least 30% faster
    }
    
    func testWorkStealingPerformance() async throws {
        let executor = WorkStealingPipelineExecutor(workerCount: 8)
        
        // Create workload with varying complexity
        let workItems = (0..<1000).map { i in
            let complexity = i % 4 == 0 ? 1000 : 100 // Some items are 10x more complex
            return { () -> Int in
                var sum = 0
                for j in 0..<complexity {
                    sum += j
                }
                return sum
            }
        }
        
        let start = CFAbsoluteTimeGetCurrent()
        
        let results = await withTaskGroup(of: Int.self) { group in
            for work in workItems {
                group.addTask {
                    try! await executor.execute(work)
                }
            }
            
            var results: [Int] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("Work-stealing execution time: \(elapsed)s")
        print("Average time per item: \(elapsed / Double(workItems.count) * 1000)ms")
        
        XCTAssertEqual(results.count, workItems.count)
    }
    
    func testAdaptiveConcurrencyPerformance() async throws {
        let basePipeline = StandardPipeline(handler: BenchmarkHandler())
        let adaptivePipeline = AdaptivePipeline(basePipeline: basePipeline)
        
        // Simulate varying load
        for phase in 0..<3 {
            let load = phase == 1 ? 1000 : 100 // High load in middle phase
            let commands = (0..<load).map { BenchmarkCommand(value: $0, complexity: 10) }
            
            let start = CFAbsoluteTimeGetCurrent()
            
            await withTaskGroup(of: Void.self) { group in
                for command in commands {
                    group.addTask {
                        _ = try? await adaptivePipeline.execute(command)
                    }
                }
            }
            
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let metrics = await adaptivePipeline.getAdaptiveMetrics()
            
            print("Phase \(phase) (load: \(load)): \(elapsed)s")
            print("  Concurrency limit: \(metrics.currentConcurrencyLimit)")
            print("  Utilization: \(metrics.utilizationPercent)%")
        }
    }
    
    func testLockFreePerformance() async throws {
        let lockFreePipeline = LockFreePipeline(handler: BenchmarkHandler())
        let standardPipeline = StandardPipeline(handler: BenchmarkHandler())
        
        let commands = (0..<10000).map { BenchmarkCommand(value: $0, complexity: 1) }
        
        // Test lock-free
        let lockFreeStart = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for command in commands {
                group.addTask {
                    _ = try? await lockFreePipeline.execute(command)
                }
            }
        }
        
        let lockFreeTime = CFAbsoluteTimeGetCurrent() - lockFreeStart
        
        // Test standard
        let standardStart = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for command in commands.prefix(1000) { // Fewer for time
                group.addTask {
                    _ = try? await standardPipeline.execute(command)
                }
            }
        }
        
        let standardTime = (CFAbsoluteTimeGetCurrent() - standardStart) * 10
        
        print("Lock-free pipeline: \(lockFreeTime)s")
        print("Standard pipeline (estimated): \(standardTime)s")
        print("Speedup: \(standardTime / lockFreeTime)x")
        
        // Check metrics
        let metrics = await lockFreePipeline.performanceMetrics
        print("Average latency: \(metrics.averageLatency * 1000)ms")
        print("Max latency: \(metrics.maxLatencySeconds * 1000)ms")
        print("Success rate: \(metrics.successRate * 100)%")
        
        XCTAssertLessThan(lockFreeTime, standardTime * 0.5) // At least 2x faster
    }
    
    func testOptimizedConcurrentPipeline() async throws {
        let standard = ConcurrentPipeline()
        let optimized = OptimizedConcurrentPipeline(shardCount: 16)
        
        let pipeline = StandardPipeline(handler: BenchmarkHandler())
        
        // Register many command types
        for i in 0..<100 {
            await standard.register(BenchmarkCommand.self, pipeline: pipeline)
            await optimized.register(BenchmarkCommand.self, pipeline: pipeline)
        }
        
        let commands = (0..<10000).map { BenchmarkCommand(value: $0, complexity: 1) }
        
        // Test standard
        let standardStart = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for command in commands.prefix(1000) {
                group.addTask {
                    _ = try? await standard.execute(command)
                }
            }
        }
        
        let standardTime = (CFAbsoluteTimeGetCurrent() - standardStart) * 10
        
        // Test optimized
        let optimizedStart = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for command in commands {
                group.addTask {
                    _ = try? await optimized.execute(command)
                }
            }
        }
        
        let optimizedTime = CFAbsoluteTimeGetCurrent() - optimizedStart
        
        print("Standard concurrent pipeline: \(standardTime)s")
        print("Optimized concurrent pipeline: \(optimizedTime)s")
        print("Speedup: \(standardTime / optimizedTime)x")
        
        XCTAssertLessThan(optimizedTime, standardTime * 0.8) // At least 20% faster
    }
}

// MARK: - Mock Middleware for Testing

struct LoggingMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate logging
        _ = String(describing: command)
        return try await next(command, context)
    }
}

struct MetricsMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await next(command, context)
        _ = CFAbsoluteTimeGetCurrent() - start
        return result
    }
}

struct TracingMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        await context.set(UUID().uuidString, for: TraceIDKey.self)
        return try await next(command, context)
    }
}

struct ValidationMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate validation
        if let validatable = command as? any ValidatableCommand {
            try await validatable.validate()
        }
        return try await next(command, context)
    }
}

struct CacheMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate cache check
        let cacheKey = String(describing: command).hashValue
        _ = cacheKey
        return try await next(command, context)
    }
}

struct TraceIDKey: ContextKey {
    typealias Value = String
}