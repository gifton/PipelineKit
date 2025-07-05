import XCTest
import PipelineKit

final class BackPressureBenchmarks: XCTestCase {
    
    // MARK: - BackPressureAsyncSemaphore Benchmarks
    
    func testSemaphoreAcquisitionPerformance() async throws {
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 100,
            maxOutstanding: 1000,
            strategy: .suspend
        )
        
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let expectation = self.expectation(description: "Semaphore acquisition")
            
            Task {
                // Acquire and release tokens rapidly
                for _ in 0..<10000 {
                    let token = try await semaphore.acquire()
                    // Immediately release by letting token go out of scope
                    _ = token
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 30)
        }
    }
    
    func testSemaphoreUnderPressure() async throws {
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 10,
            maxOutstanding: 100,
            maxQueueMemory: 10 * 1024 * 1024, // 10MB
            strategy: .suspend
        )
        
        let memoryMetrics = await BenchmarkUtilities.measureMemory(iterations: 5) {
            // Create many concurrent tasks that will queue
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<1000 {
                    group.addTask {
                        do {
                            let token = try await semaphore.acquire(
                                estimatedSize: 1024 // 1KB per operation
                            )
                            // Simulate work
                            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
                            _ = token
                        } catch {
                            // Expected under pressure
                        }
                    }
                }
                
                // Wait for some to complete
                for _ in 0..<100 {
                    await group.next()
                }
                
                // Cancel rest to clean up
                group.cancelAll()
            }
        }
        
        print("Semaphore under pressure:")
        print(memoryMetrics)
    }
    
    func testSemaphoreStatisticsOverhead() async throws {
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 50,
            maxOutstanding: 500
        )
        
        // Pre-populate with some load
        var tokens: [SemaphoreToken] = []
        for _ in 0..<25 {
            tokens.append(try await semaphore.acquire())
        }
        
        // Measure stats collection overhead
        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "Stats collection")
            
            Task {
                for _ in 0..<10000 {
                    _ = await semaphore.getStats()
                    _ = await semaphore.healthCheck()
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10)
        }
        
        // Clean up tokens
        tokens.removeAll()
    }
    
    // MARK: - Pipeline Back-Pressure Scenarios
    
    func testPipelineBackPressureDropStrategy() async throws {
        let options = PipelineOptions(
            maxConcurrency: 5,
            maxOutstanding: 10,
            backPressureStrategy: .dropNewest
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = BenchmarkHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        
        await pipeline.register(BenchmarkCommand.self, pipeline: standardPipeline)
        
        var successCount = 0
        var dropCount = 0
        
        // Flood the pipeline
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<100 {
                group.addTask {
                    do {
                        _ = try await pipeline.execute(
                            BenchmarkCommand(payload: "flood-\(i)"),
                            context: CommandContext()
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            
            for await success in group {
                if success {
                    successCount += 1
                } else {
                    dropCount += 1
                }
            }
        }
        
        print("Back-pressure drop strategy: \(successCount) succeeded, \(dropCount) dropped")
        XCTAssertGreaterThan(dropCount, 0, "Should have dropped some commands under pressure")
    }
    
    func testPipelineMemoryPressure() async throws {
        let options = PipelineOptions(
            maxConcurrency: 10,
            maxOutstanding: 1000,
            maxQueueMemory: 50 * 1024 * 1024, // 50MB limit
            backPressureStrategy: .suspend
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = MemoryIntensiveHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        
        await pipeline.register(MemoryIntensiveCommand.self, pipeline: standardPipeline)
        
        let startMemory = BenchmarkUtilities.getCurrentMemoryUsage()
        
        // Create memory pressure with large commands
        let commands = (0..<100).map { _ in
            MemoryIntensiveCommand(size: 512 * 1024) // 512KB each
        }
        
        let results = try await pipeline.executeConcurrently(commands)
        
        let endMemory = BenchmarkUtilities.getCurrentMemoryUsage()
        let memoryIncrease = endMemory - startMemory
        
        print("Memory pressure test:")
        print("  Commands: \(commands.count)")
        print("  Memory increase: \(ByteCountFormatter.string(fromByteCount: Int64(memoryIncrease), countStyle: .binary))")
        print("  Success rate: \(results.filter { $0.isSuccess }.count)/\(commands.count)")
        
        // Should stay within reasonable memory bounds
        let memoryIncreaseMB = Double(memoryIncrease) / (1024 * 1024)
        XCTAssertLessThan(memoryIncreaseMB, 100, "Memory increase should be less than 100MB")
    }
    
    // MARK: - Stress Tests
    
    func testHighConcurrencyStress() async throws {
        let options = PipelineOptions(
            maxConcurrency: 100,
            maxOutstanding: 10000,
            backPressureStrategy: .suspend
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = BenchmarkHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        
        await pipeline.register(BenchmarkCommand.self, pipeline: standardPipeline)
        
        let operationCount = 10000
        let startTime = Date()
        
        // Execute many operations concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<operationCount {
                group.addTask {
                    _ = try? await pipeline.execute(
                        BenchmarkCommand(payload: "stress-\(i)"),
                        context: CommandContext()
                    )
                }
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        let throughput = Double(operationCount) / duration
        
        print("High concurrency stress test:")
        print("  Operations: \(operationCount)")
        print("  Duration: \(String(format: "%.2f", duration))s")
        print("  Throughput: \(String(format: "%.0f", throughput)) ops/sec")
        
        // Get final stats
        let stats = await pipeline.getCapacityStats()
        print("  Final stats: \(stats)")
    }
    
    func testSustainedLoadMemoryStability() async throws {
        let options = PipelineOptions(
            maxConcurrency: 20,
            maxOutstanding: 100,
            backPressureStrategy: .suspend
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = BenchmarkHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        
        await pipeline.register(BenchmarkCommand.self, pipeline: standardPipeline)
        
        var memorySnapshots: [UInt64] = []
        let duration: TimeInterval = 10 // 10 seconds of sustained load
        let startTime = Date()
        
        // Monitor memory while applying sustained load
        await withTaskGroup(of: Void.self) { group in
            // Load generator
            group.addTask {
                while Date().timeIntervalSince(startTime) < duration {
                    _ = try? await pipeline.execute(
                        BenchmarkCommand(payload: "sustained"),
                        context: CommandContext()
                    )
                }
            }
            
            // Memory monitor
            group.addTask {
                while Date().timeIntervalSince(startTime) < duration {
                    memorySnapshots.append(BenchmarkUtilities.getCurrentMemoryUsage())
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
        }
        
        // Analyze memory stability
        let stats = BenchmarkUtilities.summarize(memorySnapshots.map { Double($0) })
        let memoryVariance = stats.standardDeviation / stats.mean
        
        print("Sustained load memory stability:")
        print("  Duration: \(duration)s")
        print("  Memory snapshots: \(memorySnapshots.count)")
        print("  Mean memory: \(ByteCountFormatter.string(fromByteCount: Int64(stats.mean), countStyle: .binary))")
        print("  Memory variance: \(String(format: "%.2f%%", memoryVariance * 100))")
        
        // Memory should remain relatively stable
        XCTAssertLessThan(memoryVariance, 0.2, "Memory variance should be less than 20%")
    }
}

// Result extension for success checking
private extension Result {
    var isSuccess: Bool {
        switch self {
        case .success:
            return true
        case .failure:
            return false
        }
    }
}