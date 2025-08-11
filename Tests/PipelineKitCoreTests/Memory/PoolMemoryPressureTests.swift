import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

/// Tests for memory pressure handling in object pools
final class PoolMemoryPressureTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    class TestObject: Sendable {
        let id = UUID()
    }
    
    // MARK: - PoolRegistry Shrink Tests
    
    func testShrinkAllPoolsWithValidPercentage() async {
        // Given
        let pool1 = ObjectPool<TestObject>(
            name: "test-pool-1",
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        let pool2 = ObjectPool<TestObject>(
            name: "test-pool-2",
            configuration: ObjectPoolConfiguration(maxSize: 50),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // Pre-allocate objects
        await pool1.preallocate(count: 80)
        await pool2.preallocate(count: 40)
        
        // Wait for registration
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // When - Shrink to 50% of max size
        await PoolRegistry.shared.shrinkAllPools(toPercentage: 0.5)
        
        // Then
        let stats1 = await pool1.statistics
        let stats2 = await pool2.statistics
        
        // Should shrink to 50% of maxSize (not currentlyAvailable)
        XCTAssertLessThanOrEqual(stats1.currentlyAvailable, 50, "Pool1 should shrink to <= 50% of max (100)")
        XCTAssertLessThanOrEqual(stats2.currentlyAvailable, 25, "Pool2 should shrink to <= 50% of max (50)")
    }
    
    func testShrinkAllPoolsWithInvalidPercentage() async {
        // Given
        let pool = ObjectPool<TestObject>(
            name: "test-pool",
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 50)
        
        // Wait for registration
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // When - Try to shrink with invalid percentages
        await PoolRegistry.shared.shrinkAllPools(toPercentage: -0.5) // Should clamp to 0.0
        
        // Then
        var stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 0, "Negative percentage should clamp to 0")
        
        // Pre-allocate again
        await pool.preallocate(count: 50)
        
        // When - Try with percentage > 1.0
        await PoolRegistry.shared.shrinkAllPools(toPercentage: 2.0) // Should clamp to 1.0
        
        // Then
        stats = await pool.statistics
        XCTAssertGreaterThan(stats.currentlyAvailable, 0, "Percentage > 1.0 should clamp to 1.0 (no shrinking)")
    }
    
    func testShrinkSpecificPool() async {
        // Given
        let targetPoolName = "target-pool"
        let otherPoolName = "other-pool"
        
        let targetPool = ObjectPool<TestObject>(
            name: targetPoolName,
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        let otherPool = ObjectPool<TestObject>(
            name: otherPoolName,
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        await targetPool.preallocate(count: 50)
        await otherPool.preallocate(count: 50)
        
        // Wait for registration
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // When - Shrink only the target pool
        await PoolRegistry.shared.shrinkPool(name: targetPoolName, to: 10)
        
        // Then
        let targetStats = await targetPool.statistics
        let otherStats = await otherPool.statistics
        
        XCTAssertEqual(targetStats.currentlyAvailable, 10, "Target pool should be shrunk")
        XCTAssertEqual(otherStats.currentlyAvailable, 50, "Other pool should be unchanged")
    }
    
    func testShrinkPoolWithNegativeSize() async {
        // Given
        let pool = ObjectPool<TestObject>(
            name: "test-pool",
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 50)
        
        // When - Try to shrink with negative size
        await pool.shrink(to: -10)
        
        // Then
        let stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 0, "Negative size should clamp to 0")
    }
    
    // MARK: - PoolMetricsCollector Memory Pressure Tests
    
    func testPoolMetricsCollectorMemoryPressureHandling() async {
        // Given
        let collector = PoolMetricsCollector()
        let pool = ObjectPool<TestObject>(
            name: "pressure-test-pool",
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 80)
        
        // Start collection (registers for memory pressure)
        await collector.startCollecting()
        
        // Wait for setup
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // When - Get initial snapshot
        let initialSnapshot = await collector.currentSnapshot()
        
        // Then
        XCTAssertGreaterThanOrEqual(initialSnapshot.memoryPressureEvents, 0)
        XCTAssertGreaterThan(initialSnapshot.currentMemoryUsage, 0, "Should report memory usage")
        
        // Cleanup
        await collector.stopCollecting()
    }
    
    func testPoolMetricsCollectorCleanup() async {
        // Given
        let collector = PoolMetricsCollector()
        var exporterCalled = false
        
        // Register an exporter
        let exporterId = await collector.registerExporter { snapshot in
            exporterCalled = true
        }
        
        // Start collecting
        await collector.startCollecting()
        
        // When - Stop collecting
        await collector.stopCollecting()
        
        // Then - Verify cleanup
        let history = await collector.history
        XCTAssertTrue(history.isEmpty, "History should be cleared")
        
        // Try to use the collector again
        await collector.startCollecting()
        await collector.stopCollecting()
        
        // Should not crash
    }
    
    // MARK: - Statistics Tests
    
    func testObjectPoolStatisticsIncludesMaxSize() {
        // Given
        let stats = ObjectPoolStatistics(
            totalAllocated: 10,
            currentlyAvailable: 5,
            currentlyInUse: 2,
            maxSize: 100,
            totalAcquisitions: 12,
            totalReleases: 10,
            hits: 8,
            misses: 4,
            evictions: 0,
            peakUsage: 3
        )
        
        // Then
        XCTAssertEqual(stats.maxSize, 100, "Statistics should include maxSize")
        XCTAssertEqual(stats.currentlyAvailable, 5)
        XCTAssertEqual(stats.currentlyInUse, 2)
    }
    
    // MARK: - Integration Tests
    
    func testEndToEndMemoryPressureScenario() async {
        // Given - Multiple pools with different configurations
        let criticalPool = ObjectPool<TestObject>(
            name: "critical-pool",
            configuration: ObjectPoolConfiguration(maxSize: 200, trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        let normalPool = ObjectPool<TestObject>(
            name: "normal-pool",
            configuration: ObjectPoolConfiguration(maxSize: 100, trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // Pre-allocate objects
        await criticalPool.preallocate(count: 150)
        await normalPool.preallocate(count: 80)
        
        // Setup metrics collector
        let collector = PoolMetricsCollector()
        await collector.startCollecting()
        
        // Wait for registration
        try? await Task.sleep(nanoseconds: 200_000_000)
        
        // When - Simulate warning pressure
        await PoolRegistry.shared.shrinkAllPools(toPercentage: 0.5)
        
        // Then - Verify pools shrunk appropriately
        var criticalStats = await criticalPool.statistics
        var normalStats = await normalPool.statistics
        
        XCTAssertLessThanOrEqual(criticalStats.currentlyAvailable, 100, "Critical pool should shrink to 50% of max")
        XCTAssertLessThanOrEqual(normalStats.currentlyAvailable, 50, "Normal pool should shrink to 50% of max")
        
        // When - Simulate critical pressure
        await PoolRegistry.shared.shrinkAllPools(toPercentage: 0.0)
        
        // Then - Verify pools cleared
        criticalStats = await criticalPool.statistics
        normalStats = await normalPool.statistics
        
        XCTAssertEqual(criticalStats.currentlyAvailable, 0, "Critical pool should be empty")
        XCTAssertEqual(normalStats.currentlyAvailable, 0, "Normal pool should be empty")
        
        // Verify statistics tracking
        XCTAssertGreaterThan(criticalStats.evictions, 0, "Should track evictions")
        XCTAssertGreaterThan(normalStats.evictions, 0, "Should track evictions")
        
        // Cleanup
        await collector.stopCollecting()
    }
    
    // MARK: - Performance Tests
    
    // MARK: - Edge Cases
    
    func testZeroSizePool() async {
        // Given - Pool with zero max size
        let zeroPool = ObjectPool<TestObject>(
            name: "zero-pool",
            configuration: ObjectPoolConfiguration(maxSize: 0, trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // When - Try to preallocate
        await zeroPool.preallocate(count: 10)
        
        // Then - Should have no objects
        let stats = await zeroPool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 0)
        XCTAssertEqual(stats.maxSize, 0)
        
        // When - Acquire object
        let obj = await zeroPool.acquire()
        
        // Then - Should create new object but not pool it
        XCTAssertNotNil(obj)
        await zeroPool.release(obj)
        
        let releaseStats = await zeroPool.statistics
        XCTAssertEqual(releaseStats.currentlyAvailable, 0, "Zero-size pool shouldn't store objects")
        XCTAssertGreaterThan(releaseStats.evictions, 0, "Should evict immediately")
    }
    
    func testSingleObjectPool() async {
        // Given - Pool with single object capacity
        let singlePool = ObjectPool<TestObject>(
            name: "single-pool",
            configuration: ObjectPoolConfiguration(maxSize: 1, trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // When - Multiple acquire/release cycles
        let obj1 = await singlePool.acquire()
        let obj2 = await singlePool.acquire()
        
        XCTAssertNotEqual(obj1.id, obj2.id, "Should create new object when pool empty")
        
        await singlePool.release(obj1)
        await singlePool.release(obj2)
        
        // Then - Only one object should be pooled
        let stats = await singlePool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 1)
        XCTAssertEqual(stats.evictions, 1, "Second object should be evicted")
    }
    
    func testInvalidPercentages() async {
        // Given
        let pool = ObjectPool<TestObject>(
            name: "invalid-test",
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 50)
        
        // When/Then - Test various invalid percentages
        
        // NaN
        await PoolRegistry.shared.shrinkAllPools(toPercentage: Double.nan)
        var stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 0, "NaN should clamp to 0")
        
        // Refill
        await pool.preallocate(count: 50)
        
        // Infinity
        await PoolRegistry.shared.shrinkAllPools(toPercentage: Double.infinity)
        stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 50, "Infinity should clamp to 1.0 (no shrink)")
        
        // Negative infinity
        await PoolRegistry.shared.shrinkAllPools(toPercentage: -Double.infinity)
        stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 0, "Negative infinity should clamp to 0")
    }
    
    func testConcurrentShrinking() async {
        // Given
        let pool = ObjectPool<TestObject>(
            name: "concurrent-shrink",
            configuration: ObjectPoolConfiguration(maxSize: 1000, trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 800)
        
        // When - Multiple concurrent shrink operations
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let targetSize = 100 + (i * 50)
                    await pool.shrink(to: targetSize)
                }
            }
        }
        
        // Then - Pool should remain consistent
        let stats = await pool.statistics
        XCTAssertGreaterThanOrEqual(stats.currentlyAvailable, 0)
        XCTAssertLessThanOrEqual(stats.currentlyAvailable, 1000)
        XCTAssertGreaterThan(stats.evictions, 0)
    }
    
    func testRapidSuccessiveShrinks() async {
        // Given
        let pool = ObjectPool<TestObject>(
            name: "rapid-shrink",
            configuration: ObjectPoolConfiguration(maxSize: 100, trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        await pool.preallocate(count: 100)
        
        // When - Rapid shrinks (testing future throttling)
        for i in stride(from: 90, through: 10, by: -10) {
            await pool.shrink(to: i)
        }
        
        // Then - Final state should match last shrink
        let stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 10)
        XCTAssertEqual(stats.evictions, 90)
    }
    
    func testUnregisterDuringShrink() async {
        // Given
        class ShortLivedPool {
            let pool: ObjectPool<TestObject>
            
            init() {
                pool = ObjectPool<TestObject>(
                    name: "short-lived-\(UUID())",
                    configuration: ObjectPoolConfiguration(maxSize: 100),
                    factory: { TestObject() },
                    registerMetrics: true
                )
            }
        }
        
        let wrapper = ShortLivedPool()
        await wrapper.pool.preallocate(count: 50)
        
        // Wait for registration
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // When - Start shrinking then deallocate
        Task {
            await PoolRegistry.shared.shrinkAllPools(toPercentage: 0.1)
        }
        
        // Small delay then nil out (triggers deinit)
        try? await Task.sleep(nanoseconds: 10_000_000)
        // Pool deallocates here when wrapper goes out of scope
        
        // Then - System should not crash
        let stats = await PoolRegistry.shared.getAggregatedStatistics()
        XCTAssertNotNil(stats)
    }
    
    func testShrinkPerformanceOptimization() async {
        // Given - Many pools registered
        var pools: [ObjectPool<TestObject>] = []
        
        for i in 0..<100 {
            let pool = ObjectPool<TestObject>(
                name: "perf-pool-\(i)",
                configuration: ObjectPoolConfiguration(maxSize: 50),
                factory: { TestObject() },
                registerMetrics: true
            )
            pools.append(pool)
            await pool.preallocate(count: 25)
        }
        
        // Wait for registration
        try? await Task.sleep(nanoseconds: 200_000_000)
        
        // When - Measure shrink performance
        let start = Date()
        await PoolRegistry.shared.shrinkPool(name: "perf-pool-50", to: 10)
        let elapsed = Date().timeIntervalSince(start)
        
        // Then - Should complete quickly due to break optimization
        XCTAssertLessThan(elapsed, 0.1, "Should find and shrink target pool quickly")
        
        // Verify only target pool was affected
        let targetStats = await pools[50].statistics
        XCTAssertEqual(targetStats.currentlyAvailable, 10, "Target pool should be shrunk")
        
        let otherStats = await pools[49].statistics
        XCTAssertEqual(otherStats.currentlyAvailable, 25, "Other pools should be unchanged")
    }
}