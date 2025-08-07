import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class MiddlewareChainOptimizerTests: XCTestCase {
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let id: String
    }
    
    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Handled: \(command.id)"
        }
    }
    
    // MARK: - Test Middleware
    
    private final class ValidationMiddleware: Middleware, @unchecked Sendable {
        let priority = ExecutionPriority.validation
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Validation logic
            return try await next(command, context)
        }
    }
    
    private final class LoggingMiddleware: Middleware, @unchecked Sendable {
        let priority = ExecutionPriority.postProcessing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Logging logic
            return try await next(command, context)
        }
    }
    
    private final class TestMetricsMiddleware: Middleware, @unchecked Sendable {
        let priority = ExecutionPriority.postProcessing // Restored to postProcessing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Metrics logic
            return try await next(command, context)
        }
    }
    
    private final class ProcessingMiddleware: Middleware, @unchecked Sendable {
        let priority = ExecutionPriority.processing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Processing logic
            return try await next(command, context)
        }
    }
    
    // MARK: - Optimizer Tests
    
    func testOptimizerAnalyzesChain() async {
        // Given
        let optimizer = MiddlewareChainOptimizer()
        let middlewares: [any Middleware] = [
            ValidationMiddleware(),
            LoggingMiddleware(),
            TestMetricsMiddleware()
        ]
        
        // When
        let optimizedChain = await optimizer.optimize(
            middleware: middlewares,
            handler: TestHandler()
        )
        
        // Then
        XCTAssertEqual(optimizedChain.metadata.count, 3)
        XCTAssertTrue(optimizedChain.metadata.canThrow)
        XCTAssertGreaterThan(optimizedChain.metadata.contextReaders, 0)
    }
    
    func testOptimizerIdentifiesParallelGroups() async {
        // Given
        let optimizer = MiddlewareChainOptimizer()
        let middlewares: [any Middleware] = [
            ValidationMiddleware(),
            LoggingMiddleware(), // Both are postProcessing priority
            TestMetricsMiddleware()  // These could run in parallel
        ]
        
        // When
        let optimizedChain = await optimizer.optimize(
            middleware: middlewares,
            handler: TestHandler()
        )
        
        // Then
        if case .partiallyParallel(let groups) = optimizedChain.strategy {
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups[0].middleware.count, 2)
        } else {
            XCTFail("Expected partially parallel strategy")
        }
    }
    
    func testOptimizerWithEmptyChain() async {
        // Given
        let optimizer = MiddlewareChainOptimizer()
        let middlewares: [any Middleware] = []
        
        // When
        let optimizedChain = await optimizer.optimize(
            middleware: middlewares,
            handler: TestHandler()
        )
        
        // Then
        XCTAssertEqual(optimizedChain.metadata.count, 0)
        if case .sequential = optimizedChain.strategy {
            // Expected
        } else {
            XCTFail("Expected sequential strategy for empty chain")
        }
    }
    
    // MARK: - Pipeline Builder Integration Tests
    
    func testPipelineBuilderWithOptimization() async throws {
        // Given
        let handler = TestHandler()
        let builder = PipelineBuilder(handler: handler)
        
        // When
        let pipeline = try await builder
            .with(ValidationMiddleware())
            .with(LoggingMiddleware())
            .with(TestMetricsMiddleware())
            .withOptimization()
            .build()
        
        // Then: Pipeline should have optimization metadata
        let optimizationMetadata = await pipeline.optimizationMetadata
        XCTAssertNotNil(optimizationMetadata)
        
        XCTAssertEqual(optimizationMetadata?.metadata.count, 3)
    }
    
    func testPipelineExecutionWithOptimization() async throws {
        // Given
        let handler = TestHandler()
        let builder = PipelineBuilder(handler: handler)
        
        let pipeline = try await builder
            .with(ValidationMiddleware())
            .with(LoggingMiddleware())
            .withOptimization()
            .build()
        
        // When
        let command = TestCommand(id: "test-123")
        let context = CommandContext()
        let result = try await pipeline.execute(command, context: context)
        
        // Then
        XCTAssertEqual(result, "Handled: test-123")
    }
    
    func testOptimizerStrategies() async {
        let optimizer = MiddlewareChainOptimizer()
        
        // Test 1: Validation-heavy chain
        let validationMiddlewares: [any Middleware] = [
            ValidationMiddleware(),
            ValidationMiddleware(),
            ValidationMiddleware(),
            LoggingMiddleware()
        ]
        
        let validationChain = await optimizer.optimize(
            middleware: validationMiddlewares,
            handler: TestHandler()
        )
        
        if case .failFast(let validators) = validationChain.strategy {
            XCTAssertEqual(validators.count, 3)
        } else {
            XCTFail("Expected fail-fast strategy for validation-heavy chain")
        }
        
        // Test 2: All parallel middleware
        let parallelMiddlewares: [any Middleware] = [
            LoggingMiddleware(),
            TestMetricsMiddleware()
        ]
        
        let parallelChain = await optimizer.optimize(
            middleware: parallelMiddlewares,
            handler: TestHandler()
        )
        
        if case .fullyParallel = parallelChain.strategy {
            // Expected
        } else if case .partiallyParallel = parallelChain.strategy {
            // Also acceptable
        } else {
            XCTFail("Expected parallel strategy")
        }
    }
    
    func testFastPathExecutorCreation() async {
        let optimizer = MiddlewareChainOptimizer()
        
        // Test 1: Empty chain - should create FastPathExecutor
        let emptyChain = await optimizer.optimize(
            middleware: [],
            handler: TestHandler()
        )
        XCTAssertTrue(emptyChain.hasFastPath, "FastPath should be available for empty chain")
        
        // Test 2: Single middleware - should create FastPathExecutor
        let singleChain = await optimizer.optimize(
            middleware: [ValidationMiddleware()],
            handler: TestHandler()
        )
        XCTAssertTrue(singleChain.hasFastPath, "FastPath should be available for single middleware")
        
        // Test 3: Two middleware - should create FastPathExecutor
        let twoChain = await optimizer.optimize(
            middleware: [ValidationMiddleware(), LoggingMiddleware()],
            handler: TestHandler()
        )
        XCTAssertTrue(twoChain.hasFastPath, "FastPath should be available for two middleware")
        
        // Test 4: Three middleware - should create FastPathExecutor
        let threeChain = await optimizer.optimize(
            middleware: [ValidationMiddleware(), ProcessingMiddleware(), LoggingMiddleware()],
            handler: TestHandler()
        )
        XCTAssertTrue(threeChain.hasFastPath, "FastPath should be available for three middleware")
        
        // Test 5: Four middleware - should NOT create FastPathExecutor
        let fourChain = await optimizer.optimize(
            middleware: [
                ValidationMiddleware(),
                LoggingMiddleware(),
                TestMetricsMiddleware(),
                ValidationMiddleware()
            ],
            handler: TestHandler()
        )
        XCTAssertFalse(fourChain.hasFastPath, "FastPath should NOT be available for more than 3 middleware")
    }
}
