import XCTest
import Foundation
import Synchronization
@testable import PipelineKit
@testable import PipelineKitCore
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
            
            func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
                // Simulate work that far outlasts any scheduling stall. With 1s of work,
                // a stall past it let the handler return before the cancellation below.
                // The sleep is cancelled, so the test does not wait for it.
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                return "completed"
            }
        }
        
        let pipeline = StandardPipeline(handler: TestHandler())
        
        let task = Task {
            try await pipeline.execute(TestCommand(), context: CommandContext())
        }
        
        // Give the task time to start. The outcome does not depend on it: a task
        // cancelled before it starts is rejected with the same error.
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Cancel the task
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            // Check if it's any kind of cancellation error
            XCTAssertTrue((error as? PipelineError)?.isCancellation == true,
                          "Expected PipelineError.cancelled, got \(error)")
        }
    }
    
    func testPipelineWithMiddlewareStopsOnCancellation() async throws {
        // Create test middleware that tracks execution
        final class TrackingMiddleware: Middleware, @unchecked Sendable {
            let priority = ExecutionPriority.processing
            // Read by the test task while the pipeline task writes it.
            private let started = Mutex(false)
            private let completed = Mutex(false)
            var executionStarted: Bool { started.withLock { $0 } }
            var executionCompleted: Bool { completed.withLock { $0 } }
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                started.withLock { $0 = true }
                defer { completed.withLock { $0 = true } }
                
                // Simulate work that far outlasts any scheduling stall. With 500ms of
                // work, a stall past it let the middleware finish before the
                // cancellation below. The sleep is cancelled, so the test does not
                // wait for it.
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                
                return try await next(command, context)
            }
        }
        
        struct TestCommand: Command {
            typealias Result = String
        }
        
        struct TestHandler: CommandHandler {
            typealias CommandType = TestCommand
            
            func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
                return "completed"
            }
        }
        
        let pipeline = StandardPipeline(handler: TestHandler())
        let middleware = TrackingMiddleware()
        try await pipeline.addMiddleware(middleware)
        
        let task = Task {
            try await pipeline.execute(TestCommand(), context: CommandContext())
        }
        
        // Wait until the middleware has started, instead of assuming 200ms is enough.
        // The deadline only bounds a hang.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !middleware.executionStarted && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        
        // Verify middleware started
        XCTAssertTrue(middleware.executionStarted)
        
        // Cancel the task
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            // Check if it's any kind of cancellation error
            XCTAssertTrue((error as? PipelineError)?.isCancellation == true,
                          "Expected PipelineError.cancelled, got \(error)")
        }
    }
    
    // MARK: - DynamicPipeline Cancellation Tests
    
    func testDynamicPipelineRetryStopsOnCancellation() async throws {
        struct TestCommand: Command {
            typealias Result = String
        }
        
        final class FailingHandler: CommandHandler, @unchecked Sendable {
            typealias CommandType = TestCommand
            var attemptCount = 0
            
            func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
                attemptCount += 1
                throw SimpleCancellationTestError.simulatedFailure
            }
        }
        
        let dynamicPipeline = DynamicPipeline()
        let handler = FailingHandler()
        
        await dynamicPipeline.register(TestCommand.self, handler: handler)
        
        let retryPolicy = RetryPolicy(
            maxAttempts: 5,
            delayStrategy: .fixed(0.5),
            shouldRetry: { _ in true }
        )
        
        let task = Task {
            try await dynamicPipeline.send(TestCommand(), retryPolicy: retryPolicy)
        }
        
        // Give time for first attempt
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Cancel the task
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Expected cancellation error")
        } catch is CancellationError {
            // Expected - retry should stop on cancellation
        } catch let error as PipelineError {
            // Also accept PipelineError.cancelled
            XCTAssertTrue(error.isCancellation, "Expected cancellation error, got \(error)")
        } catch {
            XCTFail("Expected cancellation error, got \(error)")
        }
    }
    
    func testDynamicPipelineDoesNotRetryOnCancellationError() async throws {
        struct TestCommand: Command {
            typealias Result = String
        }
        
        final class CancellingHandler: CommandHandler, @unchecked Sendable {
            typealias CommandType = TestCommand
            var attemptCount = 0
            
            func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
                attemptCount += 1
                throw PipelineError.cancelled(context: "Handler cancelled")
            }
        }
        
        let dynamicPipeline = DynamicPipeline()
        let handler = CancellingHandler()
        
        await dynamicPipeline.register(TestCommand.self, handler: handler)
        
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            delayStrategy: .fixed(0.1),
            shouldRetry: { _ in true }
        )
        
        do {
            _ = try await dynamicPipeline.send(TestCommand(), retryPolicy: retryPolicy)
            XCTFail("Expected CancellationError")
        } catch {
            // Check if it's a cancellation error (either type)
            let isCancellation = error is CancellationError ||
                                (error as? PipelineError)?.isCancellation == true
            XCTAssertTrue(isCancellation,
                         "Expected cancellation error, got \(error)")
            XCTAssertEqual(handler.attemptCount, 1, "Should only attempt once for cancellation errors")
        }
    }
    
    // MARK: - Integration Test
    
    func testCancellationPropagatesThroughEntireStack() async throws {
        // This tests cancellation through the entire stack:
        // DynamicPipeline -> Middleware -> Handler
        
        struct SlowCommand: Command {
            typealias Result = String
        }
        
        struct SlowHandler: CommandHandler {
            typealias CommandType = SlowCommand
            
            func handle(_ command: SlowCommand, context: CommandContext) async throws -> String {
                // Simulate slow operation
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                return "completed"
            }
        }
        
        // Conforms to NextGuardWarningSuppressing because this may be cancelled before next() is called
        final class SlowMiddleware: Middleware, NextGuardWarningSuppressing, @unchecked Sendable {
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
        
        let dynamicPipeline = DynamicPipeline()
        let handler = SlowHandler()
        
        await dynamicPipeline.register(SlowCommand.self, handler: handler)
        try await dynamicPipeline.addMiddleware(SlowMiddleware())
        
        let task = Task {
            try await dynamicPipeline.send(SlowCommand())
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
            XCTAssertTrue((error as? PipelineError)?.isCancellation == true,
                          "Expected PipelineError.cancelled, got \(error)")
        }
    }
}

// MARK: - Test Error

private enum SimpleCancellationTestError: Error {
    case simulatedFailure
}
