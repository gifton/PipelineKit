import XCTest
@testable import PipelineKit

final class CommandContextPoolIntegrationTests: XCTestCase {
    
    // MARK: - Test Types
    
    struct TestCommand: Command {
        typealias Result = String
        let id: String
    }
    
    struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Handled: \(command.id)"
        }
    }
    
    struct TestKey: ContextKey {
        typealias Value = String
    }
    
    struct CounterKey: ContextKey {
        typealias Value = Int
    }
    
    // MARK: - Test Middleware
    
    final class ContextInspectingMiddleware: Middleware, @unchecked Sendable {
        let priority = ExecutionPriority.processing
        var lastSeenMetadata: CommandMetadata?
        var contextWasReused = false
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Store metadata for inspection
            lastSeenMetadata = context.commandMetadata
            
            // Check if context has residual data (would indicate reuse)
            if context[TestKey.self] == "previous-execution" {
                contextWasReused = true
            }
            
            // Set a marker
            context.set("current-execution", for: TestKey.self)
            
            return try await next(command, context)
        }
    }
    
    // MARK: - Pipeline with Pool Tests
    
    func testPipelineUsesContextPoolByDefault() async throws {
        // Given: A pipeline with default settings
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // When: Executing commands
        let command1 = TestCommand(id: "test1")
        let command2 = TestCommand(id: "test2")
        
        let result1 = try await pipeline.execute(command1)
        let result2 = try await pipeline.execute(command2)
        
        // Then: Commands execute successfully
        XCTAssertEqual(result1, "Handled: test1")
        XCTAssertEqual(result2, "Handled: test2")
        
        // Check pool statistics
        let stats = CommandContextPool.shared.getStatistics()
        XCTAssertGreaterThan(stats.totalBorrows, 0)
    }
    
    func testPipelineWithPoolDisabled() async throws {
        // Given: A pipeline with pooling disabled
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler, useContextPool: false)
        
        // When: Executing a command
        let command = TestCommand(id: "test")
        let result = try await pipeline.execute(command)
        
        // Then: Command executes successfully without pooling
        XCTAssertEqual(result, "Handled: test")
    }
    
    func testPipelineBuilderWithContextPool() async throws {
        // Given: A builder with context pool configuration
        let handler = TestHandler()
        let inspectingMiddleware = ContextInspectingMiddleware()
        
        let pipeline = try await PipelineBuilder(handler: handler)
            .with(inspectingMiddleware)
            .withContextPool(true)
            .build()
        
        // When: Executing multiple commands
        let commands = (0..<5).map { TestCommand(id: "test-\($0)") }
        
        for command in commands {
            _ = try await pipeline.execute(command)
        }
        
        // Then: Context pool is used
        let stats = CommandContextPool.shared.getStatistics()
        XCTAssertGreaterThan(stats.hitRate, 0, "Pool should have hits after multiple executions")
    }
    
    func testContextPoolWithMetadata() async throws {
        // Given: A pipeline with custom metadata
        let handler = TestHandler()
        let middleware = ContextInspectingMiddleware()
        
        let pipeline = try await PipelineBuilder(handler: handler)
            .with(middleware)
            .build()
        
        // When: Executing with custom metadata
        let metadata = StandardCommandMetadata(
            userId: "user123",
            correlationId: "trace-456"
        )
        
        let command = TestCommand(id: "test")
        _ = try await pipeline.execute(command, metadata: metadata)
        
        // Then: Metadata is correctly set
        XCTAssertEqual(middleware.lastSeenMetadata?.userId, "user123")
        XCTAssertEqual(middleware.lastSeenMetadata?.correlationId, "trace-456")
    }
    
    func testContextIsolationWithPooling() async throws {
        // Given: A pipeline that modifies context
        final class ContextModifyingMiddleware: Middleware, @unchecked Sendable {
            let priority = ExecutionPriority.processing
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // Increment a counter
                let current = context[CounterKey.self] ?? 0
                context.set(current + 1, for: CounterKey.self)
                
                return try await next(command, context)
            }
        }
        
        let handler = TestHandler()
        let pipeline = try await PipelineBuilder(handler: handler)
            .with(ContextModifyingMiddleware())
            .build()
        
        // When: Executing multiple commands
        let results = await withTaskGroup(of: (String, Int?).self) { group in
            for i in 0..<10 {
                group.addTask {
                    let command = TestCommand(id: "test-\(i)")
                    let result = try! await pipeline.execute(command)
                    
                    // Try to access the context (shouldn't be possible after execution)
                    return (result, nil)
                }
            }
            
            var results: [(String, Int?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        // Then: All executions succeed
        XCTAssertEqual(results.count, 10)
        for (result, _) in results {
            XCTAssertTrue(result.starts(with: "Handled: test-"))
        }
    }
    
    func testContextPoolPerformance() async throws {
        // Given: Two pipelines - one with pooling, one without
        let handler = TestHandler()
        let pooledPipeline = StandardPipeline(handler: handler, useContextPool: true)
        let unpooledPipeline = StandardPipeline(handler: handler, useContextPool: false)
        
        let iterations = 1000
        let command = TestCommand(id: "perf-test")
        
        // When: Measuring performance with pooling
        let pooledStart = Date()
        for _ in 0..<iterations {
            _ = try await pooledPipeline.execute(command)
        }
        let pooledDuration = Date().timeIntervalSince(pooledStart)
        
        // When: Measuring performance without pooling
        let unpooledStart = Date()
        for _ in 0..<iterations {
            _ = try await unpooledPipeline.execute(command)
        }
        let unpooledDuration = Date().timeIntervalSince(unpooledStart)
        
        // Then: Pooled version should be faster (or at least not significantly slower)
        print("Pooled duration: \(pooledDuration)s")
        print("Unpooled duration: \(unpooledDuration)s")
        print("Performance improvement: \(String(format: "%.1f", (unpooledDuration / pooledDuration - 1) * 100))%")
        
        // Pool statistics
        let stats = CommandContextPool.shared.getStatistics()
        print("Pool hit rate: \(String(format: "%.1f", stats.hitRate * 100))%")
        
        // We don't assert on performance as it can vary, but we log it
    }
    
    func testMixedExecutionMethods() async throws {
        // Given: A pipeline
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // When: Using different execution methods
        let command = TestCommand(id: "mixed")
        
        // Execute with explicit context
        let explicitContext = CommandContext()
        explicitContext.set("explicit", for: TestKey.self)
        let result1 = try await pipeline.execute(command, context: explicitContext)
        
        // Execute with metadata (uses pool)
        let metadata = StandardCommandMetadata(userId: "user456")
        let result2 = try await pipeline.execute(command, metadata: metadata)
        
        // Execute without parameters (uses pool with default metadata)
        let result3 = try await pipeline.execute(command)
        
        // Then: All methods work correctly
        XCTAssertEqual(result1, "Handled: mixed")
        XCTAssertEqual(result2, "Handled: mixed")
        XCTAssertEqual(result3, "Handled: mixed")
        
        // Verify the explicit context retained its value
        XCTAssertEqual(explicitContext[TestKey.self], "explicit")
    }
    
    // MARK: - Pool Management Tests
    
    func testContextPoolClearing() async throws {
        // Given: A pipeline that has used the pool
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Execute some commands to populate the pool
        for i in 0..<5 {
            _ = try await pipeline.execute(TestCommand(id: "test-\(i)"))
        }
        
        // When: Clearing the pool
        CommandContextPool.shared.clear()
        
        // Then: Pool is empty
        let stats = CommandContextPool.shared.getStatistics()
        XCTAssertEqual(stats.currentlyAvailable, 0)
        XCTAssertEqual(stats.currentlyInUse, 0)
        
        // But pipeline still works
        let result = try await pipeline.execute(TestCommand(id: "after-clear"))
        XCTAssertEqual(result, "Handled: after-clear")
    }
}