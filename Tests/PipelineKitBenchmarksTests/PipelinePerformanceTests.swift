import XCTest
@testable import PipelineKit

final class PipelinePerformanceTests: PerformanceBenchmark {
    struct BenchmarkCommand: Command {
        typealias Result = Int
        let value: Int
    }
    
    struct BenchmarkHandler: CommandHandler {
        typealias CommandType = BenchmarkCommand
        
        func handle(_ command: BenchmarkCommand) async throws -> Int {
            return command.value * 2
        }
    }
    
    struct CounterMiddleware: Middleware {
        let counter: Actor<Int>
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            await counter.increment()
            return try await next(command, context)
        }
    }
    
    actor Actor <T: Sendable> {
        private var value: T
        
        init(_ value: T) {
            self.value = value
        }
        
        func get() -> T {
            value
        }
        
        func increment() where T == Int {
            value += 1
        }
    }
    
    func testPipelineExecutionPerformance() async throws {
        // Benchmark basic pipeline execution
        let pipeline = StandardPipeline(handler: BenchmarkHandler())
        let command = BenchmarkCommand(value: 42)
        let context = CommandContext()
        
        try await benchmark("Pipeline Execution") {
            _ = try await pipeline.execute(command, context: context)
        }
    }
    
    func testPipelineThroughput() async throws {
        // Measure operations per second
        let pipeline = StandardPipeline(handler: BenchmarkHandler())
        let command = BenchmarkCommand(value: 42)
        let context = CommandContext()
        
        try await benchmarkThroughput("Pipeline Throughput") {
            _ = try await pipeline.execute(command, context: context)
        }
    }
    
    func testPipelineLatency() async throws {
        // Measure latency percentiles
        let pipeline = StandardPipeline(handler: BenchmarkHandler())
        let command = BenchmarkCommand(value: 42)
        let context = CommandContext()
        
        try await benchmarkLatency("Pipeline Latency", samples: 1000) {
            _ = try await pipeline.execute(command, context: context)
        }
    }
    
    func testOriginalPipelinePerformance() async throws {
        let pipeline = StandardPipeline(handler: BenchmarkHandler())
        let counter = Actor(0)
        
        // Add 10 middlewares
        for _ in 0..<10 {
            try await pipeline.addMiddleware(CounterMiddleware(counter: counter))
        }
        
        // Benchmark with proper measurement infrastructure
        try await benchmark("Pipeline with 10 middlewares", iterations: 10) {
            for i in 0..<100 {
                _ = try await pipeline.execute(
                    BenchmarkCommand(value: i),
                    context: CommandContext(metadata: StandardCommandMetadata())
                )
            }
        }
        
        // Verify middleware execution count
        let totalCommands = 10 * 100 // iterations * commands per iteration
        let count = await counter.get()
        XCTAssertEqual(count, totalCommands * 10) // total commands * middlewares
    }
    
    func testConcurrentPipelinePerformance() async throws {
        let concurrentPipeline = ConcurrentPipeline(options: PipelineOptions(maxConcurrency: 10, maxOutstanding: 1000))
        let executor = StandardPipeline(handler: BenchmarkHandler())
        
        await concurrentPipeline.register(BenchmarkCommand.self, pipeline: executor)
        
        // Test throughput of concurrent execution
        let throughput = try await benchmarkThroughput("Concurrent Pipeline Throughput", duration: 2.0) {
            _ = try await concurrentPipeline.execute(
                BenchmarkCommand(value: 42),
                context: CommandContext()
            )
        }
        
        print("Concurrent pipeline throughput: \(Int(throughput)) ops/sec")
        XCTAssertGreaterThan(throughput, 100, "Should process at least 100 ops/sec")
        
        // Test batch execution performance
        let commands = (0..<100).map { BenchmarkCommand(value: $0) }
        
        try await benchmark("Concurrent Batch Execution", iterations: 10) {
            let results = try await concurrentPipeline.executeConcurrently(commands)
            
            // Verify all succeeded
            XCTAssertEqual(results.count, commands.count)
            for result in results {
                if case .failure = result {
                    XCTFail("Unexpected failure in concurrent execution")
                }
            }
        }
    }
    
    func testPipelineWithVsWithoutMiddleware() async throws {
        let handler = BenchmarkHandler()
        let command = BenchmarkCommand(value: 42)
        let context = CommandContext()
        
        // Compare pipeline performance with middleware overhead
        try await comparePerformance("Pipeline middleware overhead",
            baseline: {
                // Pipeline with middleware (baseline for comparison)
                let pipeline = StandardPipeline(handler: handler)
                for i in 0..<5 {
                    try await pipeline.addMiddleware(CounterMiddleware(counter: Actor(i)))
                }
                _ = try await pipeline.execute(command, context: context)
            },
            optimized: {
                // Pipeline without middleware (should be faster)
                let pipeline = StandardPipeline(handler: handler)
                _ = try await pipeline.execute(command, context: context)
            }
        )
    }
}
