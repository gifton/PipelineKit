import XCTest
import PipelineKit

final class PipelineExecutionBenchmarks: XCTestCase {
    
    // MARK: - StandardPipeline Benchmarks
    
    func testStandardPipelineBaseline() async throws {
        let config = BenchmarkConfiguration.default
        let handler = BenchmarkHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Warmup
        await BenchmarkUtilities.warmup(iterations: config.warmupIterations) {
            _ = try await pipeline.execute(
                BenchmarkCommand(payload: "warmup"),
                context: CommandContext()
            )
        }
        
        // Measure execution time
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let expectation = self.expectation(description: "Pipeline execution")
            
            Task {
                for i in 0..<config.measurementIterations {
                    _ = try await pipeline.execute(
                        BenchmarkCommand(payload: "test-\(i)"),
                        context: CommandContext()
                    )
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: config.timeout)
        }
    }
    
    func testStandardPipelineWithMiddleware() async throws {
        let config = BenchmarkConfiguration.default
        let handler = BenchmarkHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Add various middleware
        try await pipeline.addMiddleware(PerformanceMiddleware())
        try await pipeline.addMiddleware(ValidationMiddleware())
        try await pipeline.addMiddleware(AuthenticationMiddleware(
            authenticator: { _ in return true }
        ))
        
        // Warmup
        await BenchmarkUtilities.warmup(iterations: config.warmupIterations) {
            _ = try await pipeline.execute(
                BenchmarkCommand(payload: "warmup"),
                context: CommandContext()
            )
        }
        
        // Measure with middleware overhead
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let expectation = self.expectation(description: "Pipeline with middleware")
            
            Task {
                for i in 0..<config.measurementIterations {
                    _ = try await pipeline.execute(
                        BenchmarkCommand(payload: "test-\(i)"),
                        context: CommandContext()
                    )
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: config.timeout)
        }
    }
    
    func testStandardPipelineMemoryAllocation() async throws {
        let handler = MemoryIntensiveHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let memoryMetrics = await BenchmarkUtilities.measureMemory(iterations: 100) {
            _ = try await pipeline.execute(
                MemoryIntensiveCommand(size: 1024 * 1024), // 1MB
                context: CommandContext()
            )
        }
        
        print(memoryMetrics)
        
        // Assert reasonable memory usage
        let averageAllocationMB = Double(memoryMetrics.averageAllocation) / (1024 * 1024)
        XCTAssertLessThan(averageAllocationMB, 2.0, "Average allocation should be less than 2MB")
    }
    
    // MARK: - ConcurrentPipeline Benchmarks
    
    func testConcurrentPipelineThroughput() async throws {
        let config = BenchmarkConfiguration.stress
        let options = PipelineOptions(
            maxConcurrency: config.concurrencyLevel,
            maxOutstanding: config.operationCount,
            backPressureStrategy: .suspend
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = BenchmarkHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        
        await pipeline.register(BenchmarkCommand.self, pipeline: standardPipeline)
        
        // Measure throughput
        let throughputMetrics = await BenchmarkUtilities.measureThroughput(
            operations: config.operationCount,
            timeout: config.timeout
        ) {
            _ = try await pipeline.execute(
                BenchmarkCommand(payload: "throughput-test"),
                context: CommandContext()
            )
        }
        
        print(throughputMetrics)
        
        // Assert minimum throughput
        XCTAssertGreaterThan(
            throughputMetrics.throughputPerSecond,
            1000,
            "Should process at least 1000 ops/sec"
        )
    }
    
    func testConcurrentPipelineParallelExecution() async throws {
        let config = BenchmarkConfiguration.default
        let options = PipelineOptions(
            maxConcurrency: config.concurrencyLevel,
            backPressureStrategy: .suspend
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = CPUIntensiveHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        
        await pipeline.register(CPUIntensiveCommand.self, pipeline: standardPipeline)
        
        // Create batch of CPU-intensive commands
        let commands = (0..<100).map { _ in
            CPUIntensiveCommand(iterations: 10000)
        }
        
        // Measure parallel execution
        let startTime = Date()
        
        let results = try await pipeline.executeConcurrently(
            commands,
            context: CommandContext()
        )
        
        let duration = Date().timeIntervalSince(startTime)
        
        // Verify all succeeded
        let successCount = results.compactMap { try? $0.get() }.count
        XCTAssertEqual(successCount, commands.count)
        
        print("Parallel execution of \(commands.count) commands took \(duration)s")
        
        // Should complete faster than sequential
        let expectedSequentialTime = Double(commands.count) * 0.01 // Assuming ~10ms per command
        XCTAssertLessThan(duration, expectedSequentialTime * 0.5, "Parallel should be at least 2x faster")
    }
    
    // MARK: - PriorityPipeline Benchmarks
    
    func testPriorityPipelineOrdering() async throws {
        let handler = BenchmarkHandler()
        let pipeline = PriorityPipeline(handler: handler)
        
        // Add middleware with different priorities
        try await pipeline.addMiddleware(MockMiddleware(priority: .low))
        try await pipeline.addMiddleware(MockMiddleware(priority: .critical))
        try await pipeline.addMiddleware(MockMiddleware(priority: .normal))
        try await pipeline.addMiddleware(MockMiddleware(priority: .high))
        
        // Measure execution with priority ordering
        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "Priority execution")
            
            Task {
                for i in 0..<100 {
                    _ = try await pipeline.execute(
                        BenchmarkCommand(payload: "priority-\(i)"),
                        context: CommandContext()
                    )
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    // MARK: - Context Performance Benchmarks
    
    func testContextPerformance() async throws {
        let context = CommandContext()
        
        // Measure context operations
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let expectation = self.expectation(description: "Context operations")
            
            Task {
                for i in 0..<10000 {
                    await context.set("value-\(i)", for: TestContextKey.self)
                    let _ = await context.get(TestContextKey.self)
                    await context.remove(TestContextKey.self)
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    func testContextMemoryWithManyKeys() async throws {
        let context = CommandContext()
        
        let memoryMetrics = await BenchmarkUtilities.measureMemory(iterations: 10) {
            // Add 1000 different keys
            for i in 0..<1000 {
                await context.set("value-\(i)", for: DynamicContextKey<String>(key: "key-\(i)"))
            }
            
            // Clear for next iteration
            await context.clear()
        }
        
        print(memoryMetrics)
    }
    
    // MARK: - Middleware Chain Building Performance
    
    func testMiddlewareChainBuildingPerformance() async throws {
        let handler = BenchmarkHandler()
        
        // Test performance of building middleware chains
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let expectation = self.expectation(description: "Chain building")
            
            Task {
                for _ in 0..<100 {
                    let pipeline = StandardPipeline(handler: handler)
                    
                    // Add many middleware
                    for j in 0..<50 {
                        try await pipeline.addMiddleware(MockMiddleware(id: j))
                    }
                    
                    // Execute once to build chain
                    _ = try await pipeline.execute(
                        BenchmarkCommand(payload: "chain-test"),
                        context: CommandContext()
                    )
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 30)
        }
    }
}

// MARK: - Test Helpers

private struct TestContextKey: ContextKey {
    typealias Value = String
}

private struct DynamicContextKey<T>: ContextKey {
    typealias Value = T
    let key: String
}

private struct MockMiddleware: Middleware {
    let priority: ExecutionPriority
    let id: Int
    
    init(priority: ExecutionPriority = .normal, id: Int = 0) {
        self.priority = priority
        self.id = id
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Minimal overhead - just pass through
        return try await next(command, context)
    }
}