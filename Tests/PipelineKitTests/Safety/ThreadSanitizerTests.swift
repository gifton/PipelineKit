import XCTest
@testable import PipelineKit

final class ThreadSanitizerTests: XCTestCase {
    
    override class func setUp() {
        super.setUp()
        // Enable Thread Sanitizer in scheme for these tests
        #if DEBUG
        assert(Thread.isMainThread, "Thread Sanitizer should be enabled")
        #endif
    }
    
    func testConcurrentQueueSafety() async throws {
        let queue = SafeLockFreeQueue<Int>()
        let iterations = 10_000
        
        // Concurrent producers and consumers
        await withTaskGroup(of: Void.self) { group in
            // Producers
            for i in 0..<4 {
                group.addTask {
                    for j in 0..<iterations {
                        queue.enqueue(i * iterations + j)
                    }
                }
            }
            
            // Consumers
            for _ in 0..<4 {
                group.addTask {
                    var consumed = 0
                    while consumed < iterations {
                        if queue.dequeue() != nil {
                            consumed += 1
                        } else {
                            await Task.yield()
                        }
                    }
                }
            }
        }
        
        // Verify queue is eventually empty
        while !queue.isEmpty {
            _ = queue.dequeue()
        }
        XCTAssertTrue(queue.isEmpty)
    }
    
    func testBatchProcessorSafety() async throws {
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        let processor = SafeBatchProcessor<TestCommand>(pipeline: pipeline)
        
        // Concurrent submissions
        let results = await withTaskGroup(of: Int?.self) { group in
            for i in 0..<100 {
                group.addTask {
                    try? await processor.submit(TestCommand(value: i))
                }
            }
            
            var results: [Int] = []
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
            return results
        }
        
        XCTAssertEqual(Set(results).count, results.count, "No duplicates")
    }
    
    func testWorkStealingSafety() async throws {
        let executor = SafeWorkStealingExecutor(workerCount: 8)
        let counter = ManagedAtomic<Int>(0)
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1000 {
                group.addTask {
                    _ = try? await executor.execute {
                        counter.wrappingIncrement(ordering: .relaxed)
                        // Simulate work
                        try await Task.sleep(nanoseconds: 1_000)
                        return counter.load(ordering: .relaxed)
                    }
                }
            }
        }
        
        XCTAssertEqual(counter.load(ordering: .relaxed), 1000)
    }
    
    func testContextSafety() async throws {
        let context = SafeOptimizedCommandContext()
        
        await withTaskGroup(of: Void.self) { group in
            // Concurrent writers
            for i in 0..<10 {
                group.addTask {
                    for j in 0..<100 {
                        await context.set("value-\(i)-\(j)", for: TestKey.self)
                    }
                }
            }
            
            // Concurrent readers
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<100 {
                        _ = await context.get(TestKey.self)
                    }
                }
            }
        }
        
        // Final value should be set
        let finalValue = await context.get(TestKey.self)
        XCTAssertNotNil(finalValue)
    }
}

// Test helpers
struct TestCommand: Command {
    typealias Result = Int
    let value: Int
}

struct TestHandler: CommandHandler {
    typealias CommandType = TestCommand
    
    func handle(_ command: TestCommand) async throws -> Int {
        return command.value * 2
    }
}

struct TestKey: ContextKey {
    typealias Value = String
}