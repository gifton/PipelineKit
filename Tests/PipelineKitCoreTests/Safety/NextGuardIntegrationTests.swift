import XCTest
@testable import PipelineKitCore

final class NextGuardIntegrationTests: XCTestCase {
    
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
        
        func execute() async throws -> String {
            return value
        }
    }
    
    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> TestCommand.Result {
            return command.value + "-handled"
        }
    }
    
    // Test middleware that tries to call next twice (should fail with NextGuard)
    private struct DoubleCallMiddleware: Middleware {
        let priority = ExecutionPriority.custom
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // First call should succeed
            let result = try await next(command, context)
            
            // Second call should throw
            _ = try await next(command, context)
            
            return result
        }
    }
    
    // Test unsafe middleware that can call next twice (should work)
    private struct UnsafeDoubleCallMiddleware: Middleware, UnsafeMiddleware {
        let priority = ExecutionPriority.custom
        var callCount = 0
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Should be able to call twice without error
            _ = try await next(command, context)
            return try await next(command, context)
        }
    }
    
    // Test middleware that stores next for later use
    private struct StoringMiddleware: Middleware {
        let priority = ExecutionPriority.custom
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Can store next because it's @escaping
            let storedNext = next
            
            // Simulate async delay
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            
            // Call the stored closure
            return try await storedNext(command, context)
        }
    }
    
    // MARK: - Tests
    
    func testStandardPipelineWithNextGuardPreventsDoubleCalls() async throws {
        // Given
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(DoubleCallMiddleware())
        
        // When/Then - Should throw on second call
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        do {
            _ = try await pipeline.execute(command, context: context)
            XCTFail("Should have thrown nextAlreadyCalled error")
        } catch let error as PipelineError {
            if case .nextAlreadyCalled = error {
                // Success - NextGuard prevented double call
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    func testUnsafeMiddlewareCanCallNextMultipleTimes() async throws {
        // Given
        _ = StandardPipeline(handler: TestHandler())
        
        // Create a counting handler to verify double execution
        actor CountingState {
            var count = 0
            func increment() -> Int {
                count += 1
                return count
            }
        }
        
        let countingState = CountingState()
        
        struct CountingHandler: CommandHandler {
            typealias CommandType = TestCommand
            let state: CountingState
            
            func handle(_ command: TestCommand) async throws -> TestCommand.Result {
                let count = await state.increment()
                return command.value + "-handled-\(count)"
            }
        }
        let countingPipeline = StandardPipeline(handler: CountingHandler(state: countingState))
        try await countingPipeline.addMiddleware(UnsafeDoubleCallMiddleware())
        
        // When
        let command = TestCommand(value: "test")
        let context = CommandContext()
        let result = try await countingPipeline.execute(command, context: context)
        
        // Then
        let finalCount = await countingState.count
        XCTAssertEqual(finalCount, 2, "Handler should be called twice by unsafe middleware")
        XCTAssertEqual(result, "test-handled-2")
    }
    
    func testStoringMiddlewareWorksWithEscaping() async throws {
        // Given
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(StoringMiddleware())
        
        // When
        let command = TestCommand(value: "test")
        let context = CommandContext()
        let result = try await pipeline.execute(command, context: context)
        
        // Then
        XCTAssertEqual(result, "test-handled")
    }
    
    func testDynamicPipelineWithNextGuard() async throws {
        // Given
        let pipeline = DynamicPipeline()
        try await pipeline.register(TestCommand.self, handler: TestHandler())
        try await pipeline.addMiddleware(DoubleCallMiddleware())
        
        // When/Then - Should throw on second call
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        do {
            _ = try await pipeline.send(command, context: context)
            XCTFail("Should have thrown nextAlreadyCalled error")
        } catch let error as PipelineError {
            if case .nextAlreadyCalled = error {
                // Success - NextGuard prevented double call
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
}