import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience
import PipelineKit

final class ActualTimeoutTest: XCTestCase {
    // Upper bound on how long the 100ms timeout may take to surface. It is a
    // hang detector, not a latency measurement: the slow middleware below sleeps
    // for `slowWork`, so an elapsed time under this bound proves the caller was
    // released by the timeout (and the sleep was cancelled) rather than by the
    // work finishing. It deliberately does not assert that the timeout fired
    // within any small multiple of 100ms; a shared CI runner can stall a test
    // process for hundreds of milliseconds (observed 0.3228s against a former
    // 0.3s bound) without anything being wrong.
    private static let promptnessBound: TimeInterval = 10.0

    // The work must outlast the deadline by far more than any scheduling stall.
    // `withTimeout` returns whichever of the work and the timer finishes first,
    // so with 200ms of work against a 100ms deadline a stall past both lets the
    // work win and the call returns a value. The sleep is cancelled at the
    // deadline, so the tests still finish in about 100ms.
    private static let slowWork: TimeInterval = 30.0

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
        
        func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
            print("    [Handler] Handling: \(command.value)")
            return command.value
        }
    }
    
    // Instrumented slow middleware - conforms to NextGuardWarningSuppressing
    // because it may be cancelled by timeout, leaving next() uncalled
    private struct InstrumentedSlowMiddleware: Middleware, NextGuardWarningSuppressing {
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
        let slowMiddleware = InstrumentedSlowMiddleware(delay: Self.slowWork)
        
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
                XCTAssertLessThan(elapsed, Self.promptnessBound, "Timeout took too long (elapsed: \(elapsed)s)")
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
        let slowMiddleware = InstrumentedSlowMiddleware(delay: Self.slowWork)
        
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
                XCTAssertLessThan(elapsed, Self.promptnessBound, "Timeout took too long (elapsed: \(elapsed)s)")
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
