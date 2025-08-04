import XCTest
@testable import PipelineKit

final class ParallelMiddlewareContextTests: XCTestCase {
    
    // MARK: - Test Types
    
    struct TestCommand: Command {
        typealias Result = String
        let id: String
    }
    
    struct CounterKey: ContextKey {
        typealias Value = Int
    }
    
    struct MessagesKey: ContextKey {
        typealias Value = [String]
    }
    
    struct ThreadIDKey: ContextKey {
        typealias Value = String
    }
    
    // MARK: - Test Middleware
    
    final class ContextModifyingMiddleware: Middleware {
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
            let currentCount = context[CounterKey.self] ?? 0
            
            // Add message
            var messages = context[MessagesKey.self] ?? []
            messages.append("Middleware \(id) started with count: \(currentCount)")
            context.set(messages, for: MessagesKey.self)
            
            // Record thread info
            context.set("\(id)-\(UUID().uuidString)", for: ThreadIDKey.self)
            
            // Simulate some work
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            // Increment counter
            context.set(currentCount + 1, for: CounterKey.self)
            
            // Add completion message
            messages = context[MessagesKey.self] ?? []
            messages.append("Middleware \(id) completed")
            context.set(messages, for: MessagesKey.self)
            
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
        context.set(0, for: CounterKey.self)
        
        // When: We execute in parallel
        let result = try await wrapper.execute(command, context: context) { cmd, ctx in
            "completed"
        }
        
        // Then: The original context is unchanged (isolation works)
        XCTAssertEqual(result, "completed")
        XCTAssertEqual(context[CounterKey.self], 0, "Original context should be unchanged")
        XCTAssertNil(context[MessagesKey.self], "Original context should have no messages")
        XCTAssertNil(context[ThreadIDKey.self], "Original context should have no thread ID")
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
            strategy: .sideEffectsWithMerge
        )
        
        let command = TestCommand(id: "test")
        let context = CommandContext()
        context.set(0, for: CounterKey.self)
        
        // When: We execute with merging
        let result = try await wrapper.execute(command, context: context) { cmd, ctx in
            "completed"
        }
        
        // Then: Context changes are merged back
        XCTAssertEqual(result, "completed")
        
        // Counter should have been incremented by one of the middleware (last merge wins)
        let finalCount = context[CounterKey.self] ?? 0
        XCTAssertEqual(finalCount, 1, "Counter should be incremented")
        
        // Messages from all middleware should be present (arrays get replaced)
        let messages = context[MessagesKey.self] ?? []
        XCTAssertTrue(messages.count >= 2, "Should have messages from at least one middleware")
        
        // Thread ID from one of the middleware
        XCTAssertNotNil(context[ThreadIDKey.self])
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
                context.set(id, for: ThreadIDKey.self)
                
                // Small delay to ensure concurrent execution
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                
                // Check if our value is still there
                let currentValue = context[ThreadIDKey.self]
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
                context.set("\(validationKey)-validated", for: ThreadIDKey.self)
                
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
        XCTAssertNil(context[ThreadIDKey.self])
    }
    
    // MARK: - Performance Tests
    
    func testContextForkingPerformance() throws {
        // Given: A context with multiple values
        let context = CommandContext()
        for i in 0..<100 {
            context.set("value-\(i)", for: StringKey.self)
            context.set(i, for: IntKey.self)
        }
        
        // When/Then: Measure forking performance
        measure {
            for _ in 0..<1000 {
                _ = context.fork()
            }
        }
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
    
    struct StringKey: ContextKey {
        typealias Value = String
    }
    
    struct IntKey: ContextKey {
        typealias Value = Int
    }
    
    enum TestError: Error {
        case validationFailed
        case contextInterference(expected: String, actual: String)
    }
    
    final class LightweightMiddleware: Middleware {
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
            context.set("executed-\(id)", for: StringKey.self)
            throw ParallelExecutionError.middlewareShouldNotCallNext
        }
    }
}