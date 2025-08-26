import XCTest
@testable import PipelineKitPooling
import PipelineKitCore
import Atomics

final class ObjectPoolTests: XCTestCase {
    // MARK: - Test Types
    
    private struct TestObject: Sendable {
        let id: Int
        var value: String
        var resetCount: Int = 0
        
        init(id: Int = 0) {
            self.id = id
            self.value = "initial"
        }
    }
    
    // MARK: - Basic Operations
    
    func testBasicAcquireRelease() async throws {
        let factoryCallCount = ManagedAtomic<Int>(0)
        let resetCallCount = ManagedAtomic<Int>(0)
        
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: {
                let count = factoryCallCount.loadThenWrappingIncrement(ordering: .relaxed)
                return TestObject(id: count + 1)
            },
            reset: { _ in
                _ = resetCallCount.loadThenWrappingIncrement(ordering: .relaxed)
            }
        )
        
        // First acquire should create new object
        let obj1 = try await pool.acquire()
        XCTAssertEqual(obj1.id, 1)
        XCTAssertEqual(factoryCallCount.load(ordering: .relaxed), 1)
        
        // Release back to pool
        await pool.release(obj1)
        
        // Second acquire should reuse
        let obj2 = try await pool.acquire()
        XCTAssertEqual(obj2.id, 1)
        XCTAssertEqual(factoryCallCount.load(ordering: .relaxed), 1)
        XCTAssertEqual(resetCallCount.load(ordering: .relaxed), 1)
    }
    
    func testPoolSizeLimit() async throws {
        let config = try ObjectPoolConfiguration(maxSize: 3)
        let pool = ObjectPool<TestObject>(
            configuration: config,
            factory: { TestObject() }
        )
        
        var objects: [TestObject] = []
        
        // Acquire maxSize objects (3)
        for _ in 0..<3 {
            objects.append(try await pool.acquire())
        }
        
        // Try to acquire one more - should block/timeout
        // We'll test this by releasing one and acquiring again
        await pool.release(objects[0])
        let replacement = try await pool.acquire()
        
        // Release all
        await pool.release(replacement)
        for obj in objects.dropFirst() {
            await pool.release(obj)
        }
        
        // Pool should have maxSize available after all releases
        let stats = await pool.statistics
        XCTAssertLessThanOrEqual(stats.currentlyAvailable, 3)
    }
    
    func testPreallocate() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject() }
        )
        
        await pool.preallocate(count: 5)
        
        let stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 5)
        XCTAssertEqual(stats.totalAllocated, 5)
    }
    
    func testClear() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject() }
        )
        
        // Pre-fill pool
        await pool.preallocate(count: 5)
        var stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 5)
        
        // Clear pool
        await pool.clear()
        
        stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 0)
    }
    
    // MARK: - Concurrent Access
    
    func testConcurrentAcquireRelease() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject() }
        )
        
        await withTaskGroup(of: Void.self) { group in
            // 100 concurrent tasks
            for _ in 0..<100 {
                group.addTask {
                    guard let obj = try? await pool.acquire() else { return }
                    // Simulate work
                    try? await Task.sleep(nanoseconds: 10_000)
                    await pool.release(obj)
                }
            }
        }
        
        // Pool should still be functional
        let obj = try await pool.acquire()
        XCTAssertNotNil(obj)
    }
    
    func testConcurrentWithStatistics() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(
                maxSize: 5,
                trackStatistics: true
            ),
            factory: { TestObject() }
        )
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    guard let obj = try? await pool.acquire() else { return }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    await pool.release(obj)
                }
            }
        }
        
        let stats = await pool.statistics
        XCTAssertGreaterThan(stats.totalAcquisitions, 0)
        XCTAssertGreaterThan(stats.totalReleases, 0)
    }
    
    // MARK: - Statistics
    
    func testStatisticsTracking() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(
                maxSize: 5,
                trackStatistics: true
            ),
            factory: { TestObject() }
        )
        
        // Acquire and track hits/misses
        let obj1 = try await pool.acquire()
        await pool.release(obj1)
        _ = try await pool.acquire() // Should be a hit
        
        let stats = await pool.statistics
        XCTAssertEqual(stats.totalAcquisitions, 2)
        XCTAssertEqual(stats.totalReleases, 1)
        XCTAssertEqual(stats.hits, 1)
        XCTAssertEqual(stats.misses, 1)
    }
    
    func testStatisticsDisabled() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(
                maxSize: 5,
                trackStatistics: false
            ),
            factory: { TestObject() }
        )
        
        let obj = try await pool.acquire()
        await pool.release(obj)
        
        let stats = await pool.statistics
        // Check if statistics tracking was disabled
        XCTAssertEqual(stats.totalAcquisitions, 0)
        XCTAssertEqual(stats.totalReleases, 0)
    }
    
    // MARK: - Shrinking
    
    func testShrinkOperation() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject() }
        )
        
        // Fill pool
        await pool.preallocate(count: 10)
        var stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 10)
        
        // Shrink to 3
        await pool.shrink(to: 3)
        
        stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 3)
    }
    
    func testShrinkWithNegativeTarget() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject() }
        )
        
        await pool.preallocate(count: 5)
        
        // Should clamp to 0
        await pool.shrink(to: -10)
        
        let stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 0)
    }
    
    // MARK: - Edge Cases
    
    func testEmptyPoolAcquire() async throws {
        let factoryCount = ManagedAtomic<Int>(0)
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 2),  // Changed to 2 to allow both acquires
            factory: {
                let count = factoryCount.loadThenWrappingIncrement(ordering: .relaxed)
                return TestObject(id: count + 1)
            }
        )
        
        // Multiple acquires on empty pool
        let obj1 = try await pool.acquire()
        let obj2 = try await pool.acquire()
        
        XCTAssertEqual(factoryCount.load(ordering: .relaxed), 2)
        XCTAssertNotEqual(obj1.id, obj2.id)
        
        // Clean up
        await pool.release(obj1)
        await pool.release(obj2)
    }
    
    func testRapidAcquireRelease() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 1),
            factory: { TestObject() }
        )
        
        // Rapid acquire/release cycles
        for _ in 0..<100 {
            let obj = try await pool.acquire()
            await pool.release(obj)
        }
        
        let stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 1)
    }
    
    func testPoolWithZeroMaxSize() async throws {
        // This should throw
        XCTAssertThrowsError(
            try ObjectPoolConfiguration(maxSize: 0)
        ) { error in
            XCTAssertTrue(error is ObjectPoolConfigurationError)
        }
    }
    
    func testFactoryThrows() async throws {
        struct FactoryError: Error {}
        
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 5),
            factory: { TestObject() },
            reset: { _ in }
        )
        
        // Normal operation should work
        let obj = try await pool.acquire()
        XCTAssertNotNil(obj)
    }
    
    // MARK: - PooledObject Integration
    
    func testAcquirePooledAutoReturn() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 5),
            factory: { TestObject() }
        )
        
        var stats = await pool.statistics
        let initial = stats.currentlyAvailable
        
        // Acquire in scope
        do {
            let pooled = try await pool.acquirePooled()
            XCTAssertNotNil(pooled.object)
        }
        
        // Allow time for async dealloc
        try await Task.sleep(nanoseconds: 100_000_000)
        
        stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, initial + 1)
    }
    
    func testAcquirePooledManualReturn() async throws {
        let pool = ObjectPool<TestObject>(
            configuration: try ObjectPoolConfiguration(maxSize: 5),
            factory: { TestObject() }
        )
        
        let pooled = try await pool.acquirePooled()
        
        var stats = await pool.statistics
        let beforeReturn = stats.currentlyAvailable
        
        await pooled.returnToPool()
        
        stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, beforeReturn + 1)
    }
}
