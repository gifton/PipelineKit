import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience

/// Proof tests showing TimeoutMiddleware works correctly when configured properly
final class TimeoutProofTests: XCTestCase {
    
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
        func execute() async throws -> String { value }
    }
    
    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        func handle(_ command: TestCommand) async throws -> String {
            command.value
        }
    }
    
    /// Middleware that delays WITHIN the timeout's protection
    private struct SlowHandlerWrapper: Middleware {
        let delay: TimeInterval
        let priority: ExecutionPriority = .postProcessing // Higher priority (400) than timeout (250)
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // This delay happens AFTER timeout middleware wraps us
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await next(command, context)
        }
    }
    
    func testTimeoutCorrectlyEnforcesWhenSlowOperationIsAfter() async throws {
        // Given
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Add timeout first (priority 250)
        let timeoutMiddleware = TimeoutMiddleware(defaultTimeout: 0.05) // 50ms
        try await pipeline.addMiddleware(timeoutMiddleware)
        
        // Add slow operation with HIGHER priority value (executes AFTER timeout in chain)
        let slowMiddleware = SlowHandlerWrapper(delay: 0.1) // 100ms
        try await pipeline.addMiddleware(slowMiddleware)
        
        print("Middleware order: \(await pipeline.middlewareTypes)")
        // Should be: ["TimeoutMiddleware", "SlowHandlerWrapper"]
        // Execution: TimeoutMiddleware wraps SlowHandlerWrapper
        
        // When/Then
        do {
            _ = try await pipeline.execute(TestCommand(value: "test"), context: CommandContext())
            XCTFail("Should have timed out")
        } catch let error as PipelineError {
            if case .timeout = error {
                // ✅ Success - properly timed out
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    func testOriginalTestSetupCannotWork() async throws {
        // This recreates the original test setup to show why it can't work
        
        struct SlowMiddlewareBeforeTimeout: Middleware {
            let delay: TimeInterval
            // Using .custom priority (1000) like original test - will run AFTER timeout
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
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Original test order
        let slowMiddleware = SlowMiddlewareBeforeTimeout(delay: 0.2)
        let timeoutMiddleware = TimeoutMiddleware(defaultTimeout: 0.1)
        
        try await pipeline.addMiddleware(slowMiddleware)
        try await pipeline.addMiddleware(timeoutMiddleware)
        
        print("Original test middleware order: \(await pipeline.middlewareTypes)")
        // Will be: ["TimeoutMiddleware", "SlowMiddlewareBeforeTimeout"]
        // Because timeout priority (250) < slow priority (1000)
        
        // The slow middleware runs AFTER timeout wraps it, so it SHOULD timeout
        do {
            _ = try await pipeline.execute(TestCommand(value: "test"), context: CommandContext())
            XCTFail("Should have timed out with this setup")
        } catch let error as PipelineError {
            if case .timeout = error {
                // ✅ This is actually the expected behavior!
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }
    
    func testSlowOperationBeforeTimeoutCannotBeInterrupted() async throws {
        // This shows that operations BEFORE timeout in the chain cannot be timed out
        
        struct EarlySlowMiddleware: Middleware {
            let delay: TimeInterval
            let priority: ExecutionPriority = .preProcessing // Priority 100 < timeout's 250
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // This runs BEFORE timeout middleware gets control
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // Only now does timeout middleware get to run
                return try await next(command, context)
            }
        }
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let earlySlowMiddleware = EarlySlowMiddleware(delay: 0.2) // 200ms
        let timeoutMiddleware = TimeoutMiddleware(defaultTimeout: 0.05) // 50ms
        
        try await pipeline.addMiddleware(earlySlowMiddleware)
        try await pipeline.addMiddleware(timeoutMiddleware)
        
        print("Early slow middleware order: \(await pipeline.middlewareTypes)")
        // Will be: ["EarlySlowMiddleware", "TimeoutMiddleware"]
        
        // The slow operation completes BEFORE timeout even starts timing
        let start = Date()
        let result = try await pipeline.execute(TestCommand(value: "test"), context: CommandContext())
        let elapsed = Date().timeIntervalSince(start)
        
        XCTAssertEqual(result, "test")
        XCTAssertGreaterThan(elapsed, 0.19) // Full 200ms delay happened
        print("✅ Completed after \(elapsed)s - timeout couldn't interrupt early operation")
    }
}