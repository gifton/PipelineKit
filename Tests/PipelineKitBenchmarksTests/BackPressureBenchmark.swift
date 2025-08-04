import XCTest
import Foundation
import Atomics
@testable import PipelineKit

/// Benchmarks for BackPressureAsyncSemaphore optimizations
/// 
/// These tests validate the performance improvements from Phase 2 atomic optimizations:
/// - Atomic fast-path acquire/release
/// - Zero actor hops for uncontended operations
/// - Efficient token management with atomics
final class BackPressureBenchmarkTests: XCTestCase {
    
    func testPriorityQueuePerformance() async throws {
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 10,
            cleanupInterval: 10.0 // Long interval to avoid cleanup during test
        )
        
        let iterations = 10_000
        let priorities: [BackPressureAsyncSemaphore.QueuePriority] = [.low, .normal, .high, .critical]
        
        let start = CFAbsoluteTimeGetCurrent()
        
        // Create many waiters with different priorities
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                let priority = priorities[i % priorities.count]
                group.addTask {
                    do {
                        let token = try await semaphore.acquire(priority: priority)
                        // Token will auto-release when it goes out of scope
                        _ = token
                    } catch {
                        // Ignore cancellation errors in benchmark
                    }
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        let opsPerSecond = Double(iterations) / duration
        
        print("""
        === BackPressureAsyncSemaphore Priority Queue Performance ===
        Operations: \(iterations)
        Duration: \(String(format: "%.3f", duration))s
        Throughput: \(String(format: "%.1f", opsPerSecond / 1000))K ops/sec
        Average per-operation: \(String(format: "%.1f", (duration / Double(iterations)) * 1_000_000))μs
        """)
        
        XCTAssertGreaterThan(opsPerSecond, 1000, "Should handle at least 1K ops/sec")
    }
    
    func testTryAcquirePerformance() async throws {
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 100)
        let iterations = 100_000
        
        let start = CFAbsoluteTimeGetCurrent()
        
        var successCount = 0
        var failureCount = 0
        
        for _ in 0..<iterations {
            if let token = await semaphore.tryAcquire() {
                successCount += 1
                // Token auto-releases when out of scope
                _ = token
            } else {
                failureCount += 1
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        let opsPerSecond = Double(iterations) / duration
        
        print("""
        === tryAcquire Performance ===
        Operations: \(iterations)
        Duration: \(String(format: "%.3f", duration))s
        Throughput: \(String(format: "%.1f", opsPerSecond / 1000))K ops/sec
        Average per-operation: \(String(format: "%.1f", (duration / Double(iterations)) * 1_000_000_000))ns
        Success rate: \(String(format: "%.1f", Double(successCount) / Double(iterations) * 100))%
        """)
        
        XCTAssertGreaterThan(opsPerSecond, 10_000, "Should handle at least 10K tryAcquire ops/sec")
    }
    
    func testCancellationPerformance() async throws {
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 1)
        let iterations = 1_000
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            // First task holds the semaphore
            group.addTask {
                do {
                    let token = try await semaphore.acquire()
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    _ = token
                } catch {
                    // Ignore
                }
            }
            
            // Let first task acquire
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            
            // Create many tasks that will be cancelled
            for _ in 0..<iterations {
                group.addTask {
                    do {
                        let token = try await semaphore.acquire()
                        _ = token
                    } catch {
                        // Expected cancellation
                    }
                }
            }
            
            // Let them queue up
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            
            // Cancel all
            group.cancelAll()
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        
        print("""
        === Cancellation Performance ===
        Cancelled tasks: \(iterations)
        Total duration: \(String(format: "%.3f", duration))s
        Average cancellation handling: \(String(format: "%.1f", (duration / Double(iterations)) * 1_000_000))μs per task
        """)
        
        // Verify cleanup worked
        let stats = await semaphore.getStats()
        XCTAssertEqual(stats.queuedOperations, 0, "All waiters should be cleaned up")
    }
    
