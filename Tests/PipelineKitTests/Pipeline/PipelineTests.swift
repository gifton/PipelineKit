import XCTest
@testable import PipelineKit

final class PipelineTests: XCTestCase {
    
    struct TransformCommand: Command {
        typealias Result = String
        let input: String
    }
    
    struct TransformHandler: CommandHandler {
        typealias CommandType = TransformCommand
        
        func handle(_ command: TransformCommand) async throws -> String {
            return command.input.uppercased()
        }
    }
    
    struct AppendMiddleware: Middleware {
        let suffix: String
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            let result = try await next(command, metadata)
            if var stringResult = result as? String {
                stringResult += suffix
                return stringResult as! T.Result
            }
            return result
        }
    }
    
    struct DelayMiddleware: Middleware {
        let delay: TimeInterval
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await next(command, metadata)
        }
    }
    
    func testBasicPipelineExecution() async throws {
        let handler = TransformHandler()
        let pipeline = DefaultPipeline(handler: handler)
        
        let result = try await pipeline.execute(
            TransformCommand(input: "hello"),
            metadata: DefaultCommandMetadata()
        )
        
        XCTAssertEqual(result, "HELLO")
    }
    
    func testPipelineWithMiddleware() async throws {
        let handler = TransformHandler()
        let pipeline = DefaultPipeline(handler: handler)
        
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "!"))
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "?"))
        
        let result = try await pipeline.execute(
            TransformCommand(input: "hello"),
            metadata: DefaultCommandMetadata()
        )
        
        XCTAssertEqual(result, "HELLO?!")
    }
    
    func testPipelineBuilder() async throws {
        let builder = PipelineBuilder(handler: TransformHandler())
        _ = await builder.with(AppendMiddleware(suffix: " World"))
        _ = await builder.with(AppendMiddleware(suffix: "!"))
        _ = await builder.withMaxDepth(50)
        
        let pipeline = try await builder.build()
        
        let result = try await pipeline.execute(
            TransformCommand(input: "hello"),
            metadata: DefaultCommandMetadata()
        )
        
        XCTAssertEqual(result, "HELLO! World")
    }
    
    func testMaxDepthProtection() async throws {
        let handler = TransformHandler()
        let pipeline = DefaultPipeline(handler: handler, maxDepth: 2)
        
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "1"))
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "2"))
        
        do {
            try await pipeline.addMiddleware(AppendMiddleware(suffix: "3"))
            XCTFail("Expected error")
        } catch let error as PipelineError {
            if case .maxDepthExceeded = error {
                // Success
            } else {
                XCTFail("Wrong error type")
            }
        }
    }
    
    func testConcurrentPipelineExecution() async throws {
        let pipeline = ConcurrentPipeline(options: PipelineOptions(maxConcurrency: 2))
        let executor = DefaultPipeline(handler: TransformHandler())
        
        await pipeline.register(TransformCommand.self, pipeline: executor)
        
        let commands = (0..<5).map { TransformCommand(input: "test\($0)") }
        let results = try await pipeline.executeConcurrently(commands)
        
        XCTAssertEqual(results.count, 5)
        
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let value):
                XCTAssertTrue(value.hasPrefix("TEST"))
            case .failure:
                XCTFail("Unexpected failure at index \(index)")
            }
        }
    }
    
    func testPriorityPipeline() async throws {
        let handler = TransformHandler()
        let pipeline = PriorityPipeline(handler: handler)
        
        // Add middlewares with different priorities (lower number = higher priority)
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "3"), priority: 30)
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "1"), priority: 10)
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "2"), priority: 20)
        
        let result = try await pipeline.execute(
            TransformCommand(input: "hello"),
            metadata: DefaultCommandMetadata()
        )
        
        // Should execute in priority order: 1, 2, 3 (but reversed for middleware chain)
        XCTAssertEqual(result, "HELLO321")
    }
}