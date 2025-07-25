import XCTest
@testable import PipelineKit

/* TODO: Most of these tests use removed components (SafeLockFreeQueue, ShardedConcurrentQueue, SafeBatchProcessor, etc.)
final class SafetyPerformanceTests: XCTestCase {
    
    func testSafeQueuePerformance() async throws {
        let safeQueue = SafeLockFreeQueue<Int>()
        let shardedQueue = ShardedConcurrentQueue<Int>()
        let iterations = 100_000
        
        // Benchmark safe queue
        let safeStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            safeQueue.enqueue(i)
        }
        for _ in 0..<iterations {
            _ = safeQueue.dequeue()
        }
        let safeTime = CFAbsoluteTimeGetCurrent() - safeStart
        
        // Benchmark sharded queue
        let shardedStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            shardedQueue.enqueue(i)
        }
        for _ in 0..<iterations {
            _ = shardedQueue.dequeue()
        }
        let shardedTime = CFAbsoluteTimeGetCurrent() - shardedStart
        
        print("Safe queue: \(safeTime)s (\(Double(iterations) / safeTime) ops/sec)")
        print("Sharded queue: \(shardedTime)s (\(Double(iterations) / shardedTime) ops/sec)")
        
        // Should maintain at least 80% of unsafe performance
        XCTAssertLessThan(safeTime, 1.0) // Sub-second for 100k ops
    }
    
    func testSafeBatchProcessorPerformance() async throws {
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        let processor = SafeBatchProcessor<TestCommand>(pipeline: pipeline)
        
        let commands = (0..<1000).map { TestCommand(value: $0) }
        
        let start = CFAbsoluteTimeGetCurrent()
        
        let results = try await processor.submitBatch(commands)
        
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("Safe batch processing: \(elapsed)s for \(commands.count) commands")
        print("Throughput: \(Double(commands.count) / elapsed) commands/sec")
        
        XCTAssertEqual(results.count, commands.count)
        
        // Verify at least 85% of Phase 1 performance
        let throughput = Double(commands.count) / elapsed
        XCTAssertGreaterThan(throughput, 2000, "Should maintain high throughput")
    }
    
    func testIntegratedPerformance() async throws {
        // Test with Specialist 1's memory optimizations
        let context = InlineOptimizedContext()
        let handler = TestHandler()
        
        // Use memory-optimized pipeline from Specialist 1
        let pipeline = OptimizedPipeline(handler: handler)
        
        // Use safe batch processor
        let processor = SafeBatchProcessor<TestCommand>(
            pipeline: pipeline,
            configuration: .init(maxBatchSize: 100)
        )
        
        // Benchmark integrated system
        let commands = (0..<10_000).map { TestCommand(value: $0) }
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for command in commands {
                group.addTask {
                    _ = try? await processor.submit(command, context: context)
                }
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let throughput = Double(commands.count) / elapsed
        
        print("Integrated performance: \(throughput) commands/sec")
        print("Memory safety: Using COW and inline storage")
        print("Concurrency safety: No unsafe pointers or semaphores")
        
        XCTAssertGreaterThan(throughput, 5000, "Should maintain high integrated throughput")
    }
}
*/