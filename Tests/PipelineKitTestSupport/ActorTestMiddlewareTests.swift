import XCTest
@testable import PipelineKit
@testable import PipelineKitTestSupport

final class ActorTestMiddlewareTests: XCTestCase {
    func testActorTestMiddlewareConcurrentAccess() async throws {
        let middleware = ActorTestMiddleware()
        let handler = MockCommandHandler()
        let pipeline = try await PipelineBuilder(handler: handler)
            .with([middleware])
            .build()
        
        let iterations = 100
        let context = CommandContext.test()
        
        // Concurrent executions
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let command = MockCommand(value: i)
                    _ = try? await pipeline.execute(command, context: context)
                }
            }
        }
        
        // Verify execution count
        let count = await middleware.getExecutionCount()
        XCTAssertEqual(count, iterations)
        
        let lastCommand = await middleware.getLastCommand()
        XCTAssertNotNil(lastCommand)
        
        let lastContext = await middleware.getLastContext()
        XCTAssertNotNil(lastContext)
        
        // Test reset
        await middleware.reset()
        let countAfterReset = await middleware.getExecutionCount()
        XCTAssertEqual(countAfterReset, 0)
        
        let commandAfterReset = await middleware.getLastCommand()
        XCTAssertNil(commandAfterReset)
        
        let contextAfterReset = await middleware.getLastContext()
        XCTAssertNil(contextAfterReset)
    }
    
    // Removed testThreadSafeHistoryMiddleware - functionality not available in ActorTestMiddleware
    // Consider implementing a separate ActorHistoryMiddleware if history tracking is needed
    
    func testActorTestMiddleware() async throws {
        let middleware = ActorTestMiddleware()
        let handler = MockCommandHandler()
        let pipeline = try await PipelineBuilder(handler: handler)
            .with([middleware])
            .build()
        
        let context = CommandContext.test()
        let command = MockCommand(value: 1)
        
        // Execute command
        _ = try await pipeline.execute(command, context: context)
        
        // Access state through actor
        let count = await middleware.getExecutionCount()
        XCTAssertEqual(count, 1)
        
        let lastCommand = await middleware.getLastCommand()
        XCTAssertNotNil(lastCommand)
        XCTAssertTrue(lastCommand is MockCommand)
        
        let lastContext = await middleware.getLastContext()
        XCTAssertNotNil(lastContext)
        
        // Test reset
        await middleware.reset()
        let countAfterReset = await middleware.getExecutionCount()
        XCTAssertEqual(countAfterReset, 0)
    }
    
    // Removed testConcurrentHistoryOrdering - functionality not available in ActorTestMiddleware
    // Consider implementing a separate ActorHistoryMiddleware if history tracking is needed
    
    // Removed testThreadSafeSnapshot - functionality not available in ActorTestMiddleware
    // The ActorTestMiddleware provides thread-safe access through individual async methods
}
