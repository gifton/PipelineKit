import XCTest
@testable import PipelineKit
@testable import PipelineKitTestSupport

final class ThreadSafeTestMiddlewareTests: XCTestCase {
    func testThreadSafeTestMiddlewareConcurrentAccess() async throws {
        let middleware = ThreadSafeTestMiddleware()
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
        XCTAssertEqual(middleware.executionCount, iterations)
        XCTAssertNotNil(middleware.lastCommand)
        XCTAssertNotNil(middleware.lastContext)
        
        // Test reset
        middleware.reset()
        XCTAssertEqual(middleware.executionCount, 0)
        XCTAssertNil(middleware.lastCommand)
        XCTAssertNil(middleware.lastContext)
    }
    
    func testThreadSafeHistoryMiddleware() async throws {
        let middleware = ThreadSafeHistoryMiddleware()
        let handler = MockCommandHandler()
        let pipeline = try await PipelineBuilder(handler: handler)
            .with([middleware])
            .build()
        
        let context = CommandContext.test()
        
        // Execute different commands
        let command1 = MockCommand(value: 1)
        let command2 = MockCommand(value: 2)
        let command3 = MockCommand(value: 3)
        
        _ = try await pipeline.execute(command1, context: context)
        _ = try await pipeline.execute(command2, context: context)
        _ = try await pipeline.execute(command3, context: context)
        
        // Verify history
        XCTAssertEqual(middleware.executionCount, 3)
        XCTAssertEqual(middleware.history.count, 3)
        
        // Check specific command types
        let mockCommands = middleware.commands(of: MockCommand.self)
        XCTAssertEqual(mockCommands.count, 3)
        
        // Verify execution check
        XCTAssertTrue(middleware.wasExecuted(MockCommand.self))
    }
    
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
    
    func testConcurrentHistoryOrdering() async throws {
        let middleware = ThreadSafeHistoryMiddleware()
        let handler = MockCommandHandler()
        let pipeline = try await PipelineBuilder(handler: handler)
            .with([middleware])
            .build()
        
        let context = CommandContext.test()
        
        // Execute commands to test ordering
        let commands = (0..<5).map { i in
            MockCommand(value: i)
        }
        
        // Execute concurrently
        await withTaskGroup(of: Void.self) { group in
            for (index, command) in commands.enumerated() {
                group.addTask {
                    // Add small delay to simulate timing differences
                    try? await Task.sleep(nanoseconds: UInt64((5 - index) * 10_000_000))
                    _ = try? await pipeline.execute(command, context: context)
                }
            }
        }
        
        // All should be recorded
        XCTAssertEqual(middleware.executionCount, 5)
        
        // Check timestamps are in order
        let history = middleware.history
        for i in 1..<history.count {
            XCTAssertGreaterThanOrEqual(
                history[i].timestamp.timeIntervalSince1970,
                history[i - 1].timestamp.timeIntervalSince1970
            )
        }
    }
    
    func testThreadSafeSnapshot() async throws {
        let middleware = ThreadSafeTestMiddleware()
        let handler = MockCommandHandler()
        let pipeline = try await PipelineBuilder(handler: handler)
            .with([middleware])
            .build()
        
        let context = CommandContext.test()
        let command = MockCommand(value: 1)
        
        _ = try await pipeline.execute(command, context: context)
        
        // Get atomic snapshot
        let snapshot = middleware.getSnapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertNotNil(snapshot.command)
        XCTAssertNotNil(snapshot.context)
        
        // Verify snapshot is consistent
        XCTAssertEqual(middleware.executionCount, snapshot.count)
    }
}
