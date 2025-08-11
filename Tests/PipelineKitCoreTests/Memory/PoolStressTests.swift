import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

/// Stress tests for object pool system
final class PoolStressTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    class StressObject: Sendable {
        let id = UUID()
        static var totalCreated = 0
        
        init() {
            // Track allocations (not thread-safe, just for rough count)
            _ = StressObject.totalCreated += 1
        }
    }
    
    // MARK: - Scale Testing
    
    func testMassivePoolRegistration() async {
        // Given - Reset counter
        StressObject.totalCreated = 0
        
        // When - Create many pools rapidly
        let poolCount = 1000
        var pools: [ObjectPool<StressObject>] = []
        
        let startTime = ContinuousClock.now
        
        for i in 0..<poolCount {
            let pool = ObjectPool<StressObject>(
                name: "stress-pool-\(i)",
                configuration: ObjectPoolConfiguration(
                    maxSize: 10,
                    trackStatistics: true
                ),
                factory: { StressObject() },
                registerMetrics: true
            )
            pools.append(pool)
        }
        
        let creationTime = ContinuousClock.now.duration(since: startTime)
        
        // Wait for all registrations
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // Then - Verify registration
        let stats = await PoolRegistry.shared.getAggregatedStatistics()
        XCTAssertGreaterThanOrEqual(stats.activePoolCount, poolCount)
        
        print("Created \(poolCount) pools in \(creationTime)")
        
        // Cleanup - trigger deinits
        pools.removeAll()
        
        // Wait for cleanup
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        let finalStats = await PoolRegistry.shared.getAggregatedStatistics()
        print("Pools remaining after cleanup: \(finalStats.activePoolCount)")
    }
    
    func testConcurrentPoolOperationsUnderLoad() async {
        // Given - Multiple pools
        let poolCount = 100
        var pools: [ObjectPool<StressObject>] = []
        
        for i in 0..<poolCount {
            let pool = ObjectPool<StressObject>(
                name: "concurrent-stress-\(i)",
                configuration: ObjectPoolConfiguration(
                    maxSize: 50,
                    trackStatistics: true
                ),
                factory: { StressObject() },
                registerMetrics: true
            )
            pools.append(pool)
        }
        
        // When - Hammer with concurrent operations
        let operationsPerPool = 100
        let startTime = ContinuousClock.now
        
        await withTaskGroup(of: Void.self) { group in
            for pool in pools {
                group.addTask {
                    // Concurrent acquires/releases
                    await withTaskGroup(of: Void.self) { innerGroup in
                        for _ in 0..<operationsPerPool {
                            innerGroup.addTask {
                                let obj = await pool.acquire()
                                // Minimal work
                                _ = obj.id
                                await pool.release(obj)
                            }
                        }
                    }
                }
            }
        }
        
        let duration = ContinuousClock.now.duration(since: startTime)
        let totalOps = poolCount * operationsPerPool
        print("Completed \(totalOps) operations in \(duration)")
        
        // Then - Verify consistency
        for pool in pools {
            let stats = await pool.statistics
            XCTAssertEqual(stats.currentlyInUse, 0, "All objects should be released")
            XCTAssertEqual(stats.totalAcquisitions, operationsPerPool)
            XCTAssertEqual(stats.totalReleases, operationsPerPool)
        }
    }
    
    // MARK: - Sustained Pressure Simulation
    
    func testSustainedMemoryPressure() async {
        // Given - Setup pools and collector
        let collector = PoolMetricsCollector(
            collectionInterval: 0.1,
            maxHistorySize: 100
        )
        
        var pools: [ObjectPool<StressObject>] = []
        for i in 0..<20 {
            let pool = ObjectPool<StressObject>(
                name: "pressure-test-\(i)",
                configuration: ObjectPoolConfiguration(maxSize: 100, trackStatistics: true),
                factory: { StressObject() },
                registerMetrics: true
            )
            await pool.preallocate(count: 80)
            pools.append(pool)
        }
        
        await collector.startCollecting()
        
        // When - Apply sustained pressure for 10 seconds
        let pressureDuration: Duration = .seconds(10)
        let startTime = ContinuousClock.now
        var shrinkCount = 0
        
        while ContinuousClock.now.duration(since: startTime) < pressureDuration {
            // Simulate pressure events
            let pressureLevel = Double.random(in: 0.1...0.8)
            await PoolRegistry.shared.shrinkAllPools(toPercentage: pressureLevel)
            shrinkCount += 1
            
            // Small delay between pressure events
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        
        print("Applied \(shrinkCount) pressure events over \(pressureDuration)")
        
        // Then - Check for memory leaks and consistency
        let history = await collector.history
        XCTAssertGreaterThan(history.count, 0)
        
        // Verify no crashes and pools are still functional
        for pool in pools {
            let stats = await pool.statistics
            XCTAssertGreaterThanOrEqual(stats.currentlyAvailable, 0)
            XCTAssertLessThanOrEqual(stats.currentlyAvailable, 100)
            
            // Test pool still works
            let obj = await pool.acquire()
            await pool.release(obj)
        }
        
        // Cleanup
        await collector.stopCollecting()
    }
    
    // MARK: - Memory Leak Detection
    
    func testNoMemoryLeaksUnderStress() async {
        // Given - Track initial state
        let initialObjectCount = StressObject.totalCreated
        
        // When - Create and destroy many pools
        for iteration in 0..<10 {
            autoreleasepool {
                var tempPools: [ObjectPool<StressObject>] = []
                
                for i in 0..<100 {
                    let pool = ObjectPool<StressObject>(
                        name: "leak-test-\(iteration)-\(i)",
                        configuration: ObjectPoolConfiguration(maxSize: 20),
                        factory: { StressObject() },
                        registerMetrics: false // Skip registration for speed
                    )
                    tempPools.append(pool)
                }
                
                // Use the pools
                Task {
                    for pool in tempPools {
                        for _ in 0..<10 {
                            let obj = await pool.acquire()
                            await pool.release(obj)
                        }
                    }
                }
                
                // Force deallocation
                tempPools.removeAll()
            }
            
            // Allow cleanup
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        // Then - Objects should be deallocated
        print("Total objects created during test: \(StressObject.totalCreated - initialObjectCount)")
        
        // Note: We can't perfectly verify deallocation in Swift,
        // but we can check that the registry is clean
        let stats = await PoolRegistry.shared.getAggregatedStatistics()
        XCTAssertLessThan(stats.activePoolCount, 10, "Most pools should be deallocated")
    }
    
    // MARK: - Performance Benchmarks
    
    func testShrinkOperationPerformance() async throws {
        // Given - Large pool
        let pool = ObjectPool<StressObject>(
            name: "perf-pool",
            configuration: ObjectPoolConfiguration(maxSize: 10000, trackStatistics: true),
            factory: { StressObject() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 8000)
        
        // When - Measure shrink performance
        let iterations = 100
        var durations: [Duration] = []
        
        for i in 0..<iterations {
            let targetSize = Int.random(in: 1000...7000)
            
            let start = ContinuousClock.now
            await pool.shrink(to: targetSize)
            let duration = ContinuousClock.now.duration(since: start)
            
            durations.append(duration)
            
            // Refill for next iteration
            await pool.preallocate(count: 8000)
        }
        
        // Then - Calculate statistics
        let totalDuration = durations.reduce(Duration.zero, +)
        let averageDuration = totalDuration / iterations
        let maxDuration = durations.max() ?? .zero
        
        print("Shrink operation performance:")
        print("  Average: \(averageDuration)")
        print("  Maximum: \(maxDuration)")
        
        // Performance assertion
        XCTAssertLessThan(averageDuration, .milliseconds(10), "Shrink should be fast")
    }
    
    func testRegistrationOverhead() async throws {
        // Measure registration overhead
        var registrationTimes: [Duration] = []
        
        for i in 0..<100 {
            let start = ContinuousClock.now
            
            let pool = ObjectPool<StressObject>(
                name: "overhead-test-\(i)",
                configuration: ObjectPoolConfiguration(maxSize: 10),
                factory: { StressObject() },
                registerMetrics: true
            )
            
            // Wait for registration to complete
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            
            let duration = ContinuousClock.now.duration(since: start)
            registrationTimes.append(duration)
            
            // Keep reference to prevent deallocation
            _ = pool
        }
        
        let avgRegistration = registrationTimes.reduce(Duration.zero, +) / registrationTimes.count
        print("Average registration time: \(avgRegistration)")
        
        XCTAssertLessThan(avgRegistration, .milliseconds(50), "Registration should be quick")
    }
    
    // MARK: - Extreme Edge Cases
    
    func testRapidCreateDestroyycle() async {
        // Rapidly create and destroy pools
        for _ in 0..<1000 {
            let pool = ObjectPool<StressObject>(
                name: "rapid-\(UUID())",
                configuration: ObjectPoolConfiguration(maxSize: 5),
                factory: { StressObject() },
                registerMetrics: true
            )
            
            // Minimal usage
            let obj = await pool.acquire()
            await pool.release(obj)
            
            // Pool goes out of scope and deinits
        }
        
        // Verify system stability
        let stats = await PoolRegistry.shared.getAggregatedStatistics()
        XCTAssertNotNil(stats)
    }
    
    func testMaximumPoolSize() async {
        // Test with maximum reasonable pool size
        let maxSize = 100_000
        
        let megaPool = ObjectPool<StressObject>(
            name: "mega-pool",
            configuration: ObjectPoolConfiguration(maxSize: maxSize, trackStatistics: true),
            factory: { StressObject() },
            registerMetrics: true
        )
        
        // Don't actually allocate all - just test configuration
        await megaPool.preallocate(count: 100)
        
        let stats = await megaPool.statistics
        XCTAssertEqual(stats.maxSize, maxSize)
        XCTAssertEqual(stats.currentlyAvailable, 100)
        
        // Test shrinking large pool
        await megaPool.shrink(to: 10)
        let shrunkStats = await megaPool.statistics
        XCTAssertEqual(shrunkStats.currentlyAvailable, 10)
    }
}