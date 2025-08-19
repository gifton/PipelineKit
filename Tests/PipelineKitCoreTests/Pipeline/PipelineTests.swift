import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

final class PipelineTests: XCTestCase {
    private struct TransformCommand: Command {
        typealias Result = String
        let input: String
        
        func execute() async throws -> String {
            return input.uppercased()
        }
    }
    
    private struct TransformHandler: CommandHandler {
        typealias CommandType = TransformCommand
        
        func handle(_ command: TransformCommand) async throws -> String {
            return command.input.uppercased()
        }
    }
    
    private struct AppendMiddleware: Middleware {
        let suffix: String
        let priority: ExecutionPriority
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            let result = try await next(command, context)
            if var stringResult = result as? String {
                stringResult += suffix
                if let typedResult = stringResult as? T.Result {
                    return typedResult
                }
            }
            return result
        }
    }
    
    private struct DelayMiddleware: Middleware {
        let delay: TimeInterval
        let priority: ExecutionPriority = .custom
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await next(command, context)
        }
    }
    
    func testBasicPipelineExecution() async throws {
        let handler = TransformHandler()
        let pipeline = StandardPipeline(handler: handler)
        let context = CommandContext.test()
        
        let result = try await pipeline.execute(
            TransformCommand(input: "hello"),
            context: context
        )
        
        XCTAssertEqual(result, "HELLO")
    }
    
    func testPipelineWithMiddleware() async throws {
        let handler = TransformHandler()
        let pipeline = StandardPipeline(handler: handler)
        let context = CommandContext.test()
        
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "!", priority: .custom))
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "?", priority: .custom))
        
        let result = try await pipeline.execute(
            TransformCommand(input: "hello"),
            context: context
        )
        
        XCTAssertEqual(result, "HELLO?!")
    }
    
    func testPipelineBuilder() async throws {
        let builder = PipelineBuilder(handler: TransformHandler())
        _ = await builder.with(AppendMiddleware(suffix: " World", priority: .custom))
        _ = await builder.with(AppendMiddleware(suffix: "!", priority: .custom))
        _ = await builder.withMaxDepth(50)
        
        let pipeline = try await builder.build()
        let context = CommandContext.test()
        
        let result = try await pipeline.execute(
            TransformCommand(input: "hello"),
            context: context
        )
        
        XCTAssertEqual(result, "HELLO! World")
    }
    
    func testMaxDepthProtection() async throws {
        let handler = TransformHandler()
        let pipeline = StandardPipeline(handler: handler, maxDepth: 2)
        
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "1", priority: .custom))
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "2", priority: .custom))
        
        do {
            try await pipeline.addMiddleware(AppendMiddleware(suffix: "3", priority: .custom))
            XCTFail("Expected error")
        } catch let error as PipelineError {
            if case .maxDepthExceeded(let depth, let max) = error,
               depth == 3 && max == 2 {
                // Success - reached max depth
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    // ConcurrentPipeline was removed during simplification
    // TODO: Reimplement using TaskGroup if concurrent execution is needed
    /*
    func testConcurrentPipelineExecution() async throws {
        let pipeline = ConcurrentPipeline(options: PipelineOptions(maxConcurrency: 2))
        let executor = StandardPipeline(handler: TransformHandler())
        
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
    */
    
    func testPriorityPipeline() async throws {
        let handler = TransformHandler()
        let pipeline = AnyStandardPipeline(handler: handler)
        let context = CommandContext.test()
        
        // Add middlewares with different priorities (lower number = higher priority)
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "3", priority: .postProcessing))  // 500
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "1", priority: .authentication))  // 100  
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "2", priority: .validation))      // 300
        
        let result = try await pipeline.execute(
            TransformCommand(input: "hello"),
            context: context
        )
        
        // Should execute in priority order: 1, 2, 3 (but reversed for middleware chain)
        XCTAssertEqual(result, "HELLO321")
    }
    
    func testPipelineContextPropagation() async throws {
        struct ContextTrackingMiddleware: Middleware {
            let value: String
            let priority: ExecutionPriority = .custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                await context.setMetadata("test_context_key", value: value)
                return try await next(command, context)
            }
        }
        
        struct ContextVerifyingMiddleware: Middleware {
            let expectedValue: String
            let priority: ExecutionPriority = .custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                let metadata = await context.getMetadata()
                let value: String? = (metadata["test_context_key"] as? String)
                if value != expectedValue {
                    throw TestError.validationFailed
                }
                return try await next(command, context)
            }
        }
        
        let handler = TransformHandler()
        let pipeline = StandardPipeline(handler: handler)
        let context = CommandContext.test()
        
        try await pipeline.addMiddleware(ContextTrackingMiddleware(value: "test-value"))
        try await pipeline.addMiddleware(ContextVerifyingMiddleware(expectedValue: "test-value"))
        
        let result = try await pipeline.execute(
            TransformCommand(input: "context-test"),
            context: context
        )
        
        XCTAssertEqual(result, "CONTEXT-TEST")
        
        // Verify context still has the value after execution
        let metadata = await context.getMetadata()
        let finalValue: String? = (metadata["test_context_key"] as? String)
        XCTAssertEqual(finalValue, "test-value")
    }
}
