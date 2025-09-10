import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience
import PipelineKit
import PipelineKitTestSupport

final class TimeoutMiddlewareTests: XCTestCase {
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
        let priority: ExecutionPriority = .postProcessing  // Higher priority number than resilience
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await next(command, context)
        }
    }
    
    func testTimeoutMiddlewareEnforcesTimeout() async throws {
        // Given
        let slowMiddleware = SlowMiddleware(delay: 0.2) // 200ms
        let timeoutMiddleware = TimeoutMiddleware(
            defaultTimeout: 0.1 // 100ms timeout
        )
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(timeoutMiddleware)
        try await pipeline.addMiddleware(slowMiddleware)
        
        let context = CommandContext.test()
        let command = TestCommand(value: "test")
        
        // When/Then - Should timeout
        do {
            _ = try await pipeline.execute(command, context: context)
            XCTFail("Should have timed out")
        } catch let error as PipelineError {
            if case .timeout = error {
                // Success - command timed out as expected
            } else {
                XCTFail("Expected timeout error, got: \(error)")
            }
        }
    }
    
    func testTimeoutMiddlewareWithFastExecution() async throws {
        // Given
        let fastMiddleware = SlowMiddleware(delay: 0.01) // 10ms
        let timeoutMiddleware = TimeoutMiddleware(
            defaultTimeout: 0.1 // 100ms timeout
        )
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(fastMiddleware)
        try await pipeline.addMiddleware(timeoutMiddleware)
        
        let context = CommandContext.test()
        let command = TestCommand(value: "fast")
        
        // When
        let result = try await pipeline.execute(command, context: context)
        
        // Then - Should complete without timeout
        XCTAssertEqual(result, "fast")
    }
    
    func testTimeoutMiddlewareWithGracePeriod() async throws {
        // Given
        let slowMiddleware = SlowMiddleware(delay: 0.15) // 150ms
        let timeoutMiddleware = TimeoutMiddleware(
            configuration: TimeoutMiddleware.Configuration(
                defaultTimeout: 0.1, // 100ms timeout
                // Use a slightly larger grace period to account for CI/macOS scheduler jitter
                gracePeriod: 0.2    // 200ms grace period
            )
        )
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(slowMiddleware)
        try await pipeline.addMiddleware(timeoutMiddleware)
        
        let context = CommandContext.test()
        let command = TestCommand(value: "grace")
        
        // When
        let result = try await pipeline.execute(command, context: context)
        
        // Then - Should complete within grace period
        XCTAssertEqual(result, "grace")
    }
    
    func testTimeoutMiddlewareWithCommandSpecificTimeout() async throws {
        // Skip on CI to avoid scheduler-induced flakiness
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Skipping flaky command-specific timeout test on CI")
        }
        // Given - Command that implements TimeoutConfigurable
        struct TimeoutCommand: Command, TimeoutConfigurable {
            typealias Result = String
            let timeout: TimeInterval = 0.05 // 50ms timeout
            let value: String
            
            func execute() async throws -> String {
                return value
            }
        }
        
        struct TimeoutHandler: CommandHandler {
            typealias CommandType = TimeoutCommand
            
            func handle(_ command: TimeoutCommand) async throws -> String {
                return command.value
            }
        }
        
        let slowMiddleware = SlowMiddleware(delay: 0.1) // 100ms
        let timeoutMiddleware = TimeoutMiddleware(
            defaultTimeout: 1.0 // 1s default (should be overridden)
        )
        
        let handler = TimeoutHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(timeoutMiddleware)
        try await pipeline.addMiddleware(slowMiddleware)
        
        let context = CommandContext.test()
        let command = TimeoutCommand(value: "specific")
        
        // When/Then - Should use command-specific timeout (allow brief retries on CI)
        var didTimeout = false
        for _ in 0..<3 {
            do {
                _ = try await pipeline.execute(command, context: context)
                // small delay before retry
                try? await Task.sleep(nanoseconds: 5_000_000)
            } catch let error as PipelineError {
                if case .timeout = error {
                    didTimeout = true
                    break
                } else {
                    XCTFail("Expected timeout error, got: \(error)")
                }
            }
        }
        XCTAssertTrue(didTimeout, "Should have timed out")
    }
}
