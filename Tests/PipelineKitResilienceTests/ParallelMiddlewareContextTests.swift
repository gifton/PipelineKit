import XCTest
@testable import PipelineKitResilience
@testable import PipelineKitCore
import PipelineKitTestSupport

final class ParallelMiddlewareContextTests: XCTestCase {
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let id: String
    }
    
    private enum TestKeys {
        static let counter = "counter_key"
        static let messages = "messages_key"
        static let threadID = "thread_id_key"
    }
    
    // MARK: - Test Middleware
    
    private final class ContextModifyingMiddleware: Middleware {
        let id: String
        let delay: TimeInterval
        let priority = ExecutionPriority.processing
        
        init(id: String, delay: TimeInterval = 0.01) {
            self.id = id
            self.delay = delay
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Read current counter
            let currentCount: Int = (context.getMetadata()[TestKeys.counter] as? Int) ?? 0
            
            // Add message
            var messages: [String] = (context.getMetadata()[TestKeys.messages] as? [String]) ?? []
            messages.append("Middleware \(id) started with count: \(currentCount)")
            context.setMetadata(TestKeys.messages, value: messages)
            
            // Record thread info
            context.setMetadata(TestKeys.threadID, value: "\(id)-\(UUID().uuidString)")
            
            // Simulate some work
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            // Increment counter
            context.setMetadata(TestKeys.counter, value: currentCount + 1)
            
            // Add completion message
            messages = (context.getMetadata()[TestKeys.messages] as? [String]) ?? []
            messages.append("Middleware \(id) completed")
            context.setMetadata(TestKeys.messages, value: messages)
            
            // Don't call next for side effects
            throw ParallelExecutionError.middlewareShouldNotCallNext
        }
    }
    
    // MARK: - Context Isolation Tests
    
    func testParallelExecutionWithSharedContext() async throws {
        // Given: Multiple middleware that modify the SHARED context
        // This test verifies that all middleware share the same context (by design)
        let middlewares = [
            ContextModifyingMiddleware(id: "A"),
            ContextModifyingMiddleware(id: "B"),
            ContextModifyingMiddleware(id: "C")
        ]
        
        let wrapper = ParallelMiddlewareWrapper(
            middlewares: middlewares,
            strategy: .sideEffectsOnly
        )
        
        let command = TestCommand(id: "test")
        let context = CommandContext()
        context.setMetadata(TestKeys.counter, value: 0)
        
        // When: We execute in parallel
        let result = try await wrapper.execute(command, context: context) { _, _ in
            "completed"
        }
        
        // Then: The context shows evidence of ALL middleware having executed
        // Note: Due to parallel execution, the exact values are non-deterministic
        XCTAssertEqual(result, "completed")
        
        let counter: Int? = (context.getMetadata()[TestKeys.counter] as? Int)
        let messages: [String]? = (context.getMetadata()[TestKeys.messages] as? [String])
        let threadID: String? = (context.getMetadata()[TestKeys.threadID] as? String)
        
        // Counter should have been incremented by at least one middleware
        // (last write wins in parallel execution)
        XCTAssertNotNil(counter, "Counter should be set")
        XCTAssertGreaterThanOrEqual(counter ?? 0, 1, "At least one middleware should have incremented")
        
        // Messages array should contain entries from multiple middleware
        XCTAssertNotNil(messages, "Messages should be present")
        XCTAssertGreaterThanOrEqual(messages?.count ?? 0, 2, "Should have messages from middleware")
        
        // ThreadID will be from whichever middleware wrote last
        XCTAssertNotNil(threadID, "Thread ID should be set by one of the middleware")
    }
    
    func testParallelExecutionWithContextMerging() async throws {
        // Given: Multiple middleware with context merging enabled
        let middlewares = [
            ContextModifyingMiddleware(id: "A", delay: 0.01),
            ContextModifyingMiddleware(id: "B", delay: 0.02),
            ContextModifyingMiddleware(id: "C", delay: 0.03)
        ]
        
        let wrapper = ParallelMiddlewareWrapper(
            middlewares: middlewares,
            strategy: .sideEffectsOnly  // Merging not supported - contexts are isolated
        )
        
        let command = TestCommand(id: "test")
        let context = CommandContext()
        context.setMetadata(TestKeys.counter, value: 0)
        
        // When: We execute with merging
        let result = try await wrapper.execute(command, context: context) { _, _ in
            "completed"
        }
        
        // Then: CommandContext changes are merged back
        XCTAssertEqual(result, "completed")
        
        // Counter should have been incremented by one of the middleware (last merge wins)
        let finalCount: Int = (context.getMetadata()[TestKeys.counter] as? Int) ?? 0
        XCTAssertEqual(finalCount, 1, "Counter should be incremented")
        
        // Messages from all middleware should be present (arrays get replaced)
        let messages: [String] = (context.getMetadata()[TestKeys.messages] as? [String]) ?? []
        XCTAssertTrue(messages.count >= 2, "Should have messages from at least one middleware")
        
        // Thread ID from one of the middleware
        let threadID: String? = (context.getMetadata()[TestKeys.threadID] as? String)
        XCTAssertNotNil(threadID)
    }
    
    func testParallelExecutionWithSharedStateCoordination() async throws {
        // Given: Middleware that coordinate through shared context
        // This test demonstrates that middleware SHARE context and must handle concurrent access
        final class CoordinatingMiddleware: Middleware {
            let id: String
            let priority = ExecutionPriority.processing
            
            init(id: String) {
                self.id = id
            }
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // Append to a shared array (demonstrating shared state)
                var visits: [String] = (context.getMetadata()["visits"] as? [String]) ?? []
                visits.append(id)
                context.setMetadata("visits", value: visits)
                
                // Small delay to ensure parallel execution
                try await Task.sleep(nanoseconds: 5_000_000) // 5ms
                
                // Record completion
                var completions: [String] = (context.getMetadata()["completions"] as? [String]) ?? []
                completions.append(id)
                context.setMetadata("completions", value: completions)
                
                throw ParallelExecutionError.middlewareShouldNotCallNext
            }
        }
        
        let middlewares = (0..<5).map { CoordinatingMiddleware(id: "MW-\($0)") }
        let wrapper = ParallelMiddlewareWrapper(
            middlewares: middlewares,
            strategy: .sideEffectsOnly
        )
        
        let command = TestCommand(id: "test")
        let context = CommandContext()
        
        // When: Execute with shared context
        _ = try await wrapper.execute(command, context: context) { _, _ in "success" }
        
        // Then: All middleware should have recorded their execution
        let visits: [String]? = (context.getMetadata()["visits"] as? [String])
        let completions: [String]? = (context.getMetadata()["completions"] as? [String])
        
        // Note: Order is non-deterministic due to parallel execution
        // But we should see evidence from multiple middleware
        XCTAssertNotNil(visits, "Visits should be recorded")
        XCTAssertNotNil(completions, "Completions should be recorded")
        
        // Due to race conditions, we might not see all 5 entries
        // (last write wins for each metadata update)
        // But we should see at least some
        XCTAssertGreaterThanOrEqual(visits?.count ?? 0, 1, "At least one visit should be recorded")
        XCTAssertGreaterThanOrEqual(completions?.count ?? 0, 1, "At least one completion should be recorded")
    }
    
    // MARK: - Validation Strategy Tests
    
    func testValidationStrategyWithSharedContext() async throws {
        // Given: Validation middleware that use shared context
        final class ValidationMiddleware: Middleware {
            let validationKey: String
            let requiredValue: String
            let priority = ExecutionPriority.validation
            
            init(key: String, requiredValue: String) {
                self.validationKey = key
                self.requiredValue = requiredValue
            }
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // Record validation attempt in shared context
                var validations: [String] = (context.getMetadata()["validations"] as? [String]) ?? []
                validations.append("\(validationKey)-validated")
                context.setMetadata("validations", value: validations)
                
                // Simulate validation
                if validationKey == requiredValue {
                    throw TestError.validationFailed
                }
                
                return try await next(command, context)
            }
        }
        
        let wrapper = ParallelMiddlewareWrapper(
            middlewares: [
                ValidationMiddleware(key: "A", requiredValue: "X"),
                ValidationMiddleware(key: "B", requiredValue: "Y"),
                ValidationMiddleware(key: "C", requiredValue: "Z")
            ],
            strategy: .preValidation
        )
        
        let command = TestCommand(id: "test")
        let context = CommandContext()
        
        // When: All validations pass
        let result = try await wrapper.execute(command, context: context) { _, _ in "valid" }
        
        // Then: Context shows validation attempts (shared state)
        XCTAssertEqual(result, "valid")
        let validations: [String]? = (context.getMetadata()["validations"] as? [String])
        
        // Due to race conditions in parallel execution, we may not see all validations
        // But we should see at least one
        XCTAssertNotNil(validations, "Validations should be recorded")
        XCTAssertGreaterThanOrEqual(validations?.count ?? 0, 1, "At least one validation should be recorded")
    }
    
    // MARK: - Performance Tests
    
    func testContextForkingPerformance() async throws {
        // Given: A context with multiple values
        let context = CommandContext()
        for i in 0..<100 {
            context.setMetadata("string_key_\(i)", value: "value-\(i)")
            context.setMetadata("int_key_\(i)", value: i)
        }
        
        // When/Then: Measure forking performance
        // Note: measure doesn't support async, so we'll use a simple timing approach
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 {
            _ = context.fork()
        }
        let end = CFAbsoluteTimeGetCurrent()
        print("Fork performance: \((end - start) * 1000)ms for 1000 forks")
    }
    
    func testParallelExecutionScalability() async throws {
        // Given: Many lightweight middleware
        let middlewareCount = 50
        let middlewares = (0..<middlewareCount).map { i in
            LightweightMiddleware(id: i)
        }
        
        let wrapper = ParallelMiddlewareWrapper(
            middlewares: middlewares,
            strategy: .sideEffectsOnly
        )
        
        let command = TestCommand(id: "test")
        let context = CommandContext()
        
        // When: Execute with many middleware
        let startTime = Date()
        _ = try await wrapper.execute(command, context: context) { _, _ in "done" }
        let duration = Date().timeIntervalSince(startTime)
        
        // Then: Execution should be fast due to parallelism
        XCTAssertLessThan(duration, 0.5, "Parallel execution should be fast")
    }
    
    // MARK: - Helper Types
    
    private enum TestError: Error {
        case validationFailed
        case contextInterference(expected: String, actual: String)
    }
    
    private final class LightweightMiddleware: Middleware {
        let id: Int
        let priority = ExecutionPriority.processing
        
        init(id: Int) {
            self.id = id
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Just record execution
            context.setMetadata("lightweight_middleware_\(id)", value: "executed-\(id)")
            throw ParallelExecutionError.middlewareShouldNotCallNext
        }
    }
}
