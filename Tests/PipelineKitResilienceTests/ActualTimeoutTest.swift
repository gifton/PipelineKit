import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience
import PipelineKit

final class ActualTimeoutTest: XCTestCase {
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
            print("    [Handler] Handling: \(command.value)")
            return command.value
        }
    }
    
    // Instrumented slow middleware
    private struct InstrumentedSlowMiddleware: Middleware {
        let delay: TimeInterval
        let priority: ExecutionPriority = .postProcessing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            print("    [SlowMiddleware] Starting \(delay)s delay...")
            let start = Date()
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let elapsed = Date().timeIntervalSince(start)
                print("    [SlowMiddleware] Completed after \(elapsed)s")
                return try await next(command, context)
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                print("    [SlowMiddleware] Interrupted after \(elapsed)s: \(error)")
                throw error
            }
        }
    }
    
    func testInstrumentedTimeout() async throws {
        print("\n=== Testing with INSTRUMENTED TimeoutMiddleware ===")
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Use instrumented version
        let timeoutMiddleware = InstrumentedTimeoutMiddleware(timeout: 0.1)
        let slowMiddleware = InstrumentedSlowMiddleware(delay: 0.2)
        
        print("Adding middleware...")
        print("  TimeoutMiddleware priority: \(timeoutMiddleware.priority.rawValue)")
        print("  SlowMiddleware priority: \(slowMiddleware.priority.rawValue)")
        
        try await pipeline.addMiddleware(timeoutMiddleware)
        try await pipeline.addMiddleware(slowMiddleware)
        
        print("\nExecuting command...")
        let command = TestCommand(value: "test")
        let context = CommandContext()
        let start = Date()
        
        do {
            let result = try await pipeline.execute(command, context: context)
            let elapsed = Date().timeIntervalSince(start)
            print("\n❌ FAILED: Got result '\(result)' after \(elapsed)s")
            XCTFail("Should have timed out")
        } catch let error as PipelineError {
            let elapsed = Date().timeIntervalSince(start)
            if case .timeout = error {
                print("\n✅ SUCCESS: Timed out after \(elapsed)s")
                XCTAssertLessThan(elapsed, 0.15, "Timeout took too long")
            } else {
                print("\n❌ FAILED: Wrong error type: \(error)")
                XCTFail("Expected timeout error")
            }
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("\n❌ FAILED: Unexpected error after \(elapsed)s: \(error)")
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testActualTimeoutMiddleware() async throws {
        print("\n=== Testing ACTUAL TimeoutMiddleware ===")
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Use the real TimeoutMiddleware
        let timeoutMiddleware = TimeoutMiddleware(defaultTimeout: 0.1)
        let slowMiddleware = InstrumentedSlowMiddleware(delay: 0.2)
        
        print("Adding middleware...")
        print("  TimeoutMiddleware priority: \(timeoutMiddleware.priority.rawValue)")
        print("  SlowMiddleware priority: \(slowMiddleware.priority.rawValue)")
        
        try await pipeline.addMiddleware(timeoutMiddleware)
        try await pipeline.addMiddleware(slowMiddleware)
        
        print("\nExecuting command...")
        let command = TestCommand(value: "test")
        let context = CommandContext()
        let start = Date()
        
        do {
            let result = try await pipeline.execute(command, context: context)
            let elapsed = Date().timeIntervalSince(start)
            print("\n❌ FAILED: Got result '\(result)' after \(elapsed)s")
            print("Expected timeout after 0.1s but completed after \(elapsed)s")
            XCTFail("Should have timed out")
        } catch let error as PipelineError {
            let elapsed = Date().timeIntervalSince(start)
            if case .timeout = error {
                print("\n✅ SUCCESS: Timed out after \(elapsed)s")
                XCTAssertLessThan(elapsed, 0.15, "Timeout took too long")
            } else {
                print("\n❌ FAILED: Wrong error type: \(error)")
                XCTFail("Expected timeout error")
            }
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("\n❌ FAILED: Unexpected error after \(elapsed)s: \(error)")
            XCTFail("Unexpected error: \(error)")
        }
    }
}