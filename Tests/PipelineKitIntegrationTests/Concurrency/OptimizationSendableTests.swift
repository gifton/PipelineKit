import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

/// Tests for Sendable conformance of optimization-related types
final class OptimizationSendableTests: XCTestCase {
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let id: String
    }
    
    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Result: \(command.id)"
        }
    }
    
    private struct TestMiddleware: Middleware {
        let priority: ExecutionPriority
        let name: String
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            return try await next(command, context)
        }
    }
    
    // MARK: - ObservablePipeline Tests
    
    func testObservablePipelineIsSendable() async {
        // Verify ObservablePipeline is Sendable at compile time
        let pipeline = StandardPipeline(handler: TestHandler())
        let observable = ObservablePipeline(wrapping: pipeline)
        
        // This should compile - ObservablePipeline is Sendable
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let result = try await observable.execute(
                        TestCommand(id: "test"),
                        context: CommandContext()
                    )
                    return result
                } catch {
                    return nil
                }
            }
        }
        
        // Verify it can be sent across actors
        actor TestActor {
            func usePipeline(_ pipeline: ObservablePipeline) async throws -> String {
                try await pipeline.execute(TestCommand(id: "actor-test"), context: CommandContext())
            }
        }
        
        let actor = TestActor()
        let result = try? await actor.usePipeline(observable)
        XCTAssertEqual(result, "Result: actor-test")
    }
    
    // MARK: - MiddlewareChainOptimizer Tests
    
    func testMiddlewareChainOptimizerIsActor() async {
        // MiddlewareChainOptimizer is now an actor
        let optimizer = MiddlewareChainOptimizer()
        
        // Test concurrent access to the optimizer
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let middlewares = [
                        TestMiddleware(priority: .authentication, name: "Auth\(i)"),
                        TestMiddleware(priority: .validation, name: "Validation\(i)"),
                        TestMiddleware(priority: .processing, name: "Process\(i)")
                    ]
                    
                    _ = await optimizer.optimize(
                        middleware: middlewares,
                        handler: nil
                    )
                }
            }
        }
    }
    
    func testOptimizedChainIsSendable() async {
        // Verify OptimizedChain and related types are Sendable
        let optimizer = MiddlewareChainOptimizer()
        let middlewares = [
            TestMiddleware(priority: .authentication, name: "Auth"),
            TestMiddleware(priority: .validation, name: "Validation")
        ]
        
        let optimizedChain = await optimizer.optimize(
            middleware: middlewares,
            handler: TestHandler()
        )
        
        // Send across actor boundary
        actor ChainUser {
            func useChain(_ chain: MiddlewareChainOptimizer.OptimizedChain) -> Int {
                return chain.metadata.count
            }
        }
        
        let user = ChainUser()
        let count = await user.useChain(optimizedChain)
        XCTAssertEqual(count, 2)
    }
    
    func testFastPathExecutorIsSendable() async {
        // FastPathExecutor should be Sendable
        let executor = MiddlewareChainOptimizer.FastPathExecutor(
            middleware: [],
            executorFunc: { command, _, handler in
                return try await handler(command)
            }
        )
        
        // Use across concurrency boundaries
        await withTaskGroup(of: String?.self) { group in
            for i in 0..<5 {
                group.addTask {
                    try? await executor.execute(
                        TestCommand(id: "test-\(i)"),
                        context: CommandContext()
                    ) { cmd in
                        return "FastPath: \(cmd.id)"
                    }
                }
            }
            
            var results: [String] = []
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
            
            XCTAssertEqual(results.count, 5)
        }
    }
    
    // MARK: - MiddlewareProfiler Tests
    
    func testMiddlewareProfilerProtocolRequiresSendable() {
        // Create a profiler that must be Sendable
        struct TestProfiler: MiddlewareProfiler {
            func recordExecution(
                middleware: any Middleware,
                duration: TimeInterval,
                success: Bool
            ) {
                // Implementation
            }
            
            func getAverageExecutionTime(for middleware: any Middleware) -> TimeInterval? {
                return nil
            }
        }
        
        // This should compile - TestProfiler is implicitly Sendable
        let _: any Sendable = TestProfiler()
    }
    
    // MARK: - Integration Tests
    
    func testPipelineBuilderWithOptimization() async throws {
        // Test that PipelineBuilder works with the actor-based optimizer
        let handler = TestHandler()
        let builder = await PipelineBuilder(handler: handler)
            .with(TestMiddleware(priority: .authentication, name: "Auth"))
            .with(TestMiddleware(priority: .validation, name: "Validate"))
            .withOptimization()
        
        let pipeline = try await builder.build()
        
        // Execute commands concurrently
        await withTaskGroup(of: String?.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try? await pipeline.execute(TestCommand(id: "concurrent-\(i)"))
                }
            }
            
            var results: [String] = []
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
            
            XCTAssertEqual(results.count, 10)
            XCTAssertTrue(results.allSatisfy { $0.starts(with: "Result: concurrent-") })
        }
    }
    
    func testConcurrentOptimization() async {
        // Test multiple optimizers working concurrently
        await withTaskGroup(of: MiddlewareChainOptimizer.OptimizedChain.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let optimizer = MiddlewareChainOptimizer()
                    let middlewares = [
                        TestMiddleware(priority: .processing, name: "Process\(i)")
                    ]
                    
                    return await optimizer.optimize(
                        middleware: middlewares,
                        handler: nil
                    )
                }
            }
            
            var chains: [MiddlewareChainOptimizer.OptimizedChain] = []
            for await chain in group {
                chains.append(chain)
            }
            
            XCTAssertEqual(chains.count, 5)
            XCTAssertTrue(chains.allSatisfy { $0.metadata.count == 1 })
        }
    }
}
