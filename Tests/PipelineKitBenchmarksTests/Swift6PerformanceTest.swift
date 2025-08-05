import XCTest
@testable import PipelineKit
@testable import PipelineKitMiddleware

/// Benchmark test to verify no performance regression from Swift 6 concurrency changes
final class Swift6PerformanceTest: XCTestCase {
    private struct TestCommand: Command {
        typealias Result = String
        let id: Int
    }
    
    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Result-\(command.id)"
        }
    }
    
    /// Test basic pipeline execution performance
    func testBasicPipelinePerformance() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        let iterations = 1000
        
        // Warm up
        for i in 0..<10 {
            _ = try await pipeline.execute(TestCommand(id: i), context: CommandContext())
        }
        
        // Measure execution time
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for i in 0..<iterations {
            _ = try await pipeline.execute(TestCommand(id: i), context: CommandContext())
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let avgTime = totalTime / Double(iterations) * 1000 // Convert to ms
        let opsPerSecond = Double(iterations) / totalTime
        
        print("\n=== Swift 6 Pipeline Performance ===")
        print("Total iterations: \(iterations)")
        print("Total time: \(String(format: "%.3f", totalTime)) seconds")
        print("Average time per operation: \(String(format: "%.3f", avgTime)) ms")
        print("Operations per second: \(String(format: "%.0f", opsPerSecond))")
        
        // Assert reasonable performance (should handle at least 1000 ops/sec)
        XCTAssertGreaterThan(opsPerSecond, 1000, "Pipeline should handle at least 1000 ops/sec")
    }
    
    // REMOVED: Context pool performance test removed
    // Direct allocation is 19-51% faster than pooling for lightweight CommandContext objects
    
    /// Test middleware chain performance with Sendable conformance
    func testMiddlewareChainPerformance() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        
        // Add several middleware
        // MetricsMiddleware requires a collector
        let collector = TestMetricsCollector()
        try await pipeline.addMiddleware(MetricsMiddleware(collector: collector))
        try await pipeline.addMiddleware(AuthorizationMiddleware(
            requiredRoles: Set(["user"]),
            getUserRoles: { _ in Set(["user", "admin"]) }
        ))
        try await pipeline.addMiddleware(CachingMiddleware(
            cache: InMemoryCache()
        ))
        
        let iterations = 500
        
        // Warm up
        for i in 0..<10 {
            _ = try await pipeline.execute(TestCommand(id: i), context: CommandContext())
        }
        
        // Measure execution time
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for i in 0..<iterations {
            _ = try await pipeline.execute(TestCommand(id: i), context: CommandContext())
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let avgTime = totalTime / Double(iterations) * 1000 // Convert to ms
        let opsPerSecond = Double(iterations) / totalTime
        
        print("\n=== Middleware Chain Performance ===")
        print("Total iterations: \(iterations)")
        print("Total time: \(String(format: "%.3f", totalTime)) seconds")
        print("Average time per operation: \(String(format: "%.3f", avgTime)) ms")
        print("Operations per second: \(String(format: "%.0f", opsPerSecond))")
        
        // With middleware, expect at least 500 ops/sec
        XCTAssertGreaterThan(opsPerSecond, 500, "Pipeline with middleware should handle at least 500 ops/sec")
    }
    
    /// Test concurrent pipeline performance with actor-based optimizer
    func testConcurrentExecutionPerformance() async throws {
        let concurrentPipeline = ConcurrentPipeline(
            options: PipelineOptions(maxConcurrency: 10, maxOutstanding: 1000)
        )
        let executor = StandardPipeline(handler: TestHandler())
        
        await concurrentPipeline.register(TestCommand.self, pipeline: executor)
        
        let iterations = 1000
        let commands = (0..<iterations).map { TestCommand(id: $0) }
        
        // Measure concurrent execution
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let results = try await concurrentPipeline.executeConcurrently(commands)
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let opsPerSecond = Double(iterations) / totalTime
        
        print("\n=== Concurrent Execution Performance ===")
        print("Total commands: \(iterations)")
        print("Total time: \(String(format: "%.3f", totalTime)) seconds")
        print("Operations per second: \(String(format: "%.0f", opsPerSecond))")
        
        // Verify all succeeded
        XCTAssertEqual(results.count, iterations)
        for result in results {
            if case .failure = result {
                XCTFail("Unexpected failure in concurrent execution")
            }
        }
        
        // Concurrent execution should be fast (at least 2000 ops/sec)
        XCTAssertGreaterThan(opsPerSecond, 2000, "Concurrent pipeline should handle at least 2000 ops/sec")
    }
}

// MARK: - Test Helpers

private struct TestMetricsCollector: DetailedMetricsCollector {
    func recordLatency(_ name: String, value: TimeInterval, tags: [String: String]) async {}
    func incrementCounter(_ name: String, value: Double, tags: [String: String]) async {}
    func recordGauge(_ name: String, value: Double, tags: [String: String]) async {}
}
