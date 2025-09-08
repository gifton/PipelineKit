import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

final class PipelineTests: XCTestCase {
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
        
        func execute() async throws -> String {
            return value.uppercased()
        }
    }
    
    private struct FailingCommand: Command {
        typealias Result = String
        let error: Error
        
        func execute() async throws -> String {
            throw error
        }
    }
    
    private struct TestMiddleware: Middleware {
        let id: String
        let transform: @Sendable (String) -> String
        let priority: ExecutionPriority
        
        init(id: String, transform: @escaping @Sendable (String) -> String, priority: ExecutionPriority = .custom) {
            self.id = id
            self.transform = transform
            self.priority = priority
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            let result = try await next(command, context)
            
            // Transform string results
            if let stringResult = result as? String {
                let transformed = transform(stringResult)
                if let typedResult = transformed as? T.Result {
                    return typedResult
                }
            }
            
            return result
        }
    }
    
    // MARK: - Pipeline Protocol Tests
    
    func testPipelineProtocolConformance() async throws {
        // Verify that Pipeline protocol has required methods
        struct MockPipeline: Pipeline {
            func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
                // In a real pipeline, this would call through to a handler
                // For testing, just return a dummy result
                if let testCommand = command as? TestCommand,
                   let result = try await testCommand.execute() as? T.Result {
                    return result
                }
                fatalError("Unsupported command type")
            }
        }
        
        let pipeline = MockPipeline()
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        let result = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result, "TEST")
    }
    
    func testPipelineDefaultExecuteMethod() async throws {
        // Test the default execute method that creates its own context
        struct MockPipeline: Pipeline {
            var executedWithContext = false
            
            func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
                if let testCommand = command as? TestCommand,
                   let result = try await testCommand.execute() as? T.Result {
                    return result
                }
                fatalError("Unsupported command type")
            }
        }
        
        let pipeline = MockPipeline()
        let command = TestCommand(value: "hello")
        
        // Use the default execute method (without providing context)
        let result = try await pipeline.execute(command)
        XCTAssertEqual(result, "HELLO")
    }
    
    // MARK: - Middleware Execution Tests
    
    func testMiddlewareExecutionOrder() async throws {
        // Test that middleware executes in correct order
        let executionOrder = TestActor<[String]>([])
        
        struct OrderTestMiddleware: Middleware {
            let id: String
            let tracker: TestActor<[String]>
            let priority = ExecutionPriority.custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                await tracker.append(id + "-before")
                let result = try await next(command, context)
                await tracker.append(id + "-after")
                return result
            }
        }
        
        // Create a mock pipeline that accepts middleware
        let middleware1 = OrderTestMiddleware(id: "M1", tracker: executionOrder)
        let middleware2 = OrderTestMiddleware(id: "M2", tracker: executionOrder)
        
        // Simulate middleware chain execution
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        // Build chain manually (simulating what a pipeline would do)
        let finalHandler: @Sendable (TestCommand, CommandContext) async throws -> String = { cmd, _ in
            await executionOrder.append("handler")
            return try await cmd.execute()
        }
        
        let chain2: @Sendable (TestCommand, CommandContext) async throws -> String = { cmd, ctx in
            try await middleware2.execute(cmd, context: ctx, next: finalHandler)
        }
        
        let chain1: @Sendable (TestCommand, CommandContext) async throws -> String = { cmd, ctx in
            try await middleware1.execute(cmd, context: ctx, next: chain2)
        }
        
        _ = try await chain1(command, context)
        
        let order = await executionOrder.get()
        XCTAssertEqual(order, ["M1-before", "M2-before", "handler", "M2-after", "M1-after"])
    }
    
    // MARK: - Priority Tests
    
    func testMiddlewarePriorityOrdering() {
        // Test that middleware with different priorities are sorted correctly
        let middlewares: [any Middleware] = [
            TestMiddleware(id: "1", transform: { $0 }, priority: .postProcessing),  // 500
            TestMiddleware(id: "2", transform: { $0 }, priority: .authentication),  // 100
            TestMiddleware(id: "3", transform: { $0 }, priority: .validation),      // 200
            TestMiddleware(id: "4", transform: { $0 }, priority: .processing)      // 400
        ]
        
        let sorted = middlewares.sorted { $0.priority.rawValue < $1.priority.rawValue }
        
        XCTAssertEqual((sorted[0] as? TestMiddleware)?.id, "2") // authentication (100)
        XCTAssertEqual((sorted[1] as? TestMiddleware)?.id, "3") // validation (200)
        XCTAssertEqual((sorted[2] as? TestMiddleware)?.id, "4") // processing (400)
        XCTAssertEqual((sorted[3] as? TestMiddleware)?.id, "1") // postProcessing (500)
    }
    
    // MARK: - Error Handling Tests
    
    func testMiddlewareErrorPropagation() async throws {
        struct ErrorMiddleware: Middleware {
            let priority = ExecutionPriority.custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                throw TestError.simulatedError
            }
        }
        
        let middleware = ErrorMiddleware()
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Should not reach handler")
                fatalError("Should not reach handler")
            }
            XCTFail("Should throw error")
        } catch {
            XCTAssertEqual(error as? TestError, TestError.simulatedError)
        }
    }
    
    func testCommandExecutionError() async throws {
        let command = FailingCommand(error: TestError.simulatedError)
        
        do {
            _ = try await command.execute()
            XCTFail("Should throw error")
        } catch {
            XCTAssertEqual(error as? TestError, TestError.simulatedError)
        }
    }
    
    // MARK: - Context Propagation Tests
    
    func testContextPropagationThroughMiddleware() async throws {
        struct ContextMiddleware: Middleware {
            let key: String
            let value: String
            let priority = ExecutionPriority.custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                await context.setMetadata(key, value: value)
                return try await next(command, context)
            }
        }
        
        let context = CommandContext()
        let middleware1 = ContextMiddleware(key: "key1", value: "value1")
        let middleware2 = ContextMiddleware(key: "key2", value: "value2")
        
        let command = TestCommand(value: "test")
        
        // Execute through middleware chain
        _ = try await middleware1.execute(command, context: context) { cmd, ctx in
            try await middleware2.execute(cmd, context: ctx) { c, finalCtx in
                // Verify context has both values
                let metadata = await finalCtx.getMetadata()
                XCTAssertEqual(metadata["key1"] as? String, "value1")
                XCTAssertEqual(metadata["key2"] as? String, "value2")
                return try await c.execute()
            }
        }
        
        // Verify context still has values after execution
        let finalMetadata = await context.getMetadata()
        XCTAssertEqual(finalMetadata["key1"] as? String, "value1")
        XCTAssertEqual(finalMetadata["key2"] as? String, "value2")
    }
    
    // MARK: - Cancellation Tests
    
    func testTaskCancellationPropagation() async throws {
        struct SlowCommand: Command {
            typealias Result = String
            
            func execute() async throws -> String {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                return "completed"
            }
        }
        
        let command = SlowCommand()
        let task = Task {
            try await command.execute()
        }
        
        // Cancel after a short delay
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
    
    // MARK: - Concurrent Execution Tests
    
    func testConcurrentPipelineExecution() async throws {
        let executionCount = TestActor<Int>(0)
        
        struct CountingMiddleware: Middleware {
            let counter: TestActor<Int>
            let priority = ExecutionPriority.custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                await counter.increment()
                return try await next(command, context)
            }
        }
        
        let middleware = CountingMiddleware(counter: executionCount)
        let iterations = 100
        
        await withTaskGroup(of: String.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let command = TestCommand(value: "test\(i)")
                    let context = CommandContext()
                    
                    do {
                        return try await middleware.execute(command, context: context) { cmd, _ in
                            try await cmd.execute()
                        }
                    } catch {
                        XCTFail("Unexpected error in concurrent execution: \(error)")
                        return "error"
                    }
                }
            }
            
            for await _ in group {
                // Collect results
            }
        }
        
        let finalCount = await executionCount.get()
        XCTAssertEqual(finalCount, iterations)
    }
    
    // MARK: - Memory Management Tests
    
    func testMiddlewareValueSemantics() {
        // Test that middleware has value semantics (struct)
        let middleware1 = TestMiddleware(id: "test", transform: { $0 + "!" })
        var middleware2 = middleware1
        
        // They should be equal but independent
        XCTAssertEqual(middleware1.id, middleware2.id)
        
        // Modifying one doesn't affect the other (if we had mutable properties)
        middleware2 = TestMiddleware(id: "modified", transform: { $0 + "?" })
        XCTAssertEqual(middleware1.id, "test")
        XCTAssertEqual(middleware2.id, "modified")
    }
    
    // MARK: - Performance Tests
    
    func testPipelinePerformance() async throws {
        // Measure pipeline execution performance
        let command = TestCommand(value: "test")
        let context = CommandContext()
        
        let middleware = TestMiddleware(id: "perf", transform: { $0 })
        
        let start = Date()
        let iterations = 1000
        
        for _ in 0..<iterations {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
        }
        
        let duration = Date().timeIntervalSince(start)
        let opsPerSecond = Double(iterations) / duration
        
        print("Pipeline performance: \(Int(opsPerSecond)) ops/sec")
        XCTAssertGreaterThan(opsPerSecond, 10000) // Should handle at least 10k ops/sec
    }
}

// MARK: - Test Helpers

private enum TestError: Error, Equatable {
    case simulatedError
    case validationFailed
}
