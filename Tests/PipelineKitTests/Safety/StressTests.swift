import XCTest
@testable import PipelineKit

/* TODO: StressTests use removed components (SafeWorkStealingExecutor, ManagedAtomic, ShardedConcurrentQueue, SafeBatchProcessor)
final class StressTests: XCTestCase {
    
    func testHighConcurrencyStress() async throws {
        let executor = SafeWorkStealingExecutor(workerCount: 16)
        let operations = 10_000
        let results = ManagedAtomic<Int>(0)
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<operations {
                group.addTask {
                    _ = try? await executor.execute {
                        // Simulate varying workloads
                        let complexity = Int.random(in: 1...100)
                        var sum = 0
                        for i in 0..<complexity {
                            sum += i
                        }
                        results.wrappingIncrement(ordering: .relaxed)
                        return sum
                    }
                }
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        print("Stress test completed: \(operations) ops in \(elapsed)s")
        print("Rate: \(Double(operations) / elapsed) ops/sec")
        
        XCTAssertEqual(results.load(ordering: .relaxed), operations)
    }
    
    func testMemoryPressure() async throws {
        let queue = ShardedConcurrentQueue<Data>()
        let memoryLimit = 100_000_000 // 100MB
        var totalMemory = 0
        
        // Producer with memory tracking
        let producer = Task {
            for i in 0..<1000 {
                let size = Int.random(in: 1000...100_000)
                let data = Data(repeating: UInt8(i % 256), count: size)
                
                queue.enqueue(data)
                totalMemory += size
                
                if totalMemory > memoryLimit {
                    break
                }
            }
        }
        
        // Consumer
        let consumer = Task {
            var consumed = 0
            while consumed < 100 || !queue.isEmpty {
                if let _ = queue.dequeue() {
                    consumed += 1
                } else {
                    await Task.yield()
                }
            }
            return consumed
        }
        
        await producer.value
        let consumedCount = await consumer.value
        
        XCTAssertGreaterThan(consumedCount, 0)
        XCTAssertTrue(queue.isEmpty || queue.approximateCount < 10)
    }
    
    func testDeadlockPrevention() async throws {
        let processor1 = SafeBatchProcessor<TestCommand>(
            pipeline: StandardPipeline(handler: TestHandler())
        )
        let processor2 = SafeBatchProcessor<TestCommand>(
            pipeline: StandardPipeline(handler: TestHandler())
        )
        
        // Cross-submission that could deadlock with poor implementation
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<100 {
                    _ = try? await processor1.submit(TestCommand(value: i))
                    if i % 10 == 0 {
                        _ = try? await processor2.submit(TestCommand(value: i))
                    }
                }
            }
            
            group.addTask {
                for i in 0..<100 {
                    _ = try? await processor2.submit(TestCommand(value: i))
                    if i % 10 == 0 {
                        _ = try? await processor1.submit(TestCommand(value: i))
                    }
                }
            }
        }
        
        // If we reach here, no deadlock occurred
        XCTAssertTrue(true, "No deadlock detected")
    }
    
    func testContinuationSafety() async throws {
        let processor = SafeBatchProcessor<TestCommand>(
            pipeline: StandardPipeline(handler: SlowHandler()),
            configuration: .init(maxBatchSize: 5, maxBatchWaitTime: 0.1)
        )
        
        // Submit many commands that will batch
        let results = await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try await processor.submit(TestCommand(value: i))
                }
            }
            
            var results: [Int] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, 20)
        XCTAssertEqual(Set(results).count, 20, "All results unique")
    }
}

struct SlowHandler: CommandHandler {
    typealias CommandType = TestCommand
    
    func handle(_ command: TestCommand) async throws -> Int {
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        return command.value * 2
    }
}
*/