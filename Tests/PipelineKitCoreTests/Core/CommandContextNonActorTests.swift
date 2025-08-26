import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience
import PipelineKit
import PipelineKitTestSupport

final class CommandContextNonActorTests: XCTestCase {
    func testContextIsNoLongerActor() async {
        // This test verifies that CommandContext uses the new API
        let metadata = TestCommandMetadata(
            userId: "test-user",
            correlationId: "test-123"
        )
        let context = CommandContext(metadata: metadata)
        
        // These operations use the new subscript API
        await context.set(TestContextKeys.testKey, value: "test-value")
        let value: String? = await context.get(TestContextKeys.testKey)
        XCTAssertEqual(value, "test-value")
        
        // Test metadata access (still synchronous)
        let retrievedMetadata = await context.commandMetadata
        XCTAssertEqual(retrievedMetadata.userId, "test-user")
    }
    
    func testConcurrentContextAccess() async throws {
        let context = CommandContext.test()
        let iterations = 1000
        
        await withTaskGroup(of: Void.self) { group in
            // Multiple writers
            for i in 0..<iterations {
                group.addTask {
                    await context.set(TestContextKeys.testKey, value: "value-\(i)")
                    await context.set(TestContextKeys.numberKey, value: i)
                }
            }
            
            // Multiple readers
            for _ in 0..<iterations {
                group.addTask {
                    _ = await context.get(TestContextKeys.testKey) as String?
                    _ = await context.get(TestContextKeys.numberKey) as Int?
                }
            }
        }
        
        // Verify context still works after concurrent access
        await context.set(TestContextKeys.testKey, value: "final")
        let finalValue: String? = await context.get(TestContextKeys.testKey)
        XCTAssertEqual(finalValue, "final")
    }
    
    func testMiddlewareWithoutAwaitOnContext() async throws {
        struct NonAsyncContextMiddleware: Middleware {
            let priority: ExecutionPriority = .custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // Using the new subscript API
                await context.set(TestContextKeys.testKey, value: "middleware-value")
                let value: String? = await context.get(TestContextKeys.testKey)
                XCTAssertEqual(value, "middleware-value")
                
                return try await next(command, context)
            }
        }
        
        let handler = TestHelpers.TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(NonAsyncContextMiddleware())
        
        let context = CommandContext.test()
        let command = TestHelpers.TestCommand(value: "test")
        
        let result = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result, "test")
        
        // Verify context retained the value
        let retainedValue: String? = await context.get(TestContextKeys.testKey)
        XCTAssertEqual(retainedValue, "middleware-value")
    }
    
    func testParallelMiddlewareExecution() async throws {
        struct ParallelTestMiddleware: Middleware {
            let id: String
            let priority: ExecutionPriority = .custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // Simulate some work
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                await context.set(TestContextKeys.testKey, value: id)
                
                // For parallel middleware, we don't call next
                throw ParallelExecutionError.middlewareShouldNotCallNext
            }
        }
        
        let handler = TestHelpers.TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let parallelWrapper = ParallelMiddlewareWrapper(
            middlewares: [
                ParallelTestMiddleware(id: "middleware-1"),
                ParallelTestMiddleware(id: "middleware-2"),
                ParallelTestMiddleware(id: "middleware-3")
            ],
            strategy: .sideEffectsOnly
        )
        
        try await pipeline.addMiddleware(parallelWrapper)
        
        let context = CommandContext.test()
        let command = TestHelpers.TestCommand(value: "test")
        
        let result = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result, "test")
        
        // One of the middleware should have set a value
        let storedValue: String? = await context.get(TestContextKeys.testKey)
        XCTAssertNotNil(storedValue)
    }
}

// Test helpers specific to this test file
private enum TestHelpers {
    struct TestCommand: Command {
        typealias Result = String
        let value: String
        
        func execute() async throws -> String {
            return value
        }
    }
    
    struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return command.value
        }
    }
}
