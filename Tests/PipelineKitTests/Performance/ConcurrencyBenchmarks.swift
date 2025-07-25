import XCTest
@testable import PipelineKit

final class ConcurrencyBenchmarks: XCTestCase {
    
    struct BenchmarkCommand: Command {
        typealias Result = Int
        let value: Int
        let complexity: Int // Simulated work complexity
    }
    
    struct BenchmarkHandler: CommandHandler {
        typealias CommandType = BenchmarkCommand
        
        func handle(_ command: BenchmarkCommand) async throws -> Int {
            // Simulate work based on complexity
            if command.complexity > 0 {
                for _ in 0..<command.complexity {
                    _ = (0..<100).reduce(0, +)
                }
            }
            return command.value * 2
        }
    }
    
    // REMOVED: testBatchingPerformance - BatchProcessor no longer exists in the codebase
    
    // REMOVED: testParallelMiddlewarePerformance - ParallelPipeline no longer exists in the codebase
    
    // REMOVED: testWorkStealingPerformance - WorkStealingPipelineExecutor no longer exists in the codebase
    
    // REMOVED: testAdaptiveConcurrencyPerformance - AdaptivePipeline no longer exists in the codebase
    
    // REMOVED: testLockFreePerformance - LockFreePipeline no longer exists in the codebase
    
    // REMOVED: testOptimizedConcurrentPipeline - OptimizedConcurrentPipeline no longer exists in the codebase
}

// MARK: - Mock Middleware for Testing

struct LoggingMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate logging
        _ = String(describing: command)
        return try await next(command, context)
    }
}

struct BenchmarkMetricsMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await next(command, context)
        _ = CFAbsoluteTimeGetCurrent() - start
        return result
    }
}

struct TracingMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        context.set(UUID().uuidString, for: TraceIDKey.self)
        return try await next(command, context)
    }
}

struct ValidationMiddleware: Middleware {
    let priority = ExecutionPriority.validation
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate validation
        if let validatable = command as? any ValidatableCommand {
            try await validatable.validate()
        }
        return try await next(command, context)
    }
}

struct CacheMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate cache check
        let cacheKey = String(describing: command).hashValue
        _ = cacheKey
        return try await next(command, context)
    }
}

struct TraceIDKey: ContextKey {
    typealias Value = String
}