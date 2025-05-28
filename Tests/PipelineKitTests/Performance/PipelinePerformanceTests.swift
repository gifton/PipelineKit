import XCTest
@testable import PipelineKit

final class PipelinePerformanceTests: XCTestCase {
    
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
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            await counter.increment()
            return try await next(command, metadata)
        }
    }
    
    actor Actor<T: Sendable>: Sendable {
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
    
    func testPipelinePerformance() async throws {
        let pipeline = DefaultPipeline(handler: BenchmarkHandler())
        let counter = Actor(0)
        
        // Add 10 middlewares
        for _ in 0..<10 {
            try await pipeline.addMiddleware(CounterMiddleware(counter: counter))
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Execute 1000 commands
        for i in 0..<1000 {
            _ = try await pipeline.execute(
                BenchmarkCommand(value: i),
                metadata: DefaultCommandMetadata()
            )
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let elapsed = endTime - startTime
        
        print("Pipeline execution time: \(elapsed) seconds")
        print("Average time per command: \(elapsed / 1000) seconds")
        
        let count = await counter.get()
        XCTAssertEqual(count, 10000) // 10 middlewares * 1000 commands
    }
    
    func testConcurrentPipelinePerformance() async throws {
        let concurrentPipeline = ConcurrentPipeline(maxConcurrency: 10)
        let executor = DefaultPipeline(handler: BenchmarkHandler())
        
        await concurrentPipeline.register(BenchmarkCommand.self, pipeline: executor)
        
        let commands = (0..<1000).map { BenchmarkCommand(value: $0) }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let results = try await concurrentPipeline.executeConcurrently(commands)
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let elapsed = endTime - startTime
        
        print("Concurrent pipeline execution time: \(elapsed) seconds")
        print("Average time per command: \(elapsed / 1000) seconds")
        
        XCTAssertEqual(results.count, 1000)
        
        // Verify all succeeded
        for result in results {
            if case .failure = result {
                XCTFail("Unexpected failure in concurrent execution")
            }
        }
    }
}