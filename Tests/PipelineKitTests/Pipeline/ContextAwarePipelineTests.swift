import XCTest
@testable import PipelineKit

final class ContextAwarePipelineTests: XCTestCase {
    
    // Test command
    struct CalculateCommand: Command {
        typealias Result = Int
        let value: Int
    }
    
    // Test handler
    struct CalculateHandler: CommandHandler {
        typealias CommandType = CalculateCommand
        
        func handle(_ command: CalculateCommand) async throws -> Int {
            return command.value * 2
        }
    }
    
    // Test context key
    struct MultiplierKey: ContextKey {
        typealias Value = Int
    }
    
    // Test context key for accumulator
    struct AccumulatorKey: ContextKey {
        typealias Value = [String]
    }
    
    // Context-aware middleware that modifies result
    struct MultiplierMiddleware: Middleware {
        let priority: ExecutionPriority = .normal
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
        let priority: ExecutionPriority = .normal
        
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
    
    func testBasicContextAwarePipeline() async throws {
        let pipeline = ContextAwarePipeline(handler: CalculateHandler())
        
        let result = try await pipeline.execute(CalculateCommand(value: 5))
        
        XCTAssertEqual(result, 10) // 5 * 2
    }
    
    func testContextSharing() async throws {
        let pipeline = ContextAwarePipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(MultiplierMiddleware(multiplier: 3))
        
        let result = try await pipeline.execute(CalculateCommand(value: 5))
        
        XCTAssertEqual(result, 30) // (5 * 2) * 3
    }
    
    func testMultipleContextMiddleware() async throws {
        let pipeline = ContextAwarePipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(AccumulatorMiddleware(name: "First"))
        try await pipeline.addMiddleware(AccumulatorMiddleware(name: "Second"))
        try await pipeline.addMiddleware(MultiplierMiddleware(multiplier: 2))
        
        let result = try await pipeline.execute(CalculateCommand(value: 5))
        
        XCTAssertEqual(result, 20) // (5 * 2) * 2
    }
    
    func testRegularMiddlewareAdapter() async throws {
        let pipeline = ContextAwarePipeline(handler: CalculateHandler())
        
        // Regular middleware
        struct LoggingMiddleware: Middleware {
            let logs: Actor<[String]>
            let priority: ExecutionPriority = .logging
            
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
        
        _ = try await pipeline.execute(CalculateCommand(value: 5))
        
        let logEntries = await logs.get()
        XCTAssertEqual(logEntries.count, 1)
        XCTAssertEqual(logEntries[0], "Executing: CalculateCommand")
    }
    
    func testContextAwarePipelineBuilder() async throws {
        let builder = ContextAwarePipelineBuilder(handler: CalculateHandler())
        _ = await builder.with(AccumulatorMiddleware(name: "First"))
        _ = await builder.with(MultiplierMiddleware(multiplier: 3))
        _ = await builder.withMaxDepth(50)
        
        let pipeline = try await builder.build()
        
        let result = try await pipeline.execute(CalculateCommand(value: 4))
        
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
        
        let pipeline = ContextAwarePipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(authMiddleware)
        try await pipeline.addMiddleware(authzMiddleware)
        
        // Test with valid user
        let result = try await pipeline.execute(
            CalculateCommand(value: 10),
            metadata: DefaultCommandMetadata(userId: "user123")
        )
        XCTAssertEqual(result, 20)
        
        // Test with invalid user
        do {
            _ = try await pipeline.execute(
                CalculateCommand(value: 10),
                metadata: DefaultCommandMetadata(userId: "unknown")
            )
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertTrue(error is AuthorizationError)
        }
    }
    
    func testMetricsCollection() async throws {
        let metrics = Actor<[(String, TimeInterval)]>([])
        
        let metricsMiddleware = MetricsMiddleware { name, duration in
            await metrics.append((name, duration))
        }
        
        let pipeline = ContextAwarePipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(metricsMiddleware)
        
        _ = try await pipeline.execute(CalculateCommand(value: 5))
        
        let collectedMetrics = await metrics.get()
        XCTAssertEqual(collectedMetrics.count, 1)
        XCTAssertEqual(collectedMetrics[0].0, "CalculateCommand")
        XCTAssertTrue(collectedMetrics[0].1 >= 0)
    }
    
    func testContextInitialValues() async throws {
        struct ContextInspectorMiddleware: Middleware {
            let priority: ExecutionPriority = .normal
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
        let capturedData = Actor<(String?, Date?)>((nil, nil))
        
        let inspector = ContextInspectorMiddleware { context in
            let requestId = await context[RequestIDKey.self]
            let startTime = await context[RequestStartTimeKey.self]
            await capturedData.set((requestId, startTime))
            expectation.fulfill()
        }
        
        let pipeline = ContextAwarePipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(inspector)
        
        _ = try await pipeline.execute(CalculateCommand(value: 5))
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        let (capturedRequestId, capturedStartTime) = await capturedData.get()
        XCTAssertNotNil(capturedRequestId)
        XCTAssertNotNil(capturedStartTime)
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