    func testHighContentionScenario() async throws {
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 5)
        let concurrentTasks = 100
        let operationsPerTask = 100
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrentTasks {
                group.addTask {
                    for _ in 0..<operationsPerTask {
                        do {
                            let token = try await semaphore.acquire()
                            // Simulate some work
                            await Task.yield()
                            _ = token
                        } catch {
                            // Ignore errors
                        }
                    }
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        let totalOps = concurrentTasks * operationsPerTask
        let opsPerSecond = Double(totalOps) / duration
        
        print("""
        === High Contention Scenario ===
        Concurrent tasks: \(concurrentTasks)
        Operations per task: \(operationsPerTask)
        Total operations: \(totalOps)
        Duration: \(String(format: "%.3f", duration))s
        Throughput: \(String(format: "%.1f", opsPerSecond / 1000))K ops/sec
        """)
        
        XCTAssertLessThan(duration, 10.0, "Should complete high contention scenario in under 10 seconds")
    }
    
    // MARK: - Phase 2 Atomic Optimization Benchmarks
    
    func testUncontendedFastPath() async throws {
        // Tests the atomic fast-path with no contention
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 1000)
        let iterations = 1_000_000
        
        let start = CFAbsoluteTimeGetCurrent()
        
        for _ in 0..<iterations {
            let token = try await semaphore.acquire()
            token.release() // Immediate release
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        let opsPerSecond = Double(iterations) / duration
        let nsPerOp = (duration / Double(iterations)) * 1_000_000_000
        
        print("""
        === Uncontended Fast Path (Atomic) ===
        Operations: \(iterations)
        Duration: \(String(format: "%.3f", duration))s
        Throughput: \(String(format: "%.1f", opsPerSecond / 1_000_000))M ops/sec
        Average per-operation: \(String(format: "%.1f", nsPerOp))ns
        """)
        
        // With atomics, we expect sub-microsecond operations
        XCTAssertLessThan(nsPerOp, 1000, "Uncontended operations should be under 1μs")
        XCTAssertGreaterThan(opsPerSecond, 100_000, "Should handle at least 100K uncontended ops/sec")
    }
    
    func testMildContention() async throws {
        // 50% of operations should go through fast path
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 50)
        let concurrentTasks = 100
        let operationsPerTask = 1000
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrentTasks {
                group.addTask {
                    for _ in 0..<operationsPerTask {
                        do {
                            let token = try await semaphore.acquire()
                            // Minimal work to maintain mild contention
                            _ = token
                        } catch {
                            // Ignore
                        }
                    }
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        let totalOps = concurrentTasks * operationsPerTask
        let opsPerSecond = Double(totalOps) / duration
        
        print("""
        === Mild Contention (50% suspension rate) ===
        Concurrent tasks: \(concurrentTasks)
        Total operations: \(totalOps)
        Duration: \(String(format: "%.3f", duration))s
        Throughput: \(String(format: "%.1f", opsPerSecond / 1000))K ops/sec
        Average per-operation: \(String(format: "%.1f", (duration / Double(totalOps)) * 1_000_000))μs
        """)
        
        // Should see 3-5x improvement under mild contention
        XCTAssertGreaterThan(opsPerSecond, 50_000, "Should handle at least 50K ops/sec under mild contention")
    }
    
    func testHeavyContention() async throws {
        // 95% of operations should queue
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 2)
        let concurrentTasks = 40
        let operationsPerTask = 250
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrentTasks {
                group.addTask {
                    for _ in 0..<operationsPerTask {
                        do {
                            let token = try await semaphore.acquire()
                            // Simulate work to maintain contention
                            await Task.yield()
                            _ = token
                        } catch {
                            // Ignore
                        }
                    }
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        let totalOps = concurrentTasks * operationsPerTask
        let opsPerSecond = Double(totalOps) / duration
        
        print("""
        === Heavy Contention (95% suspension rate) ===
        Concurrent tasks: \(concurrentTasks)
        Total operations: \(totalOps)
        Duration: \(String(format: "%.3f", duration))s
        Throughput: \(String(format: "%.1f", opsPerSecond / 1000))K ops/sec
        """)
        
        XCTAssertGreaterThan(opsPerSecond, 5_000, "Should handle at least 5K ops/sec under heavy contention")
    }
    
    func testPingPongFairness() async throws {
        // Tests fairness between two threads competing for resources
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 2)
        let iterations = 10_000
        
        let counter1 = ManagedAtomic<Int>(0)
        let counter2 = ManagedAtomic<Int>(0)
        
        let start = CFAbsoluteTimeGetCurrent()
        
        await withTaskGroup(of: Void.self) { group in
            // Task 1
            group.addTask {
                for _ in 0..<iterations {
                    do {
                        let token = try await semaphore.acquire()
                        counter1.loadThenWrappingIncrement(ordering: .relaxed)
                        await Task.yield()
                        _ = token
                    } catch {
                        break
                    }
                }
            }
            
            // Task 2
            group.addTask {
                for _ in 0..<iterations {
                    do {
                        let token = try await semaphore.acquire()
                        counter2.loadThenWrappingIncrement(ordering: .relaxed)
                        await Task.yield()
                        _ = token
                    } catch {
                        break
                    }
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        let task1Count = counter1.load(ordering: .relaxed)
        let task2Count = counter2.load(ordering: .relaxed)
        let totalOps = task1Count + task2Count
        
        let fairnessRatio = Double(min(task1Count, task2Count)) / Double(max(task1Count, task2Count))
        
        print("""
        === Ping-Pong Fairness Test ===
        Total operations: \(totalOps)
        Task 1 acquisitions: \(task1Count)
        Task 2 acquisitions: \(task2Count)
        Fairness ratio: \(String(format: "%.2f", fairnessRatio))
        Duration: \(String(format: "%.3f", duration))s
        """)
        
        // With greedy CAS, we might see some unfairness
        XCTAssertGreaterThan(fairnessRatio, 0.3, "Fairness ratio should be reasonable (>0.3)")
    }
    
    func testMassCancellation() async throws {
        // Tests the performance of cancelling many waiters
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 1)
        let waitersToCancel = 10_000
        
        // First, acquire the only permit
        let blocker = try await semaphore.acquire()
        
        let start = CFAbsoluteTimeGetCurrent()
        
        // Create many waiting tasks
        let tasks = (0..<waitersToCancel).map { _ in
            Task {
                try await semaphore.acquire()
            }
        }
        
        // Let them queue up
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Mass cancellation
        let cancelStart = CFAbsoluteTimeGetCurrent()
        for task in tasks {
            task.cancel()
        }
        
        // Wait for cancellations to complete
        for task in tasks {
            _ = try? await task.value
        }
        
        let cancelDuration = CFAbsoluteTimeGetCurrent() - cancelStart
        let totalDuration = CFAbsoluteTimeGetCurrent() - start
        
        print("""
        === Mass Cancellation Performance ===
        Waiters cancelled: \(waitersToCancel)
        Cancellation duration: \(String(format: "%.3f", cancelDuration))s
        Total duration: \(String(format: "%.3f", totalDuration))s
        Cancellations per second: \(String(format: "%.1f", Double(waitersToCancel) / cancelDuration))
        Average per cancellation: \(String(format: "%.1f", (cancelDuration / Double(waitersToCancel)) * 1_000_000))μs
        """)
        
        // Release the blocker
        _ = blocker
        
        // Verify cleanup
        let stats = await semaphore.getStats()
        XCTAssertEqual(stats.queuedOperations, 0, "All cancelled waiters should be cleaned up")
        XCTAssertLessThan(cancelDuration, 1.0, "Should cancel 10K waiters in under 1 second")
    }
    
    func testMemoryPressureSimulation() async throws {
        // Tests performance under memory pressure
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 100,
            maxQueueMemory: 10_485_760 // 10MB
        )
        
        let start = CFAbsoluteTimeGetCurrent()
        var memoryLimitHits = 0
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    do {
                        // Vary size to simulate real workloads
                        let size = (i % 10 + 1) * 10_240 // 10KB to 100KB
                        let token = try await semaphore.acquire(estimatedSize: size)
                        await Task.yield()
                        _ = token
                    } catch PipelineError.backPressure(reason: .memoryPressure) {
                        memoryLimitHits += 1
                    } catch {
                        // Other errors
                    }
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        
        print("""
        === Memory Pressure Simulation ===
        Total attempts: 1000
        Memory limit hits: \(memoryLimitHits)
        Duration: \(String(format: "%.3f", duration))s
        """)
        
        XCTAssertGreaterThan(memoryLimitHits, 0, "Should hit memory limits in this scenario")
    }
}