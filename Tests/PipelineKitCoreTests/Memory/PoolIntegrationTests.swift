import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

/// Integration tests for object pool system
final class PoolIntegrationTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    class TestResource: Sendable {
        let id = UUID()
        let size: Int
        
        init(size: Int = 1024) {
            self.size = size
        }
    }
    
    // MARK: - Multi-Pool Scenarios
    
    func testMultiplePoolsWithDifferentConfigurations() async {
        // Given - Various pool configurations
        let smallPool = ObjectPool<TestResource>(
            name: "small-pool",
            configuration: ObjectPoolConfiguration(maxSize: 10, trackStatistics: true),
            factory: { TestResource(size: 100) },
            registerMetrics: true
        )
        
        let mediumPool = ObjectPool<TestResource>(
            name: "medium-pool",
            configuration: ObjectPoolConfiguration(maxSize: 50, trackStatistics: true),
            factory: { TestResource(size: 1024) },
            registerMetrics: true
        )
        
        let largePool = ObjectPool<TestResource>(
            name: "large-pool",
            configuration: ObjectPoolConfiguration(maxSize: 200, trackStatistics: true),
            factory: { TestResource(size: 10240) },
            registerMetrics: true
        )
        
        // Pre-allocate different amounts
        await smallPool.preallocate(count: 8)
        await mediumPool.preallocate(count: 30)
        await largePool.preallocate(count: 100)
        
        // Wait for registration
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // When - Get aggregated statistics
        let aggregated = await PoolRegistry.shared.getAggregatedStatistics()
        
        // Then - Verify all pools are tracked
        XCTAssertGreaterThanOrEqual(aggregated.activePoolCount, 3)
        XCTAssertGreaterThan(aggregated.totalAllocated, 0)
        
        // Test individual pool statistics
        let allStats = await PoolRegistry.shared.getAllStatistics()
        let smallStats = allStats.first { $0.name == "small-pool" }?.stats
        let mediumStats = allStats.first { $0.name == "medium-pool" }?.stats
        let largeStats = allStats.first { $0.name == "large-pool" }?.stats
        
        XCTAssertNotNil(smallStats)
        XCTAssertNotNil(mediumStats)
        XCTAssertNotNil(largeStats)
        
        XCTAssertEqual(smallStats?.currentlyAvailable, 8)
        XCTAssertEqual(mediumStats?.currentlyAvailable, 30)
        XCTAssertEqual(largeStats?.currentlyAvailable, 100)
    }
    
    func testMemoryPressureCascadeEffect() async {
        // Given - Multiple active pools
        var pools: [ObjectPool<TestResource>] = []
        
        for i in 0..<10 {
            let pool = ObjectPool<TestResource>(
                name: "cascade-pool-\(i)",
                configuration: ObjectPoolConfiguration(maxSize: 100, trackStatistics: true),
                factory: { TestResource() },
                registerMetrics: true
            )
            await pool.preallocate(count: 50)
            pools.append(pool)
        }
        
        // Wait for registration
        try? await Task.sleep(nanoseconds: 200_000_000)
        
        // When - Simulate warning pressure
        await PoolRegistry.shared.shrinkAllPools(toPercentage: 0.5)
        
        // Then - All pools should be affected
        for pool in pools {
            let stats = await pool.statistics
            XCTAssertLessThanOrEqual(stats.currentlyAvailable, 50, "Pool should shrink to 50% of max")
            XCTAssertGreaterThan(stats.evictions, 0, "Should track evictions")
        }
        
        // When - Simulate critical pressure
        await PoolRegistry.shared.shrinkAllPools(toPercentage: 0.0)
        
        // Then - All pools should be empty
        for pool in pools {
            let stats = await pool.statistics
            XCTAssertEqual(stats.currentlyAvailable, 0, "Pool should be empty under critical pressure")
        }
    }
    
    // MARK: - Metrics Collector Integration
    
    func testMetricsCollectorWithMultiplePools() async {
        // Given
        let collector = PoolMetricsCollector(
            collectionInterval: 0.5, // Faster for testing
            maxHistorySize: 10
        )
        
        // Create pools with activity
        let activePool = ObjectPool<TestResource>(
            name: "active-pool",
            configuration: ObjectPoolConfiguration(maxSize: 50, trackStatistics: true),
            factory: { TestResource() },
            registerMetrics: true
        )
        
        let idlePool = ObjectPool<TestResource>(
            name: "idle-pool",
            configuration: ObjectPoolConfiguration(maxSize: 50, trackStatistics: true),
            factory: { TestResource() },
            registerMetrics: true
        )
        
        await activePool.preallocate(count: 25)
        await idlePool.preallocate(count: 10)
        
        // Start collecting
        await collector.startCollecting()
        
        // Simulate activity on active pool
        for _ in 0..<20 {
            let obj = await activePool.acquire()
            await activePool.release(obj)
        }
        
        // Wait for collection
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // When - Get snapshot
        let snapshot = await collector.currentSnapshot()
        
        // Then - Verify metrics
        XCTAssertGreaterThanOrEqual(snapshot.poolStatistics.count, 2)
        XCTAssertGreaterThan(snapshot.overallHitRate, 0)
        XCTAssertGreaterThan(snapshot.currentMemoryUsage, 0)
        
        // Check history is building
        let history = await collector.history
        XCTAssertGreaterThan(history.count, 0)
        
        // Cleanup
        await collector.stopCollecting()
    }
    
    // MARK: - Real Memory Allocation Patterns
    
    func testRealisticMemoryAllocationPatterns() async {
        // Given - Pool with real memory allocations
        class MemoryBuffer: Sendable {
            let data: UnsafeMutableRawPointer
            let size: Int
            
            init(size: Int) {
                self.size = size
                self.data = UnsafeMutableRawPointer.allocate(
                    byteCount: size,
                    alignment: MemoryLayout<UInt8>.alignment
                )
                // Initialize memory to ensure allocation
                self.data.initializeMemory(as: UInt8.self, repeating: 0, count: size)
            }
            
            deinit {
                data.deallocate()
            }
        }
        
        let bufferPool = ObjectPool<MemoryBuffer>(
            name: "buffer-pool",
            configuration: ObjectPoolConfiguration(maxSize: 100, trackStatistics: true),
            factory: { MemoryBuffer(size: 4096) }, // 4KB buffers
            reset: { buffer in
                // Clear buffer on reuse
                buffer.data.initializeMemory(as: UInt8.self, repeating: 0, count: buffer.size)
            },
            registerMetrics: true
        )
        
        // Pre-allocate to build pool
        await bufferPool.preallocate(count: 50)
        
        // When - Simulate usage pattern
        var acquiredBuffers: [MemoryBuffer] = []
        
        // Acquire batch
        for _ in 0..<30 {
            acquiredBuffers.append(await bufferPool.acquire())
        }
        
        let statsAfterAcquire = await bufferPool.statistics
        XCTAssertEqual(statsAfterAcquire.currentlyInUse, 30)
        XCTAssertEqual(statsAfterAcquire.currentlyAvailable, 20)
        
        // Release half
        for i in 0..<15 {
            await bufferPool.release(acquiredBuffers[i])
        }
        
        let statsAfterPartialRelease = await bufferPool.statistics
        XCTAssertEqual(statsAfterPartialRelease.currentlyInUse, 15)
        XCTAssertEqual(statsAfterPartialRelease.currentlyAvailable, 35)
        
        // Shrink pool
        await bufferPool.shrink(to: 20)
        
        let statsAfterShrink = await bufferPool.statistics
        XCTAssertEqual(statsAfterShrink.currentlyAvailable, 20)
        XCTAssertGreaterThan(statsAfterShrink.evictions, 0)
        
        // Release remaining
        for i in 15..<30 {
            await bufferPool.release(acquiredBuffers[i])
        }
        
        // Verify final state
        let finalStats = await bufferPool.statistics
        XCTAssertEqual(finalStats.currentlyInUse, 0)
        XCTAssertLessThanOrEqual(finalStats.currentlyAvailable, 20)
    }
    
    // MARK: - Recovery Scenarios
    
    func testRecoveryAfterMemoryPressure() async {
        // Given - Pool under pressure
        let pool = ObjectPool<TestResource>(
            name: "recovery-pool",
            configuration: ObjectPoolConfiguration(maxSize: 100, trackStatistics: true),
            factory: { TestResource() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 80)
        let initialStats = await pool.statistics
        
        // When - Apply pressure then recover
        await pool.shrink(to: 10)
        let pressureStats = await pool.statistics
        XCTAssertEqual(pressureStats.currentlyAvailable, 10)
        
        // Simulate recovery - acquire/release cycle
        var objects: [TestResource] = []
        for _ in 0..<50 {
            objects.append(await pool.acquire())
        }
        
        let duringRecoveryStats = await pool.statistics
        XCTAssertGreaterThan(duringRecoveryStats.totalAllocated, initialStats.totalAllocated)
        
        for obj in objects {
            await pool.release(obj)
        }
        
        // Then - Pool should rebuild
        let recoveredStats = await pool.statistics
        XCTAssertGreaterThan(recoveredStats.currentlyAvailable, pressureStats.currentlyAvailable)
        XCTAssertLessThanOrEqual(recoveredStats.currentlyAvailable, 100)
    }
    
    // MARK: - Concurrent Operations
    
    func testConcurrentPoolOperations() async {
        // Given
        let pool = ObjectPool<TestResource>(
            name: "concurrent-pool",
            configuration: ObjectPoolConfiguration(maxSize: 200, trackStatistics: true),
            factory: { TestResource() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 100)
        
        // When - Perform concurrent operations
        await withTaskGroup(of: Void.self) { group in
            // Acquirers
            for i in 0..<50 {
                group.addTask {
                    let obj = await pool.acquire()
                    // Simulate work
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...10_000_000))
                    await pool.release(obj)
                }
            }
            
            // Shrinkers
            for _ in 0..<5 {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 5_000_000...15_000_000))
                    await pool.shrink(to: Int.random(in: 50...150))
                }
            }
            
            // Statistics readers
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<10 {
                        _ = await pool.statistics
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                }
            }
        }
        
        // Then - Pool should remain consistent
        let finalStats = await pool.statistics
        XCTAssertGreaterThanOrEqual(finalStats.currentlyAvailable, 0)
        XCTAssertLessThanOrEqual(finalStats.currentlyAvailable, 200)
        XCTAssertEqual(finalStats.currentlyInUse, 0, "All objects should be released")
    }
}