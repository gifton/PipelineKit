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

// MARK: - Main benchmark definitions

let benchmarks = {
    // Configure for CI if environment variable is set
    let ciMode = ProcessInfo.processInfo.environment["CI"] != nil
    
    if ciMode {
        Benchmark.defaultConfiguration.maxDuration = .seconds(1)
        Benchmark.defaultConfiguration.maxIterations = 100
        Benchmark.defaultConfiguration.warmupIterations = 5
    }
    
    // Simple pipeline benchmark
    Benchmark("Pipeline.simple") { benchmark in
        let pipeline = StandardPipeline(handler: TestHandler())
        let context = CommandContext()
        
        for _ in benchmark.scaledIterations {
            _ = try await pipeline.execute(TestCommand(), context: context)
        }
    }
    
    // CommandContext benchmark  
    Benchmark("CommandContext.metadata") { benchmark in
        let context = CommandContext()
        
        for i in benchmark.scaledIterations {
            await context.setMetadata("key-\(i)", value: i)
        }
    }
}()