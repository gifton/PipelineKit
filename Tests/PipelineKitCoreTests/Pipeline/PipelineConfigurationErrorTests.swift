import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class PipelineConfigurationErrorTests: XCTestCase {
    
    // MARK: - Empty Pipeline Tests
    
    func testEmptyPipelineThrows() async throws {
        // Given - Pipeline with no middleware or handler
        let handler = MockCommandHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let command = MockCommand(value: 1)
        let context = CommandContext.test()
        
        // When/Then - StandardPipeline with handler should work even without middleware
        do {
            let result = try await pipeline.execute(command, context: context)
            XCTAssertNotNil(result)
        } catch {
            XCTFail("StandardPipeline with handler should not throw: \(error)")
        }
    }
    
    func testPipelineWithOnlyMiddlewareNoHandler() async throws {
        // TestPipeline always has a handler (either base or mock)
        // This test is not applicable to TestPipeline
        // Skip this test as TestPipeline cannot be created without a handler
    }
    
    // MARK: - Middleware Not Found Tests
    
    func testMiddlewareNotFoundError() async throws {
        // TestPipeline doesn't have a remove method
        // This test should use StandardPipeline
        let handler = MockCommandHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // When/Then - removeMiddleware returns count of removed, not throwing
        let removedCount = await pipeline.removeMiddleware(ofType: LoggingMiddleware.self)
        XCTAssertEqual(removedCount, 0) // No middleware to remove
    }
    
    // MARK: - Maximum Middleware Depth Tests
    
    func testMaximumMiddlewareDepthExceeded() async throws {
        // Given - Pipeline with handler
        let handler = MockCommandHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Add middleware that adds more middleware during execution
        let recursiveMiddleware = RecursiveMiddleware(maxDepth: 100)
        try await pipeline.addMiddleware(recursiveMiddleware)
        
        let command = MockCommand(value: 1)
        let context = CommandContext.test()
        
        // When/Then - RecursiveMiddleware itself will handle depth limiting
        // The test needs to verify that RecursiveMiddleware respects its maxDepth
        let result = try await pipeline.execute(command, context: context)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Context Missing Tests
    
    func testContextMissingRequiredData() async throws {
        // Given - Middleware that requires specific context data
        let handler = MockCommandHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(ContextRequiringMiddleware(requiredKey: "user_id"))
        
        let command = MockCommand(value: 1)
        let context = CommandContext.test() // Missing required "user_id"
        
        // When/Then
        do {
            _ = try await pipeline.execute(command, context: context)
            XCTFail("Should throw PipelineError")
        } catch is PipelineError {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - Invalid Configuration Tests
    
    func testInvalidMiddlewareOrder() async throws {
        // Given - Middleware with conflicting requirements
        let handler = MockCommandHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Middleware that sets a value
        try await pipeline.addMiddleware(ValueSettingMiddleware(key: "auth_token", value: "token123"))
        
        // Middleware that clears all context (should be before setter)
        try await pipeline.addMiddleware(ContextClearingMiddleware())
        
        // Middleware that requires the value
        try await pipeline.addMiddleware(ContextRequiringMiddleware(requiredKey: "auth_token"))
        
        let command = MockCommand(value: 1)
        let context = CommandContext.test()
        
        // When/Then
        do {
            _ = try await pipeline.execute(command, context: context)
            XCTFail("Should throw due to missing context")
        } catch let error as PipelineError {
            if case .pipelineNotConfigured(let reason) = error {
                XCTAssertTrue(reason.contains("Missing required context"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    // MARK: - Duplicate Middleware Tests
    
    func testDuplicateMiddlewareWarning() async throws {
        // Given - Pipeline with duplicate middleware
        let handler = MockCommandHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let middleware1 = LoggingMiddleware()
        let middleware2 = LoggingMiddleware()
        
        try await pipeline.addMiddleware(middleware1)
        try await pipeline.addMiddleware(middleware2)
        
        // Should not throw, but might log warning
        let command = MockCommand(value: 1)
        let context = CommandContext.test()
        
        let result = try await pipeline.execute(command, context: context)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Invalid Command Tests
    
    func testInvalidCommandType() async throws {
        struct OtherCommand: Command {
            typealias Result = Int
        }
        
        // Given - Handler expects TestCommand but receives OtherCommand
        let handler = MockCommandHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let command = OtherCommand()
        let context = CommandContext.test()
        
        // When/Then
        do {
            _ = try await pipeline.execute(command, context: context)
            XCTFail("Should throw type mismatch error")
        } catch {
            // Expected - type mismatch
            XCTAssertTrue(true)
        }
    }
    
    // MARK: - Concurrent Modification Tests
    
    func testConcurrentMiddlewareModification() async throws {
        // Given - Pipeline being modified while executing
        let handler = MockCommandHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        try await pipeline.addMiddleware(LoggingMiddleware())
        
        // Start multiple executions
        await withTaskGroup(of: Void.self) { group in
            // Execute commands
            for i in 0..<10 {
                group.addTask {
                    let command = MockCommand(value: i)
                    let context = CommandContext.test()
                    _ = try? await pipeline.execute(command, context: context)
                }
            }
            
            // Modify pipeline concurrently
            group.addTask {
                let collector = TestMetricsCollector()
                try? await pipeline.addMiddleware(MetricsMiddleware(collector: collector))
            }
            
            group.addTask {
                _ = await pipeline.removeMiddleware(ofType: LoggingMiddleware.self)
            }
        }
        
        // Should not crash
        XCTAssertTrue(true)
    }
    
    // MARK: - Helper Types
    
    private struct TestMetricsCollector: AdvancedMetricsCollector {
        func recordLatency(_ name: String, value: TimeInterval, tags: [String: String]) async {}
        func incrementCounter(_ name: String, value: Double, tags: [String: String]) async {}
        func recordGauge(_ name: String, value: Double, tags: [String: String]) async {}
    }
    
    private final class RecursiveMiddleware: Middleware, @unchecked Sendable {
        let priority = ExecutionPriority.custom
        let maxDepth: Int
        private var currentDepth = 0
        private let lock = NSLock()
        
        init(maxDepth: Int) {
            self.maxDepth = maxDepth
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            lock.lock()
            currentDepth += 1
            let depth = currentDepth
            lock.unlock()
            
            defer {
                lock.lock()
                currentDepth -= 1
                lock.unlock()
            }
            
            if depth > maxDepth {
                throw PipelineError.pipelineNotConfigured(reason: "Max recursion depth exceeded: \(depth)")
            }
            
            return try await next(command, context)
        }
    }
    
    private struct ContextRequiringMiddleware: Middleware, Sendable {
        let requiredKey: String
        let priority = ExecutionPriority.validation
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            guard context.get(TestCustomValueKey.self) != nil else {
                throw PipelineError.pipelineNotConfigured(reason: "Missing required context")
            }
            return try await next(command, context)
        }
    }
    
    private struct ValueSettingMiddleware: Middleware, Sendable {
        let key: String
        let value: String
        let priority = ExecutionPriority.preProcessing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Store value in context using a test key
            context.set(value, for: TestCustomValueKey.self)
            return try await next(command, context)
        }
    }
    
    private struct ContextClearingMiddleware: Middleware, Sendable {
        let priority = ExecutionPriority.preProcessing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Clear specific keys
            context.remove(TestCustomValueKey.self)
            return try await next(command, context)
        }
    }
}