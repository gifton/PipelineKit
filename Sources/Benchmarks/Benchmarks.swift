import Benchmark
import Foundation
import PipelineKit
import PipelineKitCore
import PipelineKitPooling
import PipelineKitResilience

// MARK: - Test Types

struct TestCommand: Command {
    typealias Result = Int
    let value: Int = 42
}

final class TestHandler: CommandHandler {
    typealias CommandType = TestCommand
    
    func handle(_ command: TestCommand) async throws -> Int {
        return command.value
    }
}

final class SlowHandler: CommandHandler {
    typealias CommandType = TestCommand
    
    func handle(_ command: TestCommand) async throws -> Int {
        // Simulate small amount of work without actually sleeping
        var sum = 0
        for i in 0..<100 {
            sum += i
        }
        return sum
    }
}

struct LoggingMiddleware: Middleware {
    let priority = ExecutionPriority.custom
    
    func execute<C: Command>(_ command: C, 
                             context: CommandContext,
                             next: @escaping @Sendable (C, CommandContext) async throws -> C.Result) async throws -> C.Result {
        return try await next(command, context)
    }
}

struct ValidationMiddleware: Middleware {
    let priority = ExecutionPriority.validation
    
    func execute<C: Command>(_ command: C, 
                             context: CommandContext,
                             next: @escaping @Sendable (C, CommandContext) async throws -> C.Result) async throws -> C.Result {
        // Simple validation - just pass through
        return try await next(command, context)
    }
}

final class PoolableResource: @unchecked Sendable {
    var value: Int
    let id = UUID()
    
    init() {
        self.value = Int.random(in: 0..<100)
    }
    
    func reset() {
        self.value = Int.random(in: 0..<100)
    }
}

// MARK: - Benchmarks

@main
struct PipelineKitBenchmarks {
    static func main() {
        // Configure benchmarks with reasonable defaults
        var config = Benchmark.Configuration()
        config.maxDuration = .seconds(30)
        config.maxIterations = 100_000
        config.warmupIterations = 100
        config.scalingFactor = .kilo
        config.metrics = [.cpuTotal, .wallClock, .mallocCountTotal, .throughput]
        
        // MARK: Pipeline Benchmarks
        
        Benchmark("Pipeline.simple",
                 configuration: config) { benchmark in
            let pipeline = StandardPipeline(handler: TestHandler())
            let context = CommandContext()
            
            for _ in benchmark.scaledIterations {
                _ = try await pipeline.execute(TestCommand(), context: context)
            }
        }
        
        Benchmark("Pipeline.withMiddleware",
                 configuration: config) { benchmark in
            let pipeline = StandardPipeline(handler: TestHandler())
            try await pipeline.addMiddleware(LoggingMiddleware())
            try await pipeline.addMiddleware(ValidationMiddleware())
            let context = CommandContext()
            
            for _ in benchmark.scaledIterations {
                _ = try await pipeline.execute(TestCommand(), context: context)
            }
        }
        
        Benchmark("Pipeline.concurrent",
                 configuration: config) { benchmark in
            let pipeline = StandardPipeline(handler: SlowHandler())
            let context = CommandContext()
            
            let iterations = benchmark.scaledIterations
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<min(iterations.count, 10) {
                    group.addTask {
                        for _ in 0..<(iterations.count / 10) {
                            _ = try? await pipeline.execute(TestCommand(), context: context)
                        }
                    }
                }
            }
        }
        
        // MARK: CommandContext Benchmarks
        
        Benchmark("CommandContext.setMetadata",
                 configuration: config) { benchmark in
            let context = CommandContext()
            for i in benchmark.scaledIterations {
                await context.setMetadata("key-\(i)", value: i)
            }
        }
        
        Benchmark("CommandContext.getMetadata",
                 configuration: config) { benchmark in
            let context = CommandContext()
            await context.setMetadata("test", value: 42)
            
            for _ in benchmark.scaledIterations {
                _ = await context.metadata["test"]
            }
        }
        
        Benchmark("CommandContext.concurrent",
                 configuration: config) { benchmark in
            let context = CommandContext()
            let iterations = benchmark.scaledIterations
            
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<min(10, iterations.count) {
                    group.addTask {
                        for j in 0..<(iterations.count / 10) {
                            await context.setMetadata("key-\(i)-\(j)", value: j)
                            _ = await context.metadata["key-\(i)-\(j)"]
                        }
                    }
                }
            }
        }
        
        // MARK: ObjectPool Benchmarks
        
        Benchmark("ObjectPool.acquire",
                 configuration: config) { benchmark in
            let pool = ObjectPool<PoolableResource>(
                configuration: try ObjectPoolConfiguration(maxSize: 10),
                factory: { PoolableResource() },
                reset: { $0.reset() }
            )
            
            for _ in benchmark.scaledIterations {
                let obj = try await pool.acquire()
                await pool.release(obj)
            }
        }
        
        Benchmark("ObjectPool.concurrent",
                 configuration: config) { benchmark in
            let pool = ObjectPool<PoolableResource>(
                configuration: try ObjectPoolConfiguration(maxSize: 10),
                factory: { PoolableResource() },
                reset: { $0.reset() }
            )
            
            let iterations = benchmark.scaledIterations
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<min(iterations.count, 10) {
                    group.addTask {
                        for _ in 0..<(iterations.count / 10) {
                            let obj = try? await pool.acquire()
                            if let obj = obj {
                                await pool.release(obj)
                            }
                        }
                    }
                }
            }
        }
        
        // MARK: BackPressure Benchmarks
        
        Benchmark("BackPressure.acquire",
                 configuration: config) { benchmark in
            let semaphore = BackPressureSemaphore(maxConcurrency: 100)
            
            for _ in benchmark.scaledIterations {
                let token = try await semaphore.acquire()
                // Token automatically releases when deallocated
                _ = token
            }
        }
        
        Benchmark("BackPressure.tryAcquire",
                 configuration: config) { benchmark in
            let semaphore = BackPressureSemaphore(maxConcurrency: 100)
            
            for _ in benchmark.scaledIterations {
                if let token = await semaphore.tryAcquire() {
                    // Token automatically releases when deallocated
                    _ = token
                }
            }
        }
        
        Benchmark("BackPressure.contention",
                 configuration: config) { benchmark in
            let semaphore = BackPressureSemaphore(maxConcurrency: 5)
            let iterations = benchmark.scaledIterations
            
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        for _ in 0..<(iterations.count / 10) {
                            let token = try? await semaphore.acquire()
                            // Token automatically releases when deallocated
                            _ = token
                        }
                    }
                }
            }
        }
        
        // MARK: TimeoutMiddleware Benchmarks
        
        Benchmark("Timeout.noTimeout",
                 configuration: config) { benchmark in
            let pipeline = StandardPipeline(handler: TestHandler())
            try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 10.0))
            let context = CommandContext()
            
            for _ in benchmark.scaledIterations {
                _ = try await pipeline.execute(TestCommand(), context: context)
            }
        }
        
        Benchmark("Timeout.withCancellation",
                 configuration: config) { benchmark in
            let pipeline = StandardPipeline(handler: SlowHandler())
            try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 10.0))
            let context = CommandContext()
            
            for _ in benchmark.scaledIterations {
                _ = try? await pipeline.execute(TestCommand(), context: context)
            }
        }
    }
}