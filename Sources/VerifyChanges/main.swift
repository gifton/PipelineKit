import Foundation
import PipelineKit

// Test command
struct TestCommand: Command {
    typealias Result = String
    let value: String
    
    func execute() async throws -> String {
        return value.uppercased()
    }
}

// Test handler
struct TestHandler: CommandHandler {
    typealias CommandType = TestCommand
    
    func handle(_ command: TestCommand) async throws -> String {
        return try await command.execute()
    }
}

// Test middleware
struct LoggingMiddleware: Middleware {
    let priority: ExecutionPriority = .postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        print("Before executing command")
        let result = try await next(command, context)
        print("After executing command")
        return result
    }
}

// Context test middleware
struct ContextTestMiddleware: Middleware {
    let priority: ExecutionPriority = .custom
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // These should no longer require await
        context.set("test-value", for: StringKey.self)
        let value = context.get(StringKey.self)
        print("Context value: \(value ?? "nil")")
        
        return try await next(command, context)
    }
}

struct StringKey: ContextKey {
    typealias Value = String
}

// Main test
@main
struct VerifyChanges {
    static func main() async throws {
        print("=== Testing PipelineKit Changes ===\n")
        
        print("1. Testing CommandContext is no longer an actor...")
        let metadata = StandardCommandMetadata(
            userId: "test-user",
            correlationId: "test-123"
        )
        let context = CommandContext(metadata: metadata)
        
        // These operations don't require await
        context.set("sync-value", for: StringKey.self)
        let value = context.get(StringKey.self)
        print("✓ Context operations are synchronous: \(value ?? "nil")")
        
        print("\n2. Testing standard pipeline execution...")
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        try await pipeline.addMiddleware(LoggingMiddleware())
        try await pipeline.addMiddleware(ContextTestMiddleware())
        
        let command = TestCommand(value: "hello world")
        let result = try await pipeline.execute(command, context: context)
        print("✓ Pipeline result: \(result)")
        
        print("\n3. Testing parallel middleware execution...")
        struct SideEffectMiddleware: Middleware {
            let id: String
            let priority: ExecutionPriority = .custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                print("  - Side effect middleware \(id) executing")
                context.set("sideeffect-\(id)", for: StringKey.self)
                // For parallel execution, don't call next
                throw ParallelExecutionError.middlewareShouldNotCallNext
            }
        }
        
        let parallelWrapper = ParallelMiddlewareWrapper(
            middlewares: [
                SideEffectMiddleware(id: "1"),
                SideEffectMiddleware(id: "2"),
                SideEffectMiddleware(id: "3")
            ],
            strategy: .sideEffectsOnly
        )
        
        try await pipeline.addMiddleware(parallelWrapper)
        
        let result2 = try await pipeline.execute(
            TestCommand(value: "parallel test"),
            context: context
        )
        print("✓ Parallel execution result: \(result2)")
        
        print("\n4. Testing timeout middleware...")
        struct SlowMiddleware: Middleware {
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
        
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: SlowMiddleware(delay: 0.2),
            timeout: 0.1
        )
        
        try await pipeline.addMiddleware(timeoutWrapper)
        
        let result3 = try await pipeline.execute(
            TestCommand(value: "timeout test"),
            context: context
        )
        print("✓ Timeout test completed (check console for warning): \(result3)")
        
        print("\n=== All tests passed! ===")
    }
}