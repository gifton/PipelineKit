import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience
import PipelineKit

/// Tests that demonstrate and diagnose timeout behavior in the pipeline.
///
/// IMPORTANT: Swift's Cooperative Cancellation Model
/// ==================================================
/// In Swift's async/await model, task cancellation is COOPERATIVE, not preemptive.
/// This means:
/// 1. When a timeout occurs, we can immediately throw a timeout error to the caller ✅
/// 2. However, we CANNOT forcefully stop operations that are already running ❌
/// 3. Background operations will continue until they check Task.isCancelled or complete naturally
/// 
/// Therefore, these tests verify that:
/// - Timeout errors are thrown promptly at the specified timeout duration
/// - The pipeline doesn't wait for slow operations to complete
/// - But they DON'T verify that operations stop immediately (because they can't!)
///
/// The log output may show operations completing AFTER the timeout - this is EXPECTED!
/// For example:
/// ```
/// [Handler] Starting slow operation
/// Timeout error thrown at 0.05s
/// [Handler] Completed    // <-- This happens AFTER timeout, which is normal!
/// ```
final class TimeoutDiagnosticTests: XCTestCase {
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
            return command.value
        }
    }
    
    // Slow middleware for testing timeouts
    private struct SlowMiddleware: Middleware {
        let delay: TimeInterval
        let priority: ExecutionPriority = .custom
        let id: String
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            print("[\(id)] Starting slow middleware, will delay for \(delay)s")
            let start = Date()
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let elapsed = Date().timeIntervalSince(start)
            print("[\(id)] Slow middleware completed after \(elapsed)s")
            return try await next(command, context)
        }
    }
    
    // Diagnostic middleware to trace execution
    private struct TracingMiddleware: Middleware {
        let priority: ExecutionPriority
        let id: String
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            print("[\(id)] Before next (priority: \(priority.rawValue))")
            let result = try await next(command, context)
            print("[\(id)] After next")
            return result
        }
    }
    
    func testDirectTimeoutUtility() async throws {
        print("\n=== Direct Timeout Utility Test ===")
        
        // Test the timeout utility directly
        do {
            print("Testing withTimeout directly with 0.1s timeout on 0.2s operation...")
            let start = Date()
            _ = try await withTimeout(0.1) {
                try await Task.sleep(nanoseconds: 200_000_000) // 0.2s
                return "Should not reach here"
            }
            let elapsed = Date().timeIntervalSince(start)
            XCTFail("Unexpected success after \(elapsed)s")
        } catch {
            print("✅ Correctly timed out with error: \(error)")
            XCTAssertTrue(error is TimeoutError)
        }
    }
    
    func testMiddlewarePriorityOrder() async throws {
        print("\n=== Middleware Priority Order Test ===")
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Add middlewares with different priorities
        let preProcessing = TracingMiddleware(priority: .preProcessing, id: "PreProcessing")
        let authentication = TracingMiddleware(priority: .authentication, id: "Authentication")
        let resilience = TracingMiddleware(priority: .resilience, id: "Resilience")
        let custom = TracingMiddleware(priority: .custom, id: "Custom")
        
        try await pipeline.addMiddleware(custom)
        try await pipeline.addMiddleware(resilience)
        try await pipeline.addMiddleware(authentication)
        try await pipeline.addMiddleware(preProcessing)
        
        print("Middleware types: \(await pipeline.middlewareTypes)")
        
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, context: CommandContext())
        
        XCTAssertEqual(result, "test")
    }
    
    func testTimeoutWithSlowMiddlewareAfter() async throws {
        print("\n=== Timeout with Slow Middleware After ===")
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // TimeoutMiddleware has priority .resilience (200)
        let timeoutMiddleware = TimeoutMiddleware(defaultTimeout: 0.05) // 50ms
        
        // SlowMiddleware has priority .custom (1000)
        let slowMiddleware = SlowMiddleware(delay: 0.1, id: "SlowAfter") // 100ms
        
        try await pipeline.addMiddleware(timeoutMiddleware)
        try await pipeline.addMiddleware(slowMiddleware)
        
        print("Middleware order: \(await pipeline.middlewareTypes)")
        
        let command = TestCommand(value: "test")
        let start = Date()
        
        do {
            let result = try await pipeline.execute(command, context: CommandContext())
            let elapsed = Date().timeIntervalSince(start)
            print("Execution completed in \(elapsed)s with result: \(result)")
            
            // NOTE: In Swift's cooperative cancellation model, operations cannot be
            // forcefully interrupted. If the slow middleware doesn't check Task.isCancelled,
            // it will complete even after timeout. This is expected behavior.
            // We should NOT reach here because timeout should throw an error.
            XCTFail("Should have thrown timeout error, but got result: \(result)")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("Failed after \(elapsed)s with error: \(error)")
            
            // The timeout error should be thrown promptly (around 50ms)
            // We allow up to 200ms for CI variability, but this is just for the error to be thrown
            // The background operation may continue running - that's expected!
            XCTAssertLessThan(elapsed, 0.2, "Timeout error should be thrown promptly: \(elapsed)s")
            
            if let pipelineError = error as? PipelineError,
               case .timeout = pipelineError {
                // Success - timeout was correctly detected and thrown
                print("✅ Correctly threw timeout error at \(elapsed)s")
            } else {
                XCTFail("Expected timeout error, got: \(error)")
            }
        }
    }
    
    func testTimeoutWithSlowMiddlewareBefore() async throws {
        print("\n=== Timeout with Slow Middleware Before ===")
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Create slow middleware with lower priority (executes first)
        struct EarlySlowMiddleware: Middleware {
            let delay: TimeInterval
            let priority: ExecutionPriority = .preProcessing // 100 - runs before timeout
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                print("[EarlySlow] Starting, will delay for \(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                print("[EarlySlow] Completed")
                return try await next(command, context)
            }
        }
        
        let timeoutMiddleware = TimeoutMiddleware(defaultTimeout: 0.05) // 50ms
        let slowMiddleware = EarlySlowMiddleware(delay: 0.1) // 100ms
        
        try await pipeline.addMiddleware(timeoutMiddleware)
        try await pipeline.addMiddleware(slowMiddleware)
        
        print("Middleware order: \(await pipeline.middlewareTypes)")
        
        let command = TestCommand(value: "test")
        let start = Date()
        
        do {
            _ = try await pipeline.execute(command, context: CommandContext())
            XCTFail("Should have timed out")
        } catch let error as PipelineError {
            let elapsed = Date().timeIntervalSince(start)
            print("Timed out after \(elapsed)s with error: \(error)")
            if case .timeout = error {
                // ✅ Success - timeout correctly detected and error thrown
                // NOTE: The slow middleware may continue running in the background after
                // the timeout error is thrown. This is expected due to Swift's cooperative
                // cancellation model. The important thing is that we get the timeout error
                // promptly, not that background operations are forcefully stopped.
                
                // We expect the timeout error to be thrown around 50ms, but allow up to 250ms for CI
                XCTAssertLessThan(elapsed, 0.25, "Timeout error should be thrown promptly (elapsed: \(elapsed)s)")
                print("✅ Timeout correctly detected at \(elapsed)s (background ops may continue)")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    func testTimeoutExecutionFlow() async throws {
        print("\n=== Timeout Execution Flow Analysis ===")
        
        // Create a custom middleware that prints timing info
        struct TimingMiddleware: Middleware {
            let priority: ExecutionPriority
            let id: String
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                let start = Date()
                print("[\(id)] Starting at \(start.timeIntervalSince1970)")
                defer {
                    let elapsed = Date().timeIntervalSince(start)
                    print("[\(id)] Completed after \(elapsed)s")
                }
                return try await next(command, context)
            }
        }
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let timing1 = TimingMiddleware(priority: .preProcessing, id: "Timing1")
        let timeout = TimeoutMiddleware(defaultTimeout: 0.05)
        let timing2 = TimingMiddleware(priority: .postProcessing, id: "Timing2")
        
        try await pipeline.addMiddleware(timing1)
        try await pipeline.addMiddleware(timeout)
        try await pipeline.addMiddleware(timing2)
        
        print("Final middleware order: \(await pipeline.middlewareTypes)")
        
        // Add a slow operation in the handler itself
        struct SlowHandler: CommandHandler {
            typealias CommandType = TestCommand
            
            func handle(_ command: TestCommand) async throws -> String {
                print("[Handler] Starting slow operation")
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                print("[Handler] Completed")
                return command.value
            }
        }
        
        let slowPipeline = StandardPipeline(handler: SlowHandler())
        try await slowPipeline.addMiddleware(timeout)
        
        print("\nTesting timeout on slow handler...")
        let start = Date()
        do {
            _ = try await slowPipeline.execute(TestCommand(value: "test"), context: CommandContext())
            XCTFail("Should have timed out")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("Correctly failed with: \(error)")
            
            // Verify we got a timeout error promptly (around 50ms)
            if let pipelineError = error as? PipelineError,
               case .timeout = pipelineError {
                // The timeout error should be thrown around 50ms, but we allow more for CI
                XCTAssertLessThan(elapsed, 0.2, "Timeout should be detected promptly")
                print("✅ Timeout correctly thrown at \(elapsed)s")
                
                // NOTE: The handler's Task.sleep may continue in the background.
                // The print("[Handler] Completed") may appear after this test ends.
                // This is expected behavior due to Swift's cooperative cancellation.
            } else {
                XCTFail("Expected timeout error, got: \(error)")
            }
        }
    }
}
