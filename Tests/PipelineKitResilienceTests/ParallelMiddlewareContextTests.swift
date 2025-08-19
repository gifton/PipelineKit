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
            let currentCount: Int = (await context.getMetadata()[TestKeys.counter] as? Int) ?? 0
            
            // Add message
            var messages: [String] = (await context.getMetadata()[TestKeys.messages] as? [String]) ?? []
            messages.append("Middleware \(id) started with count: \(currentCount)")
            await context.setMetadata(TestKeys.messages, value: messages)
            
            // Record thread info
            await context.setMetadata(TestKeys.threadID, value: "\(id)-\(UUID().uuidString)")
            
            // Simulate some work
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            // Increment counter
            await context.setMetadata(TestKeys.counter, value: currentCount + 1)
            
            // Add completion message
            messages = (await context.getMetadata()[TestKeys.messages] as? [String]) ?? []
            messages.append("Middleware \(id) completed")
            await context.setMetadata(TestKeys.messages, value: messages)
            
            // Don't call next for side effects
            throw ParallelExecutionError.middlewareShouldNotCallNext
        }
    }
    
    // MARK: - Context Isolation Tests
    
    func testParallelExecutionWithContextIsolation() async throws {
        // Given: Multiple middleware that modify context
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
        await context.setMetadata(TestKeys.counter, value: 0)
        
        // When: We execute in parallel
        let result = try await wrapper.execute(command, context: context) { _, _ in
            "completed"
        }
        
        // Then: The original context is unchanged (isolation works)
        XCTAssertEqual(result, "completed")
        let counter: Int? = (await context.getMetadata()[TestKeys.counter] as? Int)
        let messages: [String]? = (await context.getMetadata()[TestKeys.messages] as? [String])
        let threadID: String? = (await context.getMetadata()[TestKeys.threadID] as? String)
        XCTAssertEqual(counter, 0, "Original context should be unchanged")
        XCTAssertNil(messages, "Original context should have no messages")
        XCTAssertNil(threadID, "Original context should have no thread ID")
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
        await context.setMetadata(TestKeys.counter, value: 0)
        
        // When: We execute with merging
        let result = try await wrapper.execute(command, context: context) { _, _ in
            "completed"
        }
        
        // Then: CommandContext changes are merged back
        XCTAssertEqual(result, "completed")
        
        // Counter should have been incremented by one of the middleware (last merge wins)
        let finalCount: Int = (await context.getMetadata()[TestKeys.counter] as? Int) ?? 0
        XCTAssertEqual(finalCount, 1, "Counter should be incremented")
        
        // Messages from all middleware should be present (arrays get replaced)
        let messages: [String] = (await context.getMetadata()[TestKeys.messages] as? [String]) ?? []
        XCTAssertTrue(messages.count >= 2, "Should have messages from at least one middleware")
        
        // Thread ID from one of the middleware
        let threadID: String? = (await context.getMetadata()[TestKeys.threadID] as? String)
        XCTAssertNotNil(threadID)
    }
    
    func testContextIsolationPreventsInterference() async throws {
        // Given: Middleware that would interfere if sharing context
        final class InterferingMiddleware: Middleware {
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
                // Each middleware tries to set and check its own value
                await context.setMetadata(TestKeys.threadID, value: id)
                
                // Small delay to ensure concurrent execution
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                
                // Check if our value is still there
                let currentValue: String? = (await context.getMetadata()[TestKeys.threadID] as? String)
                if currentValue != id {
                    throw TestError.contextInterference(
                        expected: id,
                        actual: currentValue ?? "nil"
                    )
                }
                
                throw ParallelExecutionError.middlewareShouldNotCallNext
            }
        }
        
        let middlewares = (0..<10).map { InterferingMiddleware(id: "MW-\($0)") }
        let wrapper = ParallelMiddlewareWrapper(
            middlewares: middlewares,
            strategy: .sideEffectsOnly
        )
        
        let command = TestCommand(id: "test")
        let context = CommandContext()
        
        // When/Then: Execute should succeed without interference errors
        _ = try await wrapper.execute(command, context: context) { _, _ in "success" }
    }
    
    // MARK: - Validation Strategy Tests
    
    func testValidationStrategyWithIsolation() async throws {
        // Given: Validation middleware
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
                // Set validation result
                await context.setMetadata(TestKeys.threadID, value: "\(validationKey)-validated")
                
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
        
        // Then: Original context is unchanged (isolation)
        XCTAssertEqual(result, "valid")
        let threadID: String? = (await context.getMetadata()[TestKeys.threadID] as? String)
        XCTAssertNil(threadID)
    }
    
    // MARK: - Performance Tests
    
    func testContextForkingPerformance() async throws {
        // Given: A context with multiple values
        let context = CommandContext()
        for i in 0..<100 {
            await context.setMetadata("string_key_\(i)", value: "value-\(i)")
            await context.setMetadata("int_key_\(i)", value: i)
        }
        
        // When/Then: Measure forking performance
        // Note: measure doesn't support async, so we'll use a simple timing approach
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 {
            _ = await context.fork()
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
            await context.setMetadata("lightweight_middleware_\(id)", value: "executed-\(id)")
            throw ParallelExecutionError.middlewareShouldNotCallNext
        }
    }
}
