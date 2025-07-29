import XCTest
@testable import PipelineKit

final class FastPathExecutorV2BenchmarkTests: XCTestCase {
    
    // MARK: - Test Infrastructure
    
    struct BenchmarkCommand: Command {
        typealias Result = String
        let id: String
        let payload: String
        
        init(id: String = UUID().uuidString, payload: String = "test") {
            self.id = id
            self.payload = payload
        }
    }
    
    struct BenchmarkHandler: CommandHandler {
        typealias CommandType = BenchmarkCommand
        
        func handle(_ command: BenchmarkCommand) async throws -> String {
            // Simulate minimal work
            return "\(command.id):\(command.payload)"
        }
    }
    
    struct LightweightMiddleware: Middleware {
        let name: String
        let priority: ExecutionPriority = .custom
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Minimal work - just pass through
            context.set(name, for: StringKey.self)
            return try await next(command, context)
        }
    }
    
    struct ProcessingMiddleware: Middleware {
        let name: String
        let priority: ExecutionPriority = .processing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Simulate some processing
            context.set("\(name)-processed", for: StringKey.self)
            let result = try await next(command, context)
            context.set("\(name)-complete", for: ProcessedKey.self)
            return result
        }
    }
    
    // Context Keys
    private struct StringKey: ContextKey {
        typealias Value = String
    }
    
    private struct ProcessedKey: ContextKey {
        typealias Value = String
    }
    
    // MARK: - Benchmark Tests
    
    func testDirectExecutionComparison() async throws {
        let handler = BenchmarkHandler()
        let optimizer = MiddlewareChainOptimizer()
        
        // Setup type-erased version
        let optimizedChain = await optimizer.optimize(
            middleware: [],
            handler: handler
        )
        
        XCTAssertNotNil(optimizedChain.fastPathExecutor, "Should have fast path for empty chain")
        
        // Setup type-safe version
        let typeSafeExecutor = FastPathExecutorFactory.createDirectExecutor(for: BenchmarkCommand.self)
        
        // Measure type-erased version
        let typeErasedTime = await measure(iterations: 10000) {
            let command = BenchmarkCommand()
            let context = CommandContext()
            if let fastPath = optimizedChain.fastPathExecutor {
                _ = try? await fastPath.execute(command, context: context) { cmd in
                    try await handler.handle(cmd)
                }
            }
        }
        
        // Measure type-safe version
        let typeSafeTime = await measure(iterations: 10000) {
            let command = BenchmarkCommand()
            let context = CommandContext()
            _ = try? await typeSafeExecutor.execute(command, context: context) { cmd in
                try await handler.handle(cmd)
            }
        }
        
        let improvement = ((typeErasedTime - typeSafeTime) / typeErasedTime) * 100
        print("Direct execution - Type-safe improvement over type-erased: \(String(format: "%.1f", improvement))%")
        
        // Type-safe should be faster
        XCTAssertLessThan(typeSafeTime, typeErasedTime, "Type-safe should be faster than type-erased")
    }
    
    func testSingleMiddlewareComparison() async throws {
        let handler = BenchmarkHandler()
        let optimizer = MiddlewareChainOptimizer()
        let middleware = LightweightMiddleware(name: "MW1")
        
        // Setup type-erased version
        let optimizedChain = await optimizer.optimize(
            middleware: [middleware],
            handler: handler
        )
        
        XCTAssertNotNil(optimizedChain.fastPathExecutor, "Should have fast path for single middleware")
        
        // Setup type-safe version
        let typeSafeExecutor = FastPathExecutorFactory.createSingleExecutor(
            for: BenchmarkCommand.self,
            middleware: middleware
        )
        
        // Measure type-erased version
        let typeErasedTime = await measure(iterations: 10000) {
            let command = BenchmarkCommand()
            let context = CommandContext()
            if let fastPath = optimizedChain.fastPathExecutor {
                _ = try? await fastPath.execute(command, context: context) { cmd in
                    try await handler.handle(cmd)
                }
            }
        }
        
        // Measure type-safe version
        let typeSafeTime = await measure(iterations: 10000) {
            let command = BenchmarkCommand()
            let context = CommandContext()
            _ = try? await typeSafeExecutor.execute(command, context: context) { cmd in
                try await handler.handle(cmd)
            }
        }
        
        let improvement = ((typeErasedTime - typeSafeTime) / typeErasedTime) * 100
        print("Single middleware - Type-safe improvement over type-erased: \(String(format: "%.1f", improvement))%")
        
        // Type-safe should be faster
        XCTAssertLessThan(typeSafeTime, typeErasedTime, "Type-safe should be faster than type-erased")
    }
    
    func testTripleMiddlewareComparison() async throws {
        let handler = BenchmarkHandler()
        let optimizer = MiddlewareChainOptimizer()
        let mw1 = LightweightMiddleware(name: "MW1")
        let mw2 = ProcessingMiddleware(name: "MW2")
        let mw3 = LightweightMiddleware(name: "MW3")
        
        // Setup type-erased version
        let optimizedChain = await optimizer.optimize(
            middleware: [mw1, mw2, mw3],
            handler: handler
        )
        
        XCTAssertNotNil(optimizedChain.fastPathExecutor, "Should have fast path for triple middleware")
        
        // Setup type-safe version
        let typeSafeExecutor = FastPathExecutorFactory.createTripleExecutor(
            for: BenchmarkCommand.self,
            middleware1: mw1,
            middleware2: mw2,
            middleware3: mw3
        )
        
        // Measure type-erased version
        let typeErasedTime = await measure(iterations: 10000) {
            let command = BenchmarkCommand()
            let context = CommandContext()
            if let fastPath = optimizedChain.fastPathExecutor {
                _ = try? await fastPath.execute(command, context: context) { cmd in
                    try await handler.handle(cmd)
                }
            }
        }
        
        // Measure type-safe version
        let typeSafeTime = await measure(iterations: 10000) {
            let command = BenchmarkCommand()
            let context = CommandContext()
            _ = try? await typeSafeExecutor.execute(command, context: context) { cmd in
                try await handler.handle(cmd)
            }
        }
        
        let improvement = ((typeErasedTime - typeSafeTime) / typeErasedTime) * 100
        print("Triple middleware - Type-safe improvement over type-erased: \(String(format: "%.1f", improvement))%")
        
        // Type-safe should be faster
        XCTAssertLessThan(typeSafeTime, typeErasedTime, "Type-safe should be faster than type-erased")
    }
    
    func testOverallPerformanceGain() async throws {
        // Test to validate that removing type erasure provides expected ~17% improvement
        let handler = BenchmarkHandler()
        let optimizer = MiddlewareChainOptimizer()
        let iterations = 50000
        
        // Current type-erased implementation
        let optimizedChain = await optimizer.optimize(
            middleware: [],
            handler: handler
        )
        
        let typeErasedTime = await measure(iterations: iterations) {
            let command = BenchmarkCommand()
            let context = CommandContext()
            if let fastPath = optimizedChain.fastPathExecutor {
                _ = try? await fastPath.execute(command, context: context) { cmd in
                    try await handler.handle(cmd)
                }
            }
        }
        
        // Type-safe executor
        let executor = FastPathExecutorFactory.createDirectExecutor(for: BenchmarkCommand.self)
        let typeSafeTime = await measure(iterations: iterations) {
            let command = BenchmarkCommand()
            let context = CommandContext()
            _ = try? await executor.execute(command, context: context) { cmd in
                try await handler.handle(cmd)
            }
        }
        
        // Standard pipeline (no optimization)
        let standardPipeline = StandardPipeline(handler: handler)
        let standardTime = await measure(iterations: iterations) {
            let command = BenchmarkCommand()
            let context = CommandContext()
            _ = try? await standardPipeline.execute(command, context: context)
        }
        
        let typeErasedImprovement = ((standardTime - typeErasedTime) / standardTime) * 100
        let typeSafeImprovement = ((standardTime - typeSafeTime) / standardTime) * 100
        let typeErasurePenalty = ((typeErasedTime - typeSafeTime) / typeSafeTime) * 100
        
        print("\nPerformance Summary:")
        print("Standard pipeline: \(String(format: "%.3f", standardTime))s")
        print("Type-erased fast path: \(String(format: "%.3f", typeErasedTime))s (%.1f%% improvement)")
        print("Type-safe fast path: \(String(format: "%.3f", typeSafeTime))s (%.1f%% improvement)")
        print("Type erasure penalty: \(String(format: "%.1f", typeErasurePenalty))%")
        
        // Type-safe should be significantly faster than standard
        XCTAssertGreaterThan(typeSafeImprovement, 30.0, "Type-safe fast path should provide >30% improvement")
        // Type-safe should be faster than type-erased
        XCTAssertLessThan(typeSafeTime, typeErasedTime, "Type-safe should be faster than type-erased")
    }
    
    // MARK: - Helper Methods
    
    private func measure(iterations: Int = 1000, _ block: () async throws -> Void) async -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            try? await block()
        }
        return CFAbsoluteTimeGetCurrent() - start
    }
}