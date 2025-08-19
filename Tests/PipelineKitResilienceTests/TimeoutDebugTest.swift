import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience

final class TimeoutDebugTest: XCTestCase {
    // Test command
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
        
        func execute() async throws -> String {
            return value
        }
    }
    
    // Test handler  
    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            print("  [Handler] Handling: \(command.value)")
            return command.value
        }
    }
    
    // Debug middleware to trace execution
    private struct DebugMiddleware: Middleware {
        let name: String
        let priority: ExecutionPriority
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            print("  [\(name)] Before next")
            let result = try await next(command, context)
            print("  [\(name)] After next")
            return result
        }
    }
    
    // Slow middleware
    private struct SlowMiddleware: Middleware {
        let delay: TimeInterval
        let priority: ExecutionPriority = .postProcessing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            print("  [SlowMiddleware] Starting \(delay)s delay...")
            let start = Date()
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let elapsed = Date().timeIntervalSince(start)
                print("  [SlowMiddleware] Completed after \(elapsed)s")
                return try await next(command, context)
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                print("  [SlowMiddleware] Interrupted after \(elapsed)s: \(error)")
                throw error
            }
        }
    }
    
    func testTimeoutDebug() async throws {
        // Test with explicit middleware order
        print("\n=== Testing timeout with slow middleware ===")
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Add middleware
        let timeoutMiddleware = TimeoutMiddleware(defaultTimeout: 0.1)
        let slowMiddleware = SlowMiddleware(delay: 0.2)
        
        print("Middleware priorities:")
        print("  TimeoutMiddleware: \(timeoutMiddleware.priority.rawValue)")
        print("  SlowMiddleware: \(slowMiddleware.priority.rawValue)")
        
        try await pipeline.addMiddleware(timeoutMiddleware)
        try await pipeline.addMiddleware(slowMiddleware)
        
        print("\nExecuting command...")
        let command = TestCommand(value: "test")
        let context = CommandContext()
        let start = Date()
        
        do {
            let result = try await pipeline.execute(command, context: context)
            let elapsed = Date().timeIntervalSince(start)
            XCTFail("Should have timed out! Got result: \(result) after \(elapsed)s")
        } catch let error as PipelineError {
            let elapsed = Date().timeIntervalSince(start)
            if case .timeout = error {
                print("✅ Timed out after \(elapsed)s")
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }
    
    func testJustTimeout() async throws {
        print("\n=== Testing just timeout middleware ===")
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let timeoutMiddleware = TimeoutMiddleware(defaultTimeout: 0.1)
        try await pipeline.addMiddleware(timeoutMiddleware)
        
        // Add a debug middleware after timeout to trace
        try await pipeline.addMiddleware(DebugMiddleware(name: "Debug", priority: .postProcessing))
        
        print("Executing command...")
        let command = TestCommand(value: "fast")
        let context = CommandContext()
        
        let result = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result, "fast")
        print("✅ Completed without timeout")
    }
}