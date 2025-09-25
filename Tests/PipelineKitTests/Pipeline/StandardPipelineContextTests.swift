import XCTest
@testable import PipelineKit
@testable import PipelineKitCore
import PipelineKitSecurity
import PipelineKitTestSupport

// Test context keys
private enum TestKeys {
    static let customValue = "custom_value"
    static let multiplier = "multiplier"
    static let accumulator = "accumulator"
}

final class StandardPipelineContextTests: XCTestCase {
    // Test command
    private struct CalculateCommand: Command {
        typealias Result = Int
        let value: Int
        
        func execute() async throws -> Int {
            return value * 2
        }
    }
    
    // Test handler
    private struct CalculateHandler: CommandHandler {
        typealias CommandType = CalculateCommand
        
        func handle(_ command: CalculateCommand) async throws -> Int {
            return command.value * 2
        }
    }
    
    // Context keys are now in TestKeys enum
    
    // Context-aware middleware that modifies result
    private struct MultiplierMiddleware: Middleware {
        let multiplier: Int
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            await context.setMetadata(TestKeys.multiplier, value: multiplier)
            
            let result = try await next(command, context)
            
            if let intResult = result as? Int,
               let multipliedResult = (intResult * multiplier) as? T.Result {
                return multipliedResult
            }
            
            return result
        }
    }
    
    // Middleware that accumulates execution info
    private struct AccumulatorMiddleware: Middleware {
        let name: String
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            let metadata = await context.getMetadata()
            var accumulator: [String] = (metadata[TestKeys.accumulator] as? [String]) ?? []
            accumulator.append("\(name):before")
            await context.setMetadata(TestKeys.accumulator, value: accumulator)
            
            let result = try await next(command, context)
            
            let metadata2 = await context.getMetadata()
            accumulator = (metadata2[TestKeys.accumulator] as? [String]) ?? []
            accumulator.append("\(name):after")
            await context.setMetadata(TestKeys.accumulator, value: accumulator)
            
            return result
        }
    }
    
    func testBasicStandardPipeline() async throws {
        let pipeline = StandardPipeline(handler: CalculateHandler())
        let context = CommandContext.test()
        
        let result = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        XCTAssertEqual(result, 10) // 5 * 2
    }
    
    func testContextSharing() async throws {
        let pipeline = StandardPipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(MultiplierMiddleware(multiplier: 3))
        
        let context = CommandContext.test()
        let result = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        XCTAssertEqual(result, 30) // (5 * 2) * 3
    }
    
    func testMultipleContextMiddleware() async throws {
        let pipeline = StandardPipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(AccumulatorMiddleware(name: "First"))
        try await pipeline.addMiddleware(AccumulatorMiddleware(name: "Second"))
        try await pipeline.addMiddleware(MultiplierMiddleware(multiplier: 2))
        
        let context = CommandContext.test()
        let result = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        XCTAssertEqual(result, 20) // (5 * 2) * 2
        
        // Check accumulator
        let metadata = await context.getMetadata()
        let accumulator: [String]? = (metadata[TestKeys.accumulator] as? [String])
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
        
        let context = CommandContext.test()
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
        let context = CommandContext.test()
        
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
                throw PipelineError.authentication(required: true)
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
        let validContext = CommandContext.test(userID: "user123")
        let result = try await pipeline.execute(
            CalculateCommand(value: 10),
            context: validContext
        )
        XCTAssertEqual(result, 20)
        
        // Test with invalid user
        let invalidContext = CommandContext.test(userID: "unknown")
        do {
            _ = try await pipeline.execute(
                CalculateCommand(value: 10),
                context: invalidContext
            )
            XCTFail("Expected authentication error")
        } catch {
            // Debug: Print actual error
            print("DEBUG: Actual error thrown: \(error)")
            print("DEBUG: Error type: \(type(of: error))")
            
            if let pipelineError = error as? PipelineError {
                switch pipelineError {
                case .authentication:
                    // This is what should actually be thrown for unknown user
                    break // Expected
                case .authorization:
                    XCTFail("Got authorization error when expecting authentication error")
                default:
                    XCTFail("Unexpected PipelineError: \(pipelineError)")
                }
            } else {
                XCTFail("Expected PipelineError but got: \(error)")
            }
        }
    }
    
    // MetricsMiddleware was removed during modularization
    /*
    func testMetricsCollection() async throws {
        let pipeline = StandardPipeline(handler: CalculateHandler())
        
        // Add simple metrics middleware
        let metricsMiddleware = MetricsMiddleware.simple { name, duration in
            print("Metric: \(name) took \(duration) seconds")
        }
        try await pipeline.addMiddleware(metricsMiddleware)
        
        let context = CommandContext.test()
        _ = try await pipeline.execute(CalculateCommand(value: 5), context: context)
        
        // Verify metrics were collected via context
        let metadata = await context.commandMetadata
        XCTAssertNotNil(metadata)
    }
    */
    
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
            let contextMetadata = await context.getMetadata()
            let requestId = (contextMetadata["request_id"] as? String)
            await capturedData.set((metadata.userID, requestId, metadata.timestamp))
            expectation.fulfill()
        }
        
        let pipeline = StandardPipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(inspector)
        
        let context = CommandContext.test(userID: "test-user-123")
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
                await context.setMetadata(TestKeys.customValue, value: value)
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
                let metadata = await context.getMetadata()
                let value = (metadata[TestKeys.customValue] as? String)
                XCTAssertEqual(value, expectedValue)
                return try await next(command, context)
            }
        }
        
        let pipeline = StandardPipeline(handler: CalculateHandler())
        try await pipeline.addMiddleware(ContextSetterMiddleware(value: "test-value"))
        try await pipeline.addMiddleware(ContextVerifierMiddleware(expectedValue: "test-value"))
        
        let context = CommandContext.test()
        let result = try await pipeline.execute(CalculateCommand(value: 7), context: context)
        
        XCTAssertEqual(result, 14)
        
        // Verify context persists after execution
        let metadata = await context.getMetadata()
        let finalValue = (metadata[TestKeys.customValue] as? String)
        XCTAssertEqual(finalValue, "test-value")
    }
}

// Helper actor for thread-safe test data collection
actor Actor <T: Sendable> {
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
