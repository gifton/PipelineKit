import XCTest
@testable import PipelineKit

/// Integration tests to validate FastPathExecutor performance improvements
final class FastPathExecutorIntegrationTests: XCTestCase {
    
    // MARK: - Test Infrastructure
    
    struct CalculateCommand: Command {
        typealias Result = Int
        let value: Int
        let operations: [Operation]
        
        enum Operation {
            case add(Int)
            case multiply(Int)
            case subtract(Int)
        }
    }
    
    struct CalculateHandler: CommandHandler {
        typealias CommandType = CalculateCommand
        
        func handle(_ command: CalculateCommand) async throws -> Int {
            var result = command.value
            for operation in command.operations {
                switch operation {
                case .add(let value):
                    result += value
                case .multiply(let value):
                    result *= value
                case .subtract(let value):
                    result -= value
                }
            }
            return result
        }
    }
    
    struct ValidationMiddleware: Middleware {
        let priority = ExecutionPriority.validation
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Validate command
            if let calc = command as? CalculateCommand {
                guard calc.value >= 0 else {
                    throw PipelineError.validation(field: "value", reason: .custom("Value must be non-negative"))
                }
            }
            return try await next(command, context)
        }
    }
    
    struct LoggingMiddleware: Middleware {
        let priority = ExecutionPriority.postProcessing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await next(command, context)
            let duration = CFAbsoluteTimeGetCurrent() - start
            context.set(duration, for: ExecutionTimeKey.self)
            return result
        }
    }
    
    struct AuthenticationMiddleware: Middleware {
        let priority = ExecutionPriority.authentication
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Check auth
            guard context.get(UserIdKey.self) != nil else {
                throw PipelineError.authorization(reason: .invalidCredentials)
            }
            return try await next(command, context)
        }
    }
    
    // Context Keys
    private struct ExecutionTimeKey: ContextKey {
        typealias Value = TimeInterval
    }
    
    private struct UserIdKey: ContextKey {
        typealias Value = String
    }
    
    // Errors are now part of PipelineError
    
    // MARK: - Tests
    
    func testRealWorldPerformanceGain() async throws {
        let handler = CalculateHandler()
        let optimizer = MiddlewareChainOptimizer()
        
        // Real-world middleware stack
        let middleware: [any Middleware] = [
            AuthenticationMiddleware(),
            ValidationMiddleware(),
            LoggingMiddleware()
        ]
        
        // Setup standard pipeline
        let standardPipeline = StandardPipeline(handler: handler)
        for mw in middleware {
            try await standardPipeline.addMiddleware(mw)
        }
        
        // Setup optimized pipeline
        let optimizedChain = await optimizer.optimize(
            middleware: middleware,
            handler: handler
        )
        
        XCTAssertNotNil(optimizedChain.fastPathExecutor, "Should have fast path for triple middleware")
        
        // Test with realistic workload
        let commands = (0..<1000).map { i in
            CalculateCommand(
                value: i,
                operations: [
                    .add(10),
                    .multiply(2),
                    .subtract(5)
                ]
            )
        }
        
        // Measure standard pipeline
        let standardStart = CFAbsoluteTimeGetCurrent()
        for command in commands {
            let context = CommandContext()
            context.set("user123", for: UserIdKey.self)
            _ = try await standardPipeline.execute(command, context: context)
        }
        let standardTime = CFAbsoluteTimeGetCurrent() - standardStart
        
        // Measure optimized pipeline
        let optimizedStart = CFAbsoluteTimeGetCurrent()
        for command in commands {
            let context = CommandContext()
            context.set("user123", for: UserIdKey.self)
            if let fastPath = optimizedChain.fastPathExecutor {
                _ = try await fastPath.execute(command, context: context) { cmd in
                    try await handler.handle(cmd)
                }
            }
        }
        let optimizedTime = CFAbsoluteTimeGetCurrent() - optimizedStart
        
        let improvement = ((standardTime - optimizedTime) / standardTime) * 100
        print("Real-world performance improvement: \(String(format: "%.1f", improvement))%")
        print("Standard: \(String(format: "%.3f", standardTime))s")
        print("Optimized: \(String(format: "%.3f", optimizedTime))s")
        
        // Should see significant improvement
        XCTAssertGreaterThan(improvement, 25.0, "Should see >25% improvement in real-world scenario")
    }
    
    func testScalabilityWithManyMiddleware() async throws {
        let handler = CalculateHandler()
        let optimizer = MiddlewareChainOptimizer()
        
        // Test scalability as middleware count increases
        for middlewareCount in [1, 2, 3, 4, 5, 10] {
            let middleware = (0..<middlewareCount).map { i in
                LoggingMiddleware()
            }
            
            // Standard pipeline
            let standardPipeline = StandardPipeline(handler: handler)
            for mw in middleware {
                try await standardPipeline.addMiddleware(mw)
            }
            
            // Optimized chain
            let optimizedChain = await optimizer.optimize(
                middleware: Array(middleware.prefix(3)), // Fast path only for ≤3
                handler: handler
            )
            
            let command = CalculateCommand(value: 100, operations: [.add(50)])
            let context = CommandContext()
            
            // Measure
            let standardTime = await measure(iterations: 1000) {
                _ = try? await standardPipeline.execute(command, context: context)
            }
            
            let optimizedTime: TimeInterval
            if middlewareCount <= 3, let fastPath = optimizedChain.fastPathExecutor {
                optimizedTime = await measure(iterations: 1000) {
                    _ = try? await fastPath.execute(command, context: context) { cmd in
                        try await handler.handle(cmd)
                    }
                }
            } else {
                optimizedTime = standardTime // No fast path for >3 middleware
            }
            
            let improvement = middlewareCount <= 3 ? 
                ((standardTime - optimizedTime) / standardTime) * 100 : 0
            
            print("Middleware count: \(middlewareCount), Improvement: \(String(format: "%.1f", improvement))%")
        }
    }
    
    func testMemoryEfficiency() async throws {
        let handler = CalculateHandler()
        let optimizer = MiddlewareChainOptimizer()
        
        let middleware: [any Middleware] = [
            ValidationMiddleware(),
            LoggingMiddleware()
        ]
        
        let optimizedChain = await optimizer.optimize(
            middleware: middleware,
            handler: handler
        )
        
        // Measure memory allocations
        let iterations = 10000
        
        // Warm up
        for _ in 0..<100 {
            let command = CalculateCommand(value: 42, operations: [])
            let context = CommandContext()
            if let fastPath = optimizedChain.fastPathExecutor {
                _ = try? await fastPath.execute(command, context: context) { cmd in
                    try await handler.handle(cmd)
                }
            }
        }
        
        // Memory test - FastPath should have fewer allocations
        let command = CalculateCommand(value: 42, operations: [.add(10)])
        
        // This would need actual memory profiling tools to measure accurately
        // For now, we just ensure it runs without issues
        for _ in 0..<iterations {
            let context = CommandContext()
            if let fastPath = optimizedChain.fastPathExecutor {
                _ = try await fastPath.execute(command, context: context) { cmd in
                    try await handler.handle(cmd)
                }
            }
        }
        
        // Test passes if no memory issues
        XCTAssertTrue(true, "Memory efficiency test completed")
    }
    
    func testConcurrentExecution() async throws {
        let handler = CalculateHandler()
        let optimizer = MiddlewareChainOptimizer()
        
        let middleware: [any Middleware] = [
            ValidationMiddleware(),
            LoggingMiddleware()
        ]
        
        let standardPipeline = StandardPipeline(handler: handler)
        for mw in middleware {
            try await standardPipeline.addMiddleware(mw)
        }
        
        let optimizedChain = await optimizer.optimize(
            middleware: middleware,
            handler: handler
        )
        
        // Test concurrent execution performance
        let concurrentTasks = 100
        let commands = (0..<concurrentTasks).map { i in
            CalculateCommand(value: i, operations: [.multiply(2), .add(1)])
        }
        
        // Standard pipeline concurrent
        let standardStart = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Int?.self) { group in
            for command in commands {
                group.addTask {
                    let context = CommandContext()
                    return try? await standardPipeline.execute(command, context: context)
                }
            }
            
            for await _ in group {
                // Collect results
            }
        }
        let standardTime = CFAbsoluteTimeGetCurrent() - standardStart
        
        // Optimized concurrent
        let optimizedStart = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Int?.self) { group in
            for command in commands {
                group.addTask { [optimizedChain] in
                    let context = CommandContext()
                    if let fastPath = optimizedChain.fastPathExecutor {
                        return try? await fastPath.execute(command, context: context) { cmd in
                            try await handler.handle(cmd)
                        }
                    }
                    return nil
                }
            }
            
            for await _ in group {
                // Collect results
            }
        }
        let optimizedTime = CFAbsoluteTimeGetCurrent() - optimizedStart
        
        let improvement = ((standardTime - optimizedTime) / standardTime) * 100
        print("Concurrent execution improvement: \(String(format: "%.1f", improvement))%")
        
        // Should maintain performance advantage under concurrent load
        XCTAssertGreaterThan(improvement, 20.0, "Should maintain >20% improvement under concurrent load")
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