import XCTest
import PipelineKit
import PipelineKitCore

final class ModuleValidationTests: XCTestCase {
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
    }
    
    private final class TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Handled: \(command.value)"
        }
    }
    
    func testCoreTypesAccessible() async throws {
        // Test that we can create core types
        let command = TestCommand(value: "test")
        let context = CommandContext()
        let handler = TestHandler()
        
        // Test that we can use the pipeline
        let pipeline = StandardPipeline(handler: handler)
        let result = try await pipeline.execute(command, context: context)
        
        XCTAssertEqual(result, "Handled: test")
    }
    
    func testMiddlewareOrderBuilder() {
        // Test that builder types are accessible
        var builder = MiddlewareOrderBuilder()
        
        struct TestMiddleware: Middleware {
            let priority: ExecutionPriority = .processing
            
            func execute<T>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result where T: Command {
                return try await next(command, context)
            }
        }
        
        builder.add(TestMiddleware(), order: .authentication)
        let middlewares = builder.build()
        
        XCTAssertEqual(middlewares.count, 1)
    }
    
    func testBackPressureSemaphore() async throws {
        // Test that support types are accessible
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 2,
            strategy: .suspend
        )
        
        let token = try await semaphore.acquire()
        XCTAssertNotNil(token)
    }
}
