import XCTest
@testable import PipelineKitCore

@MainActor
final class PoolRegistryTests: XCTestCase {
    
    override func setUp() async throws {
        // Reset registry state
        PoolRegistry.metricsEnabledByDefault = false
    }
    
    // MARK: - Registration Tests
    
    func testRegistrationWithMetricsEnabled() async throws {
        // Create pool with metrics explicitly enabled
        let pool = ObjectPool<TestObject>(
            name: "test-pool",
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // Give time for async registration
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Check that pool is registered
        let stats = await PoolRegistry.shared.getAllStatistics()
        XCTAssertTrue(stats.contains { $0.name == "test-pool" })
    }
    
    func testRegistrationWithMetricsDisabledByDefault() async throws {
        // Default should be disabled
        let pool = ObjectPool<TestObject>(
            factory: { TestObject() }
        )
        
        // Give time for async registration (though it shouldn't happen)
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Pool should not be registered
        let stats = await PoolRegistry.shared.getAllStatistics()
        XCTAssertFalse(stats.contains { $0.name.contains("TestObject") })
    }
    
    func testGlobalMetricsEnabledByDefault() async throws {
        // Enable metrics globally
        PoolRegistry.metricsEnabledByDefault = true
        
        let pool = ObjectPool<TestObject>(
            factory: { TestObject() }
        )
        
        // Give time for async registration
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Pool should be registered
        let stats = await PoolRegistry.shared.getAllStatistics()
        XCTAssertTrue(stats.contains { $0.name.contains("TestObject") })
        
        // Reset for other tests
        PoolRegistry.metricsEnabledByDefault = false
    }
    
    // MARK: - Statistics Collection Tests
    
    func testStatisticsCollection() async throws {
        let pool = ObjectPool<TestObject>(
            name: "stats-test-pool",
            configuration: ObjectPoolConfiguration(maxSize: 2, trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // Use the pool
        let obj1 = await pool.acquire()
        let obj2 = await pool.acquire()
        await pool.release(obj1)
        await pool.release(obj2)
        
        // Reuse from pool (hits)
        let obj3 = await pool.acquire()
        let obj4 = await pool.acquire()
        
        // Give time for async registration
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Get statistics
        let stats = await PoolRegistry.shared.getAllStatistics()
        let poolStats = stats.first { $0.name == "stats-test-pool" }
        
        XCTAssertNotNil(poolStats)
        XCTAssertEqual(poolStats?.stats.hits, 2)
        XCTAssertEqual(poolStats?.stats.misses, 2)
        XCTAssertEqual(poolStats?.stats.totalAllocated, 2)
    }
    
    func testAggregatedStatistics() async throws {
        // Create multiple pools
        let pool1 = ObjectPool<TestObject>(
            name: "pool-1",
            configuration: ObjectPoolConfiguration(trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        let pool2 = ObjectPool<TestObject>(
            name: "pool-2",
            configuration: ObjectPoolConfiguration(trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // Use pools
        let obj1 = await pool1.acquire() // miss
        await pool1.release(obj1)
        let obj2 = await pool1.acquire() // hit
        
        let obj3 = await pool2.acquire() // miss
        await pool2.release(obj3)
        let obj4 = await pool2.acquire() // hit
        
        // Give time for async registration
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Get aggregated statistics
        let aggregated = await PoolRegistry.shared.getAggregatedStatistics()
        
        XCTAssertEqual(aggregated.activePoolCount, 2)
        XCTAssertEqual(aggregated.totalHits, 2)
        XCTAssertEqual(aggregated.totalMisses, 2)
        XCTAssertEqual(aggregated.overallHitRate, 50.0, accuracy: 0.1)
    }
    
    // MARK: - Cleanup Tests
    
    func testWeakReferenceCleanup() async throws {
        var pool: ObjectPool<TestObject>? = ObjectPool<TestObject>(
            name: "cleanup-test",
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // Give time for async registration
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Verify pool is registered
        var stats = await PoolRegistry.shared.getAllStatistics()
        XCTAssertTrue(stats.contains { $0.name == "cleanup-test" })
        
        // Release the pool
        pool = nil
        
        // Give time for cleanup
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Pool should be removed from registry
        stats = await PoolRegistry.shared.getAllStatistics()
        XCTAssertFalse(stats.contains { $0.name == "cleanup-test" })
    }
    
    // MARK: - Name Generation Tests
    
    func testAutomaticNameGeneration() async throws {
        let pool1 = ObjectPool<TestObject>(
            factory: { TestObject() },
            registerMetrics: true
        )
        
        let pool2 = ObjectPool<TestObject>(
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // Give time for async registration
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Names should be unique
        let stats = await PoolRegistry.shared.getAllStatistics()
        let names = stats.map { $0.name }
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count, "Pool names should be unique")
        
        // Names should follow pattern
        for name in names {
            XCTAssertTrue(name.contains("TestObject"))
        }
    }
    
    // MARK: - Debug Support Tests
    
    #if DEBUG
    func testDetailedStatistics() async throws {
        let pool = ObjectPool<TestObject>(
            name: "detailed-test",
            configuration: ObjectPoolConfiguration(trackStatistics: true),
            factory: { TestObject() },
            registerMetrics: true
        )
        
        // Use the pool
        let obj = await pool.acquire()
        await pool.release(obj)
        
        // Give time for async registration
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Get detailed statistics
        let detailed = await PoolRegistry.shared.getDetailedStatistics()
        let poolDetail = detailed.first { $0.name == "detailed-test" }
        
        XCTAssertNotNil(poolDetail)
        XCTAssertNotNil(poolDetail?.createdAt)
        XCTAssertEqual(poolDetail?.stats.hits, 0)
        XCTAssertEqual(poolDetail?.stats.misses, 1)
    }
    #endif
}

// MARK: - Test Helpers

private final class TestObject: Sendable {
    let id = UUID()
}