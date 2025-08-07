import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class MinimalTest: XCTestCase {
    func testCommandContextIsNotActor() async {
        // This test verifies CommandContext is no longer an actor
        let context = CommandContext.test()
        
        // These now require await for async storage access
        await context.set("value", for: "string_key")
        let value: String? = await context.get(String.self, for: "string_key")
        XCTAssertEqual(value, "value")
        
        // Verify metadata access
        let metadata = context.commandMetadata
        XCTAssertNotNil(metadata)
    }
    
    func testParallelMiddlewareWrapper() async throws {
        struct TestCommand: Command {
            typealias Result = String
            let value: String
            func execute() async throws -> String { value }
        }
        
        struct TestHandler: CommandHandler {
            typealias CommandType = TestCommand
            func handle(_ command: TestCommand) async throws -> String {
                command.value
            }
        }
        
        struct SideEffectMiddleware: Middleware {
            let id: String
            let priority: ExecutionPriority = .custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // Just a side effect, don't call next
                await context.set(id, for: "string_key")
                throw ParallelExecutionError.middlewareShouldNotCallNext
            }
        }
        
        let pipeline = StandardPipeline(handler: TestHandler())
        let parallel = ParallelMiddlewareWrapper(
            middlewares: [
                SideEffectMiddleware(id: "m1"),
                SideEffectMiddleware(id: "m2")
            ],
            strategy: .sideEffectsWithMerge
        )
        
        try await pipeline.addMiddleware(parallel)
        
        let context = CommandContext.test()
        let result = try await pipeline.execute(
            TestCommand(value: "test"),
            context: context
        )
        
        XCTAssertEqual(result, "test")
        let storedValue: String? = await context.get(String.self, for: "string_key")
        XCTAssertNotNil(storedValue)
    }
}

// StringKey no longer needed - using string keys directly
