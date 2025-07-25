import Foundation
import PipelineKit

// Simple test to verify basic performance
struct TestCommand: Command {
    typealias Result = String
    let value: Int
}

struct TestHandler: CommandHandler {
    typealias CommandType = TestCommand
    
    func handle(_ command: TestCommand) async throws -> String {
        return "Processed: \(command.value)"
    }
}

// Simple middleware that adds timing
struct TimingMiddleware: Middleware {
    let priority = ExecutionPriority.processing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = Date()
        let result = try await next(command, context)
        let elapsed = Date().timeIntervalSince(start)
        print("Execution took: \(elapsed * 1000)ms")
        return result
    }
}

// Test function
func runPerformanceTest() async throws {
    print("=== Basic Performance Test ===")
    
    // Create pipeline
    let pipeline = StandardPipeline(handler: TestHandler())
    try await pipeline.addMiddleware(TimingMiddleware())
    
    // Warm up
    print("\nWarm up run:")
    _ = try await pipeline.execute(TestCommand(value: 0))
    
    // Test single execution
    print("\nSingle execution:")
    let start = Date()
    let result = try await pipeline.execute(TestCommand(value: 42))
    let elapsed = Date().timeIntervalSince(start)
    print("Result: \(result)")
    print("Total time: \(elapsed * 1000)ms")
    
    // Test multiple executions
    print("\nMultiple executions (100 iterations):")
    let multiStart = Date()
    for i in 0..<100 {
        _ = try await pipeline.execute(TestCommand(value: i))
    }
    let multiElapsed = Date().timeIntervalSince(multiStart)
    print("Total time: \(multiElapsed * 1000)ms")
    print("Average per execution: \(multiElapsed * 10)ms")
    
    // Test concurrent executions
    print("\nConcurrent executions (100 concurrent):")
    let concurrentStart = Date()
    await withTaskGroup(of: String.self) { group in
        for i in 0..<100 {
            group.addTask {
                try! await pipeline.execute(TestCommand(value: i))
            }
        }
        for await _ in group {
            // Just consume results
        }
    }
    let concurrentElapsed = Date().timeIntervalSince(concurrentStart)
    print("Total time: \(concurrentElapsed * 1000)ms")
    print("Average per execution: \(concurrentElapsed * 10)ms")
    
    // Test with context pool
    print("\nWith context pooling:")
    let pooledPipeline = StandardPipeline(handler: TestHandler(), useContextPool: true)
    try await pooledPipeline.addMiddleware(TimingMiddleware())
    
    let poolStart = Date()
    for i in 0..<100 {
        _ = try await pooledPipeline.execute(TestCommand(value: i))
    }
    let poolElapsed = Date().timeIntervalSince(poolStart)
    print("Total time: \(poolElapsed * 1000)ms")
    print("Average per execution: \(poolElapsed * 10)ms")
    
    // Show pool statistics
    let stats = CommandContextPool.shared.getStatistics()
    print("\nContext Pool Statistics:")
    print("  Total allocated: \(stats.totalAllocated)")
    print("  Currently available: \(stats.currentlyAvailable)")
    print("  Currently in use: \(stats.currentlyInUse)")
    print("  Total borrows: \(stats.totalBorrows)")
    print("  Hit rate: \(String(format: "%.1f%%", stats.hitRate * 100))")
}

// Run the test
Task {
    do {
        try await runPerformanceTest()
        print("\n✅ Performance test completed successfully")
    } catch {
        print("\n❌ Performance test failed: \(error)")
    }
    exit(0)
}

RunLoop.main.run()