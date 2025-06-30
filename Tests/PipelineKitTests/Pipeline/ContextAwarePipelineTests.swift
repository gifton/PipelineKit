import XCTest
@testable import PipelineKit

final class ContextAwarePipelineTests: XCTestCase {
    
    // Test command
    struct CalculateCommand: Command {
        typealias Result = Int
        let value: Int
        
        func execute() async throws -> Int {
            return value * 2
        }
    }
    
    // Test handler
    struct CalculateHandler: CommandHandler {
        typealias CommandType = CalculateCommand
        
        func handle(_ command: CalculateCommand) async throws -> Int {
            return command.value * 2
        }
    }
    
    // Test context key for multiplier
    struct MultiplierKey: ContextKey {
        typealias Value = Int
    }
    
    // Test context key for accumulator
    struct AccumulatorKey: ContextKey {
        typealias Value = [String]
    }
    
    // Context-aware middleware that modifies result
    struct MultiplierMiddleware: Middleware {
        let multiplier: Int
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            await context.set(multiplier, for: MultiplierKey.self)
            
            let result = try await next(command, context)
            
            if let intResult = result as? Int {
                return (intResult * multiplier) as! T.Result
            }
            
            return result
        }
    }
    
    // Middleware that accumulates execution info
    struct AccumulatorMiddleware: Middleware {
        let name: String
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            var accumulator = await context[AccumulatorKey.self] ?? []
            accumulator.append("\(name):before")
            await context.set(accumulator, for: AccumulatorKey.self)
            
            let result = try await next(command, context)
            
            accumulator = await context[AccumulatorKey.self] ?? []
            accumulator.append("\(name):after")
            await context.set(accumulator, for: AccumulatorKey.self)
            
            return result
        }
    }
    
    func testBasicStandardPipeline() async throws {
        let pipeline = StandardPipeline(handler: CalculateHandler())
        let context = await CommandContext.test()
        
        let result = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        XCTAssertEqual(result, 10) // 5 * 2
    }
    
    func testContextSharing() async throws {
        let pipeline = StandardPipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(MultiplierMiddleware(multiplier: 3))
        
        let context = await CommandContext.test()
        let result = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        XCTAssertEqual(result, 30) // (5 * 2) * 3
    }
    
    func testMultipleContextMiddleware() async throws {
        let pipeline = StandardPipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(AccumulatorMiddleware(name: "First"))
        try await pipeline.addMiddleware(AccumulatorMiddleware(name: "Second"))
        try await pipeline.addMiddleware(MultiplierMiddleware(multiplier: 2))
        
        let context = await CommandContext.test()
        let result = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        XCTAssertEqual(result, 20) // (5 * 2) * 2
        
        // Check accumulator
        let accumulator = await context[AccumulatorKey.self]
        XCTAssertEqual(accumulator, ["First:before", "Second:before", "Second:after", "First:after"])
    }
    
    func testRegularMiddlewareAdapter() async throws {
        let pipeline = StandardPipeline(handler: CalculateHandler())
        
        // Regular middleware
        struct LoggingMiddleware: Middleware {
            let logs: Actor<[String]>
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                await logs.append("Executing: \(T.self)")
                return try await next(command, context)
            }
        }
        
        let logs = Actor<[String]>([])
        try await pipeline.addMiddleware(LoggingMiddleware(logs: logs))
        
        let context = await CommandContext.test()
        _ = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        let logEntries = await logs.get()
        XCTAssertEqual(logEntries.count, 1)
        XCTAssertEqual(logEntries[0], "Executing: CalculateCommand")
    }
    
    func testContextAwarePipelineBuilder() async throws {
        let builder = PipelineBuilder(handler: CalculateHandler())
        _ = await builder.with(AccumulatorMiddleware(name: "First"))
        _ = await builder.with(MultiplierMiddleware(multiplier: 3))
        _ = await builder.withMaxDepth(50)
        
        let pipeline = try await builder.build()
        let context = await CommandContext.test()
        
        let result = try await pipeline.execute(CalculateCommand(value: 4), context: context)
        
        XCTAssertEqual(result, 24) // (4 * 2) * 3
    }
    
    func testAuthenticationFlow() async throws {
        // Simulate authentication and authorization flow
        let authenticatedUsers = ["user123": "John Doe"]
        let userRoles = ["user123": Set(["admin", "user"])]
        
        let authMiddleware = AuthenticationMiddleware { userId in
            guard let userId = userId,
                  authenticatedUsers[userId] != nil else {
                throw AuthorizationError.notAuthenticated
            }
            return userId
        }
        
        let authzMiddleware = AuthorizationMiddleware(
            requiredRoles: ["admin"]
        ) { userId in
            userRoles[userId] ?? []
        }
        
        let pipeline = StandardPipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(authMiddleware)
        try await pipeline.addMiddleware(authzMiddleware)
        
        // Test with valid user
        let validContext = await CommandContext.test(userId: "user123")
        let result = try await pipeline.execute(
            CalculateCommand(value: 10),
            context: validContext
        )
        XCTAssertEqual(result, 20)
        
        // Test with invalid user
        let invalidContext = await CommandContext.test(userId: "unknown")
        do {
            _ = try await pipeline.execute(
                CalculateCommand(value: 10),
                context: invalidContext
            )
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertTrue(error is AuthorizationError)
        }
    }
    
    func testMetricsCollection() async throws {
        let pipeline = StandardPipeline(handler: CalculateHandler())
        
        // Add metrics middleware
        let metricsCollector = StandardAdvancedMetricsCollector()
        let metricsMiddleware = MetricsMiddleware(collector: metricsCollector)
        try await pipeline.addMiddleware(metricsMiddleware)
        
        let context = await CommandContext.testWithMetrics()
        _ = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        // Verify metrics were collected via context
        let metadata = await context.commandMetadata
        XCTAssertNotNil(metadata)
    }
    
    func testContextInitialValues() async throws {
        struct ContextInspectorMiddleware: Middleware {
            let onExecute: @Sendable (CommandContext) async -> Void
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                await onExecute(context)
                return try await next(command, context)
            }
        }
        
        let expectation = XCTestExpectation(description: "Context inspection")
        let capturedData = Actor<(String?, String?, Date?)>((nil, nil, nil))
        
        let inspector = ContextInspectorMiddleware { context in
            let metadata = await context.commandMetadata
            let requestId = await context.get(RequestIDKey.self)
            await capturedData.set((metadata.userId, requestId, metadata.timestamp))
            expectation.fulfill()
        }
        
        let pipeline = StandardPipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(inspector)
        
        let context = await CommandContext.test(userId: "test-user-123")
        _ = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        let (capturedUserId, _, capturedTimestamp) = await capturedData.get()
        XCTAssertEqual(capturedUserId, "test-user-123")
        XCTAssertNotNil(capturedTimestamp)
    }
    
    func testContextPropagationAcrossMiddleware() async throws {
        struct ContextSetterMiddleware: Middleware {
            let value: String
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                await context.set(value, for: TestCustomValueKey.self)
                return try await next(command, context)
            }
        }
        
        struct ContextVerifierMiddleware: Middleware {
            let expectedValue: String
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                let value = await context.get(TestCustomValueKey.self)
                XCTAssertEqual(value, expectedValue)
                return try await next(command, context)
            }
        }
        
        let pipeline = StandardPipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(ContextSetterMiddleware(value: "test-value"))
        try await pipeline.addMiddleware(ContextVerifierMiddleware(expectedValue: "test-value"))
        
        let context = await CommandContext.test()
        let result = try await pipeline.execute(CalculateCommand(value: 7), context: context)
        
        XCTAssertEqual(result, 14)
        
        // Verify context persists after execution
        let finalValue = await context.get(TestCustomValueKey.self)
        XCTAssertEqual(finalValue, "test-value")
    }
}

// Helper actor for thread-safe test data collection
actor Actor<T: Sendable>: Sendable {
    private var value: T
    
    init(_ value: T) {
        self.value = value
    }
    
    func get() -> T {
        value
    }
    
    func set(_ newValue: T) {
        value = newValue
    }
    
    func append(_ element: String) where T == [String] {
        value.append(element)
    }
    
    func append(_ element: (String, TimeInterval)) where T == [(String, TimeInterval)] {
        value.append(element)
    }
}