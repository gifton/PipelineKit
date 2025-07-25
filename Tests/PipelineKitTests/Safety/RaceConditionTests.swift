import XCTest
// import Atomics // Removed - was used by removed components
@testable import PipelineKit

final class RaceConditionTests: XCTestCase {
    
    /* TODO: ShardedConcurrentQueue was removed
    func testNoLostUpdates() async throws {
        let queue = ShardedConcurrentQueue<Int>()
        let producerCount = 10
        let itemsPerProducer = 1000
        
        // Track all produced items
        let produced = ManagedAtomic<Int>(0)
        
        // Produce items concurrently
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<producerCount {
                group.addTask {
                    for i in 0..<itemsPerProducer {
                        queue.enqueue(i)
                        produced.wrappingIncrement(ordering: .relaxed)
                    }
                }
            }
        }
        
        // Consume all items
        var consumed = 0
        while consumed < producerCount * itemsPerProducer {
            if queue.dequeue() != nil {
                consumed += 1
            } else {
                await Task.yield()
            }
        }
        
        XCTAssertEqual(consumed, producerCount * itemsPerProducer)
        XCTAssertTrue(queue.isEmpty)
    }
    */
    
    /* TODO: SafeBatchProcessor was removed
    func testNoDuplicateProcessing() async throws {
        let processor = SafeBatchProcessor<TestCommand>(
            pipeline: StandardPipeline(handler: TestHandler()),
            configuration: .init(maxBatchSize: 10)
        )
        
        let processedIds = ManagedAtomic<Set<Int>>(Set())
        let lock = NSLock()
        
        // Submit many commands concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let result = try? await processor.submit(TestCommand(value: i))
                    if let result = result {
                        lock.lock()
                        var set = processedIds.load(ordering: .acquiring)
                        XCTAssertFalse(set.contains(result), "Duplicate processing detected")
                        set.insert(result)
                        processedIds.store(set, ordering: .releasing)
                        lock.unlock()
                    }
                }
            }
        }
        
        let finalSet = processedIds.load(ordering: .acquiring)
        XCTAssertEqual(finalSet.count, 100)
    }
    
    func testMemoryOrdering() async throws {
        let queue = SafeLockFreeQueue<Int>()
        let flag = ManagedAtomic<Bool>(false)
        let value = ManagedAtomic<Int>(0)
        
        // Producer
        let producer = Task {
            value.store(42, ordering: .relaxed)
            flag.store(true, ordering: .releasing)
            queue.enqueue(1)
        }
        
        // Consumer
        let consumer = Task {
            while !flag.load(ordering: .acquiring) {
                await Task.yield()
            }
            let readValue = value.load(ordering: .relaxed)
            XCTAssertEqual(readValue, 42, "Memory ordering violation")
        }
        
        await producer.value
        await consumer.value
    }
    
    func testABAProtection() async throws {
        let queue = SafeLockFreeQueue<String>()
        
        // Simulate ABA scenario
        await withTaskGroup(of: Void.self) { group in
            // Thread 1: Enqueue A, Dequeue, Enqueue A
            group.addTask {
                queue.enqueue("A")
                try? await Task.sleep(nanoseconds: 1_000)
                _ = queue.dequeue()
                queue.enqueue("A")
            }
            
            // Thread 2: Try to dequeue
            group.addTask {
                try? await Task.sleep(nanoseconds: 500)
                let value = queue.dequeue()
                XCTAssertNotNil(value)
            }
        }
        
        // Verify final state
        let remaining = queue.dequeue()
        XCTAssertTrue(remaining == "A" || remaining == nil)
    }
    */
}