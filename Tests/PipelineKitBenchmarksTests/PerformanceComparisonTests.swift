import XCTest
@testable import PipelineKit
@testable import PipelineKitMiddleware
import PipelineKitTestSupport

/// Tests that demonstrate and validate performance improvements
final class PerformanceComparisonTests: XCTestCase {
    // MARK: - Context Performance Tests
    
    func testContextPerformanceImprovement() async throws {
        // This test demonstrates the performance improvement from removing actor isolation
        
        let iterations = 10000
        let context = CommandContext(metadata: StandardCommandMetadata(userId: "test"))
        
        measure {
            for i in 0..<iterations {
                // Previously would have been: await context.set(i, for: PerfTestKey.self)
                context.set(i, for: PerfTestKey.self)
                _ = context.get(PerfTestKey.self)
            }
        }
        
        // Expected: 30-50% faster than actor-based implementation
    }
    
    func testConcurrentContextAccess() async throws {
        // Demonstrates thread-safe concurrent access without actor overhead
        
        let context = CommandContext(metadata: StandardCommandMetadata(userId: "test"))
        let iterations = 1000
        
        measure {
            let expectation = expectation(description: "concurrent")
            expectation.expectedFulfillmentCount = 10
            
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for i in 0..<10 {
                        group.addTask {
                            for j in 0..<iterations {
                                context.set("\(i)-\(j)", for: PerfStringKey.self)
                                _ = context.get(PerfStringKey.self)
                            }
                            expectation.fulfill()
                        }
                    }
                }
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    // MARK: - Parallel Middleware Tests
    
    func testParallelMiddlewarePerformance() async throws {
        // Demonstrates parallel middleware execution performance
        
        let handler = MockCommandHandler()
        
        // Create middleware that can run in parallel
        let loggingMiddleware = SlowLoggingMiddleware()
        let metricsMiddleware = SlowMetricsMiddleware()
        let auditMiddleware = SlowAuditMiddleware()
        
        // Sequential execution
        let sequentialPipeline = try await PipelineBuilder(handler: handler)
            .with([loggingMiddleware, metricsMiddleware, auditMiddleware])
            .build()
        
        // Parallel execution
        let parallelWrapper = ParallelMiddlewareWrapper(
            middlewares: [loggingMiddleware, metricsMiddleware, auditMiddleware],
            strategy: .sideEffectsOnly
        )
        let parallelPipeline = try await PipelineBuilder(handler: handler)
            .with([parallelWrapper])
            .build()
        
        let command = MockCommand(value: 42)
        let context = CommandContext(metadata: StandardCommandMetadata(userId: "test"))
        
        // Measure sequential
        let sequentialTime = await measureAsync {
            _ = try await sequentialPipeline.execute(command, context: context)
        }
        
        // Measure parallel
        let parallelTime = await measureAsync {
            _ = try await parallelPipeline.execute(command, context: context)
        }
        
        // Calculate improvement
        let improvement = ((sequentialTime - parallelTime) / sequentialTime) * 100
        print("Parallel middleware is \(String(format: "%.1f", improvement))% faster")
        
        // Should be significantly faster (close to 3x for 3 middleware)
        XCTAssertLessThan(parallelTime, sequentialTime * 0.5)
    }
    
    // MARK: - Context Pooling Tests
    
    // REMOVED: Context pooling test removed as pooling degrades performance
    // Analysis showed 19-51% performance degradation with pooling due to
    // synchronization overhead exceeding allocation cost for lightweight objects
    
    // MARK: - Caching Middleware Tests
    
    func testCachedMiddlewarePerformance() async throws {
        // Demonstrates caching middleware performance benefits
        
        let handler = MockCommandHandler()
        let expensiveMiddleware = ExpensiveComputationMiddleware()
        
        // Pipeline with cached middleware
        let cache = InMemoryMiddlewareCache()
        let cachedMiddleware = CachedMiddleware(
            wrapping: expensiveMiddleware,
            cache: cache,
            ttl: 60
        )
        let pipeline = try await PipelineBuilder(handler: handler)
            .with([cachedMiddleware])
            .build()
        
        let command = MockCommand(value: 42)
        let context = CommandContext(metadata: StandardCommandMetadata(userId: "test"))
        
        // First execution (cache miss)
        let firstTime = await measureAsync {
            _ = try await pipeline.execute(command, context: context)
        }
        
        // Second execution (cache hit)
        let secondTime = await measureAsync {
            _ = try await pipeline.execute(command, context: context)
        }
        
        // Calculate improvement
        let improvement = ((firstTime - secondTime) / firstTime) * 100
        print("Cached middleware is \(String(format: "%.1f", improvement))% faster on cache hit")
        
        // Cache hit should be significantly faster
        XCTAssertLessThan(secondTime, firstTime * 0.1)
    }
    
    // MARK: - Helpers
    
    private func measureAsync<T>(
        iterations: Int = 100,
        _ block: () async throws -> T
    ) async -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        
        for _ in 0..<iterations {
            _ = try? await block()
        }
        
        let end = CFAbsoluteTimeGetCurrent()
        return (end - start) / Double(iterations)
    }
}

// MARK: - Test Middleware

private struct SlowLoggingMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate slow logging
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        let result = try await next(command, context)
        context.set("logged", for: PerfStringKey.self)
        return result
    }
}

private struct SlowMetricsMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate slow metrics collection
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        let result = try await next(command, context)
        context.set("metrics", for: PerfStringKey.self)
        return result
    }
}

private struct SlowAuditMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate slow audit logging
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        let result = try await next(command, context)
        context.set("audited", for: PerfStringKey.self)
        return result
    }
}

private struct ExpensiveComputationMiddleware: Middleware {
    let priority = ExecutionPriority.processing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate expensive computation
        var sum = 0
        for i in 0..<100000 {
            sum += i
        }
        context.set(sum, for: PerfTestKey.self)
        
        // Add artificial delay
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        return try await next(command, context)
    }
}

// MARK: - Test Types

private struct PerfTestKey: ContextKey {
    typealias Value = Int
}

private struct PerfStringKey: ContextKey {
    typealias Value = String
}
