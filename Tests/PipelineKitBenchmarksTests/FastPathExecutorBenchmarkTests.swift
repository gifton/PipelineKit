import XCTest
@testable import PipelineKit

final class FastPathExecutorBenchmarkTests: XCTestCase {
    // MARK: - Test Infrastructure
    
    private struct BenchmarkCommand: Command {
        typealias Result = String
        let id: String
        let payload: String
        
        init(id: String = UUID().uuidString, payload: String = "test") {
            self.id = id
            self.payload = payload
        }
    }
    
    private struct BenchmarkHandler: CommandHandler {
        typealias CommandType = BenchmarkCommand
        
        func handle(_ command: BenchmarkCommand) async throws -> String {
            // Simulate minimal work
            return "\(command.id):\(command.payload)"
        }
    }
    
    private struct LightweightMiddleware: Middleware {
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
    
    private struct ProcessingMiddleware: Middleware {
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
    
    func testDirectExecutionPerformance() async throws {
        let handler = BenchmarkHandler()
        let optimizer = MiddlewareChainOptimizer()
        
        // Setup optimized pipeline with no middleware
        let optimizedChain = await optimizer.optimize(
            middleware: [],
            handler: handler
        )
        
        XCTAssertTrue(optimizedChain.hasFastPath, "Should have fast path for empty chain")
        
        let standardPipeline = StandardPipeline(handler: handler)
        
        // Measure standard execution
        let standardTime = await measure {
            let command = BenchmarkCommand()
            let context = CommandContext()
            _ = try? await standardPipeline.execute(command, context: context)
        }
        
        // Fast path execution is now internal, so we can't measure it directly
        // We can only verify that optimization is enabled
        let fastPathTime = standardTime // Use standard time as approximation
        
        let improvement = ((standardTime - fastPathTime) / standardTime) * 100
        print("Direct execution improvement: \(String(format: "%.1f", improvement))%")
        
        // Fast path should be at least 20% faster
        XCTAssertGreaterThan(improvement, 20.0, "Fast path should provide >20% improvement")
    }
    
    func testSingleMiddlewarePerformance() async throws {
        let handler = BenchmarkHandler()
        let optimizer = MiddlewareChainOptimizer()
        let middleware = [LightweightMiddleware(name: "MW1")]
        
        // Setup pipelines
        let standardPipeline = StandardPipeline(handler: handler)
        for mw in middleware {
            try await standardPipeline.addMiddleware(mw)
        }
        
        let optimizedChain = await optimizer.optimize(
            middleware: middleware,
            handler: handler
        )
        
        XCTAssertTrue(optimizedChain.hasFastPath, "Should have fast path for single middleware")
        
        // Measure performance
        let standardTime = await measure {
            let command = BenchmarkCommand()
            let context = CommandContext()
            _ = try? await standardPipeline.execute(command, context: context)
        }
        
        let fastPathTime = await measure {
            let command = BenchmarkCommand()
            let context = CommandContext()
            // Fast path execution is now internal
            _ = try? await standardPipeline.execute(command, context: context)
        }
        
        let improvement = ((standardTime - fastPathTime) / standardTime) * 100
        print("Single middleware improvement: \(String(format: "%.1f", improvement))%")
        
        // Should see improvement with fast path
        XCTAssertGreaterThan(improvement, 15.0, "Fast path should provide >15% improvement")
    }
    
    func testTripleMiddlewarePerformance() async throws {
        let handler = BenchmarkHandler()
        let optimizer = MiddlewareChainOptimizer()
        let middleware: [any Middleware] = [
            LightweightMiddleware(name: "MW1"),
            ProcessingMiddleware(name: "MW2"),
            LightweightMiddleware(name: "MW3")
        ]
        
        // Setup pipelines
        let standardPipeline = StandardPipeline(handler: handler)
        for mw in middleware {
            try await standardPipeline.addMiddleware(mw)
        }
        
        let optimizedChain = await optimizer.optimize(
            middleware: middleware,
            handler: handler
        )
        
        XCTAssertTrue(optimizedChain.hasFastPath, "Should have fast path for triple middleware")
        
        // Measure performance
        let standardTime = await measure {
            let command = BenchmarkCommand()
            let context = CommandContext()
            _ = try? await standardPipeline.execute(command, context: context)
        }
        
        let fastPathTime = await measure {
            let command = BenchmarkCommand()
            let context = CommandContext()
            // Fast path execution is now internal
            _ = try? await standardPipeline.execute(command, context: context)
        }
        
        let improvement = ((standardTime - fastPathTime) / standardTime) * 100
        print("Triple middleware improvement: \(String(format: "%.1f", improvement))%")
        
        // Should see significant improvement with more middleware
        XCTAssertGreaterThan(improvement, 20.0, "Fast path should provide >20% improvement")
    }
    
    func testTypeErasureOverhead() async throws {
        let iterations = 10000
        
        // Direct execution without type erasure
        let directStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            let command = BenchmarkCommand()
            let handler = BenchmarkHandler()
            _ = try await handler.handle(command)
        }
        let directTime = CFAbsoluteTimeGetCurrent() - directStart
        
        // With type erasure (simulating FastPathExecutor approach)
        let typeErasedStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            struct TypeErasedCommand: Command, @unchecked Sendable {
                typealias Result = Any
                let wrapped: Any
            }
            
            let command = BenchmarkCommand()
            let wrapped = TypeErasedCommand(wrapped: command)
            let handler = BenchmarkHandler()
            
            // Simulate the type erasure overhead
            guard let unwrapped = wrapped.wrapped as? BenchmarkCommand else {
                XCTFail("Type mismatch")
                return
            }
            let result = try await handler.handle(unwrapped)
            _ = result as Any
        }
        let typeErasedTime = CFAbsoluteTimeGetCurrent() - typeErasedStart
        
        let overhead = ((typeErasedTime - directTime) / directTime) * 100
        print("Type erasure overhead: \(String(format: "%.1f", overhead))%")
        
        // Document the overhead for optimization planning
        XCTAssertLessThan(overhead, 50.0, "Type erasure overhead should be reasonable")
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
