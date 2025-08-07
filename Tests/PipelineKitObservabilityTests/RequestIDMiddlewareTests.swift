import XCTest
import PipelineKitCore
@testable import PipelineKitObservability

final class RequestIDMiddlewareTests: XCTestCase {
    
    // MARK: - Test Commands
    
    struct TestCommand: Command {
        typealias Result = String
        let name: String
        
        func execute() async throws -> String {
            "Executed: \(name)"
        }
    }
    
    struct NestedCommand: Command {
        typealias Result = String
        let pipeline: Pipeline
        
        func execute() async throws -> String {
            // Execute another command through nested pipeline
            let innerCommand = TestCommand(name: "inner")
            _ = try await pipeline.execute(innerCommand)
            return "Nested execution complete"
        }
    }
    
    // MARK: - Tests
    
    func testAutomaticRequestIDGeneration() async throws {
        // Given
        let middleware = RequestIDMiddleware()
        let command = TestCommand(name: "test")
        let context = CommandContext()
        
        // Verify no request ID initially
        XCTAssertNil(context.requestID)
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            // Then - request ID should be set during execution
            XCTAssertNotNil(ctx.requestID)
            XCTAssertFalse(ctx.requestID!.isEmpty)
            return try await cmd.execute()
        }
        
        // Request ID should persist after execution
        XCTAssertNotNil(context.requestID)
    }
    
    func testExistingRequestIDPreservation() async throws {
        // Given
        let existingID = "existing-request-123"
        let middleware = RequestIDMiddleware()
        let command = TestCommand(name: "test")
        let context = CommandContext()
        context.requestID = existingID
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            // Then - existing ID should be preserved
            XCTAssertEqual(ctx.requestID, existingID)
            return try await cmd.execute()
        }
        
        // Should still have the same ID
        XCTAssertEqual(context.requestID, existingID)
    }
    
    func testCustomIDGenerator() async throws {
        // Given
        var generatorCallCount = 0
        let customID = "custom-id-456"
        
        let middleware = RequestIDMiddleware(
            configuration: RequestIDMiddleware.Configuration(
                generator: {
                    generatorCallCount += 1
                    return customID
                }
            )
        )
        
        let command = TestCommand(name: "test")
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertEqual(context.requestID, customID)
        XCTAssertEqual(generatorCallCount, 1)
    }
    
    func testHeaderExtraction() async throws {
        // Given
        let headerID = "header-request-789"
        let middleware = RequestIDMiddleware(
            configuration: RequestIDMiddleware.Configuration(
                headerName: "X-Request-ID"
            )
        )
        
        let command = TestCommand(name: "test")
        let context = CommandContext()
        context.metadata["headers"] = ["X-Request-ID": headerID]
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            // Then - should extract from header
            XCTAssertEqual(ctx.requestID, headerID)
            return try await cmd.execute()
        }
        
        XCTAssertEqual(context.requestID, headerID)
    }
    
    func testFallbackToGeneratorWhenHeaderMissing() async throws {
        // Given
        let middleware = RequestIDMiddleware(
            configuration: RequestIDMiddleware.Configuration(
                headerName: "X-Request-ID",
                generator: { "fallback-id" }
            )
        )
        
        let command = TestCommand(name: "test")
        let context = CommandContext()
        // No headers set
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then - should use generator
        XCTAssertEqual(context.requestID, "fallback-id")
    }
    
    func testPropagateToResponse() async throws {
        // Given
        let requestID = "response-test-123"
        let middleware = RequestIDMiddleware(
            configuration: RequestIDMiddleware.Configuration(
                propagateToResponse: true,
                responseHeaderName: "X-Response-ID"
            )
        )
        
        let command = TestCommand(name: "test")
        let context = CommandContext()
        context.requestID = requestID
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then - should add to response headers
        let responseHeaders = context.metadata["responseHeaders"] as? [String: String]
        XCTAssertEqual(responseHeaders?["X-Response-ID"], requestID)
    }
    
    func testLoggingIntegration() async throws {
        // Given
        var loggedRequestID: String?
        
        let middleware = RequestIDMiddleware(
            configuration: RequestIDMiddleware.Configuration(
                logRequestID: true,
                logger: { id in
                    loggedRequestID = id
                }
            )
        )
        
        let command = TestCommand(name: "test")
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertNotNil(loggedRequestID)
        XCTAssertEqual(loggedRequestID, context.requestID)
    }
    
    func testIDFormat() async throws {
        // Given
        let middleware = RequestIDMiddleware()
        let command = TestCommand(name: "test")
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then - verify UUID format
        let requestID = context.requestID!
        XCTAssertTrue(requestID.count == 36) // UUID with hyphens
        XCTAssertTrue(requestID.contains("-"))
        
        // Should be valid UUID
        XCTAssertNotNil(UUID(uuidString: requestID))
    }
    
    func testConcurrentRequests() async throws {
        // Given
        let middleware = RequestIDMiddleware()
        let requestCount = 100
        
        // When - execute many requests concurrently
        let requestIDs = await withTaskGroup(of: String?.self) { group in
            for i in 0..<requestCount {
                group.addTask {
                    let command = TestCommand(name: "test-\(i)")
                    let context = CommandContext()
                    
                    _ = try? await middleware.execute(command, context: context) { cmd, _ in
                        try await cmd.execute()
                    }
                    
                    return context.requestID
                }
            }
            
            var ids: [String] = []
            for await id in group {
                if let id = id {
                    ids.append(id)
                }
            }
            return ids
        }
        
        // Then - all IDs should be unique
        XCTAssertEqual(requestIDs.count, requestCount)
        XCTAssertEqual(Set(requestIDs).count, requestCount)
    }
    
    func testNestedPipelineIDPropagation() async throws {
        // Given
        let outerMiddleware = RequestIDMiddleware()
        let innerMiddleware = RequestIDMiddleware()
        
        let innerPipeline = StandardPipeline()
        innerPipeline.use(innerMiddleware)
        
        let command = NestedCommand(pipeline: innerPipeline)
        let context = CommandContext()
        
        var outerRequestID: String?
        var innerRequestID: String?
        
        // When
        _ = try await outerMiddleware.execute(command, context: context) { cmd, ctx in
            outerRequestID = ctx.requestID
            
            // Set up inner middleware to capture ID
            innerPipeline.use { innerCmd, innerCtx, next in
                innerRequestID = innerCtx.requestID
                return try await next(innerCmd, innerCtx)
            }
            
            return try await cmd.execute()
        }
        
        // Then - both should have the same request ID
        XCTAssertNotNil(outerRequestID)
        XCTAssertNotNil(innerRequestID)
        XCTAssertEqual(outerRequestID, innerRequestID)
    }
    
    func testCustomPrefix() async throws {
        // Given
        let middleware = RequestIDMiddleware(
            configuration: RequestIDMiddleware.Configuration(
                generator: {
                    "req-\(UUID().uuidString.lowercased())"
                }
            )
        )
        
        let command = TestCommand(name: "test")
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertTrue(context.requestID!.hasPrefix("req-"))
    }
    
    func testMetadataStorage() async throws {
        // Given
        let middleware = RequestIDMiddleware(
            configuration: RequestIDMiddleware.Configuration(
                storeInMetadata: true,
                metadataKey: "request_id"
            )
        )
        
        let command = TestCommand(name: "test")
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            // Should be in both places during execution
            XCTAssertEqual(ctx.requestID, ctx.metadata["request_id"] as? String)
            return try await cmd.execute()
        }
        
        // Then - should be stored in metadata
        XCTAssertEqual(context.requestID, context.metadata["request_id"] as? String)
    }
}

// MARK: - Helper Types

struct StandardPipeline: Pipeline {
    private var middlewares: [any Middleware] = []
    
    mutating func use(_ middleware: any Middleware) {
        middlewares.append(middleware)
    }
    
    mutating func use(_ closure: @escaping MiddlewareClosure) {
        // Simple closure middleware wrapper
        struct ClosureMiddleware: Middleware {
            let closure: MiddlewareClosure
            let priority: ExecutionPriority = .normal
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                try await closure(command, context, next)
            }
        }
        
        middlewares.append(ClosureMiddleware(closure: closure))
    }
    
    func execute<T: Command>(_ command: T) async throws -> T.Result {
        let context = CommandContext()
        
        // Build middleware chain
        var next: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, _ in
            try await cmd.execute()
        }
        
        for middleware in middlewares.reversed() {
            let currentNext = next
            next = { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: currentNext)
            }
        }
        
        return try await next(command, context)
    }
}

typealias MiddlewareClosure = @Sendable (any Command, CommandContext, @Sendable (any Command, CommandContext) async throws -> Any) async throws -> Any