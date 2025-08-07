import XCTest
import Foundation
@testable import PipelineKit
import PipelineKitTestSupport

final class SimpleCancellationTests: XCTestCase {
    // MARK: - Pipeline Cancellation Tests
    
    func testPipelineExecutionThrowsOnCancellation() async throws {
        // Create a test command and handler
        struct TestCommand: Command {
            typealias Result = String
        }
        
        struct TestHandler: CommandHandler {
            typealias CommandType = TestCommand
            
            func handle(_ command: TestCommand) async throws -> String {
                // Simulate some work
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                return "completed"
            }
        }
        
        let pipeline = StandardPipeline(handler: TestHandler())
        
        let task = Task {
            try await pipeline.execute(TestCommand(), context: CommandContext())
        }
        
        // Give the task time to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Cancel the task
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            // Check if it's any kind of cancellation error
            let errorString = String(describing: error)
            XCTAssertTrue(errorString.contains("CancellationError") || error is CancellationError,
                         "Expected CancellationError, got \(error)")
        }
    }
    
    func testPipelineWithMiddlewareStopsOnCancellation() async throws {
        // Create test middleware that tracks execution
        final class TrackingMiddleware: Middleware, @unchecked Sendable {
            let priority = ExecutionPriority.processing
            var executionStarted = false
            var executionCompleted = false
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                executionStarted = true
                defer { executionCompleted = true }
                
                // Simulate some work
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                
                return try await next(command, context)
            }
        }
        
        struct TestCommand: Command {
            typealias Result = String
        }
        
        struct TestHandler: CommandHandler {
            typealias CommandType = TestCommand
            
            func handle(_ command: TestCommand) async throws -> String {
                return "completed"
            }
        }
        
        let pipeline = StandardPipeline(handler: TestHandler())
        let middleware = TrackingMiddleware()
        try await pipeline.addMiddleware(middleware)
        
        let task = Task {
            try await pipeline.execute(TestCommand(), context: CommandContext())
        }
        
        // Give the task time to start middleware execution
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Verify middleware started
        XCTAssertTrue(middleware.executionStarted)
        
        // Cancel the task
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            // Check if it's any kind of cancellation error
            let errorString = String(describing: error)
            XCTAssertTrue(errorString.contains("CancellationError") || error is CancellationError,
                         "Expected CancellationError, got \(error)")
        }
    }
    
    // MARK: - CommandBus Cancellation Tests
    
    func testCommandBusRetryStopsOnCancellation() async throws {
        struct TestCommand: Command {
            typealias Result = String
        }
        
        final class FailingHandler: CommandHandler, @unchecked Sendable {
            typealias CommandType = TestCommand
            var attemptCount = 0
            
            func handle(_ command: TestCommand) async throws -> String {
                attemptCount += 1
                throw SimpleCancellationTestError.simulatedFailure
            }
        }
        
        let commandBus = CommandBus()
        let handler = FailingHandler()
        
        try await commandBus.register(TestCommand.self, handler: handler)
        
        let retryPolicy = RetryPolicy(
            maxAttempts: 5,
            delayStrategy: .fixed(0.5),
            shouldRetry: { _ in true }
        )
        
        let task = Task {
            try await commandBus.send(TestCommand(), retryPolicy: retryPolicy)
        }
        
        // Give time for first attempt
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Cancel the task
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected - retry should stop on cancellation
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
    
    func testCommandBusDoesNotRetryOnCancellationError() async throws {
        struct TestCommand: Command {
            typealias Result = String
        }
        
        final class CancellingHandler: CommandHandler, @unchecked Sendable {
            typealias CommandType = TestCommand
            var attemptCount = 0
            
            func handle(_ command: TestCommand) async throws -> String {
                attemptCount += 1
                throw PipelineError.cancelled(context: "Handler cancelled")
            }
        }
        
        let commandBus = CommandBus()
        let handler = CancellingHandler()
        
        try await commandBus.register(TestCommand.self, handler: handler)
        
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            delayStrategy: .fixed(0.1),
            shouldRetry: { _ in true }
        )
        
        do {
            _ = try await commandBus.send(TestCommand(), retryPolicy: retryPolicy)
            XCTFail("Expected CancellationError")
        } catch {
            // Check if it's a CancellationError
            let errorString = String(describing: error)
            XCTAssertTrue(errorString.contains("CancellationError") || error is CancellationError,
                         "Expected CancellationError, got \(error)")
            XCTAssertEqual(handler.attemptCount, 1, "Should only attempt once for CancellationError")
        }
    }
    
    // MARK: - Integration Test
    
    func testCancellationPropagatesThroughEntireStack() async throws {
        // This tests cancellation through the entire stack:
        // CommandBus -> Pipeline -> Middleware -> Handler
        
        struct SlowCommand: Command {
            typealias Result = String
        }
        
        struct SlowHandler: CommandHandler {
            typealias CommandType = SlowCommand
            
            func handle(_ command: SlowCommand) async throws -> String {
                // Simulate slow operation
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                return "completed"
            }
        }
        
        final class SlowMiddleware: Middleware, @unchecked Sendable {
            let priority = ExecutionPriority.processing
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // Add some delay
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                return try await next(command, context)
            }
        }
        
        let commandBus = CommandBus()
        let handler = SlowHandler()
        
        try await commandBus.register(SlowCommand.self, handler: handler)
        try await commandBus.addMiddleware(SlowMiddleware())
        
        let task = Task {
            try await commandBus.send(SlowCommand())
        }
        
        // Give time for execution to start
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Cancel the task
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            // Check if it's any kind of cancellation error
            let errorString = String(describing: error)
            XCTAssertTrue(errorString.contains("CancellationError") || error is CancellationError,
                         "Expected CancellationError, got \(error)")
        }
    }
}

// MARK: - Test Error

private enum SimpleCancellationTestError: Error {
    case simulatedFailure
}
