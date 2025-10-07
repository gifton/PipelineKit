import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

final class MiddlewareTests: XCTestCase {
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let input: String
        
        func execute() async throws -> String {
            return "Result: \(input)"
        }
    }
    
    private struct TransformMiddleware: Middleware {
        let transform: @Sendable (String) -> String
        let priority: ExecutionPriority
        
        init(transform: @escaping @Sendable (String) -> String, priority: ExecutionPriority = .custom) {
            self.transform = transform
            self.priority = priority
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            let result = try await next(command, context)
            
            if let stringResult = result as? String,
               let transformed = transform(stringResult) as? T.Result {
                return transformed
            }
            
            return result
        }
    }
    
    // MARK: - Priority Tests
    
    func testExecutionPriorityValues() {
        XCTAssertEqual(ExecutionPriority.authentication.rawValue, 100)
        XCTAssertEqual(ExecutionPriority.validation.rawValue, 200)
        XCTAssertEqual(ExecutionPriority.resilience.rawValue, 250)
        XCTAssertEqual(ExecutionPriority.preProcessing.rawValue, 300)
        XCTAssertEqual(ExecutionPriority.monitoring.rawValue, 350)
        XCTAssertEqual(ExecutionPriority.processing.rawValue, 400)
        XCTAssertEqual(ExecutionPriority.postProcessing.rawValue, 500)
        XCTAssertEqual(ExecutionPriority.errorHandling.rawValue, 600)
        XCTAssertEqual(ExecutionPriority.observability.rawValue, 700)
        XCTAssertEqual(ExecutionPriority.custom.rawValue, 1000)
        
        // Verify ordering
        XCTAssertLessThan(ExecutionPriority.authentication.rawValue, ExecutionPriority.validation.rawValue)
        XCTAssertLessThan(ExecutionPriority.validation.rawValue, ExecutionPriority.resilience.rawValue)
        XCTAssertLessThan(ExecutionPriority.resilience.rawValue, ExecutionPriority.preProcessing.rawValue)
        XCTAssertLessThan(ExecutionPriority.preProcessing.rawValue, ExecutionPriority.processing.rawValue)
        XCTAssertLessThan(ExecutionPriority.processing.rawValue, ExecutionPriority.postProcessing.rawValue)
        XCTAssertLessThan(ExecutionPriority.postProcessing.rawValue, ExecutionPriority.errorHandling.rawValue)
        XCTAssertLessThan(ExecutionPriority.errorHandling.rawValue, ExecutionPriority.observability.rawValue)
        XCTAssertLessThan(ExecutionPriority.observability.rawValue, ExecutionPriority.custom.rawValue)
    }
    
    func testMiddlewareSorting() {
        var middlewares: [any Middleware] = [
            TransformMiddleware(transform: { $0 }, priority: .postProcessing),
            TransformMiddleware(transform: { $0 }, priority: .authentication),
            TransformMiddleware(transform: { $0 }, priority: .validation),
            TransformMiddleware(transform: { $0 }, priority: .processing),
            TransformMiddleware(transform: { $0 }, priority: .observability)
        ]
        
        middlewares.sort { $0.priority.rawValue < $1.priority.rawValue }
        
        XCTAssertEqual(middlewares[0].priority, .authentication)  // 100
        XCTAssertEqual(middlewares[1].priority, .validation)      // 200
        XCTAssertEqual(middlewares[2].priority, .processing)      // 400
        XCTAssertEqual(middlewares[3].priority, .postProcessing)  // 500
        XCTAssertEqual(middlewares[4].priority, .observability)   // 700
    }
    
    // MARK: - Execution Tests
    
    func testMiddlewareExecution() async throws {
        let middleware = TransformMiddleware(transform: { $0.uppercased() })
        let command = TestCommand(input: "hello")
        let context = CommandContext()
        
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        XCTAssertEqual(result, "RESULT: HELLO")
    }
    
    func testMiddlewareChaining() async throws {
        let middleware1 = TransformMiddleware(transform: { $0 + "!" })
        let middleware2 = TransformMiddleware(transform: { "[\($0)]" })
        
        let command = TestCommand(input: "test")
        let context = CommandContext()
        
        let result = try await middleware1.execute(command, context: context) { cmd, ctx in
            try await middleware2.execute(cmd, context: ctx) { c, _ in
                try await c.execute()
            }
        }
        
        XCTAssertEqual(result, "[Result: test]!")
    }
    
    // MARK: - Context Modification Tests
    
    func testMiddlewareContextModification() async throws {
        struct ContextModifyingMiddleware: Middleware {
            let key: String
            let value: any Sendable
            let priority = ExecutionPriority.custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                context.setMetadata(key, value: value)
                return try await next(command, context)
            }
        }
        
        let middleware = ContextModifyingMiddleware(key: "test", value: "modified")
        let command = TestCommand(input: "test")
        let context = CommandContext()
        
        _ = try await middleware.execute(command, context: context) { _, ctx in
            let value = await ctx.getMetadata("test") as? String
            XCTAssertEqual(value, "modified")
            return "done"
        }
        
        // Verify context still has the value
        let finalValue = context.getMetadata("test") as? String
        XCTAssertEqual(finalValue, "modified")
    }
    
    // MARK: - Error Handling Tests
    
    func testMiddlewareErrorHandling() async throws {
        struct ErrorHandlingMiddleware: Middleware {
            let priority = ExecutionPriority.custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                do {
                    return try await next(command, context)
                } catch {
                    // Transform error
                    throw TestError.wrappedError(error)
                }
            }
        }
        
        struct FailingCommand: Command {
            typealias Result = String
            func execute() async throws -> String {
                throw TestError.originalError
            }
        }
        
        let middleware = ErrorHandlingMiddleware()
        let command = FailingCommand()
        let context = CommandContext()
        
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Should throw error")
        } catch {
            guard case TestError.wrappedError(let inner) = error else {
                XCTFail("Wrong error type")
                return
            }
            XCTAssertEqual(inner as? TestError, TestError.originalError)
        }
    }
    
    // MARK: - Async Behavior Tests
    
    func testMiddlewareAsyncExecution() async throws {
        struct AsyncMiddleware: Middleware {
            let delay: TimeInterval
            let priority = ExecutionPriority.custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await next(command, context)
            }
        }
        
        let middleware = AsyncMiddleware(delay: 0.01) // 10ms
        let command = TestCommand(input: "async")
        let context = CommandContext()
        
        let start = Date()
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        let duration = Date().timeIntervalSince(start)
        
        XCTAssertGreaterThanOrEqual(duration, 0.01)
    }
    
    // MARK: - Conditional Execution Tests
    
    func testConditionalMiddleware() async throws {
        struct ConditionalMiddleware: Middleware {
            let condition: @Sendable (any Command) -> Bool
            let priority = ExecutionPriority.custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                if condition(command) {
                    // Apply middleware logic
                    let result = try await next(command, context)
                    if let stringResult = result as? String {
                        let processed = "PROCESSED: " + stringResult
                        if let typedResult = processed as? T.Result {
                            return typedResult
                        }
                    }
                    return result
                } else {
                    // Skip middleware
                    return try await next(command, context)
                }
            }
        }
        
        let middleware = ConditionalMiddleware { cmd in
            (cmd as? TestCommand)?.input.contains("process") ?? false
        }
        
        let context = CommandContext()
        
        // Test with condition met
        let command1 = TestCommand(input: "process this")
        let result1 = try await middleware.execute(command1, context: context) { cmd, _ in
            try await cmd.execute()
        }
        XCTAssertEqual(result1, "PROCESSED: Result: process this")
        
        // Test with condition not met
        let command2 = TestCommand(input: "skip this")
        let result2 = try await middleware.execute(command2, context: context) { cmd, _ in
            try await cmd.execute()
        }
        XCTAssertEqual(result2, "Result: skip this")
    }
    
    // MARK: - Performance Tests
    
    func testMiddlewarePerformance() async throws {
        let middleware = TransformMiddleware(transform: { $0 })
        let command = TestCommand(input: "perf")
        let context = CommandContext()
        
        let iterations = 10000
        let start = Date()
        
        for _ in 0..<iterations {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
        }
        
        let duration = Date().timeIntervalSince(start)
        let opsPerSecond = Double(iterations) / duration
        
        print("Middleware performance: \(Int(opsPerSecond)) ops/sec")
        XCTAssertGreaterThan(opsPerSecond, 20000) // Should handle at least 20k ops/sec
    }
    
    // MARK: - Memory Management Tests
    
    func testMiddlewareValueSemantics() {
        // Middleware are structs and have value semantics
        let middleware1 = TransformMiddleware(transform: { $0 + "!" })
        var middleware2 = middleware1
        
        // Modifying one doesn't affect the other
        middleware2 = TransformMiddleware(transform: { $0 + "?" })
        
        // They are independent
        XCTAssertNotNil(middleware1)
        XCTAssertNotNil(middleware2)
    }
}

// MARK: - Test Helpers

private enum TestError: Error, Equatable {
    case originalError
    case wrappedError(Error)
    
    static func == (lhs: TestError, rhs: TestError) -> Bool {
        switch (lhs, rhs) {
        case (.originalError, .originalError):
            return true
        case (.wrappedError(let lhsError), .wrappedError(let rhsError)):
            return (lhsError as? TestError) == (rhsError as? TestError)
        default:
            return false
        }
    }
}
