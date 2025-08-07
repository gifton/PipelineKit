import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class ObjectPoolTests: XCTestCase {
    // MARK: - Test Types
    
    private struct TestObject: Sendable {
        var value: Int
        var isReset: Bool = false
        
        init(value: Int = 0) {
            self.value = value
        }
        
        mutating func reset() {
            value = 0
            isReset = true
        }
    }
    
    // MARK: - Basic Functionality Tests
    
    func testPoolCreation() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject(value: 42) }
        )
        
        // Pre-allocate objects
        await pool.preallocate(count: 5)
        
        // When
        let stats = await pool.statistics()
        
        // Then
        XCTAssertEqual(stats.totalAllocated, 5)
        XCTAssertEqual(stats.currentlyAvailable, 5)
        XCTAssertEqual(stats.currentlyInUse, 0)
    }
    
    func testAcquireFromPreAllocated() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject(value: 42) }
        )
        
        // Pre-allocate objects
        await pool.preallocate(count: 5)
        
        // When
        let obj = await pool.acquire()
        let stats = await pool.statistics()
        
        // Then
        XCTAssertEqual(obj.value, 42)
        XCTAssertEqual(stats.currentlyAvailable, 4)
        XCTAssertEqual(stats.currentlyInUse, 1)
        XCTAssertEqual(stats.hits, 1)
        XCTAssertEqual(stats.hitRate, 1.0)
    }
    
    func testAcquireWhenEmpty() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject(value: 99) }
        )
        
        // When
        let obj = await pool.acquire()
        let stats = await pool.statistics()
        
        // Then
        XCTAssertEqual(obj.value, 99)
        XCTAssertEqual(stats.totalAllocated, 1)
        XCTAssertEqual(stats.currentlyInUse, 1)
        XCTAssertEqual(stats.hits, 0)
        XCTAssertEqual(stats.hitRate, 0.0)
    }
    
    func testReleaseToPool() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject(value: 42) }
        )
        
        // When
        let obj = await pool.acquire()
        await pool.release(obj)
        let stats = await pool.statistics()
        
        // Then
        XCTAssertEqual(stats.currentlyAvailable, 1)
        XCTAssertEqual(stats.currentlyInUse, 0)
        XCTAssertEqual(stats.totalReturns, 1)
    }
    
    func testReuseWithReset() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject(value: 42) },
            reset: { obj in
                var mutableObj = obj
                mutableObj.reset()
            }
        )
        
        // When
        let obj1 = await pool.acquire()
        obj1.value = 100
        await pool.release(obj1)
        
        let obj2 = await pool.acquire()
        
        // Then
        XCTAssertTrue(obj2.isReset)
        XCTAssertEqual(obj2.value, 0) // Reset by reset function
    }
    
    func testMaxSizeLimit() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 2),
            factory: { TestObject(value: 42) }
        )
        
        // When
        let obj1 = await pool.acquire()
        let obj2 = await pool.acquire()
        let obj3 = await pool.acquire()
        
        await pool.release(obj1)
        await pool.release(obj2)
        await pool.release(obj3) // Should not be kept in pool
        
        let stats = await pool.statistics()
        
        // Then
        XCTAssertEqual(stats.currentlyAvailable, 2) // Max size is 2
        XCTAssertEqual(stats.totalReturns, 3)
    }
    
    func testPeakUsageTracking() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject() }
        )
        
        // When
        let objects = await withTaskGroup(of: TestObject.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await pool.acquire()
                }
            }
            
            var objects: [TestObject] = []
            for await obj in group {
                objects.append(obj)
            }
            return objects
        }
        
        let stats = await pool.statistics()
        
        // Then
        XCTAssertEqual(stats.peakUsage, 5)
        
        // Release some
        await pool.release(objects[0])
        await pool.release(objects[1])
        
        let statsAfter = await pool.statistics()
        XCTAssertEqual(statsAfter.peakUsage, 5) // Peak doesn't decrease
    }
    
    func testPooledObjectWrapper() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject(value: 42) }
        )
        
        // Pre-allocate
        await pool.preallocate(count: 1)
        
        // When
        let statsBefore = await pool.statistics()
        
        let pooledObj = await pool.acquirePooled()
        XCTAssertEqual(pooledObj.object.value, 42)
        
        let statsDuring = await pool.statistics()
        
        // Manually return
        await pooledObj.returnToPool()
        
        let statsAfter = await pool.statistics()
        
        // Then
        XCTAssertEqual(statsBefore.currentlyAvailable, 1)
        XCTAssertEqual(statsDuring.currentlyInUse, 1)
        XCTAssertEqual(statsAfter.currentlyAvailable, 1)
        XCTAssertEqual(statsAfter.currentlyInUse, 0)
    }
    
    func testConcurrentAccess() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject(value: Int.random(in: 1...100)) }
        )
        
        // Pre-allocate to ensure good hit rate
        await pool.preallocate(count: 50)
        
        // When
        let results = await withTaskGroup(of: Int.self) { group in
            // Multiple concurrent acquires and releases
            for _ in 0..<50 {
                group.addTask {
                    let obj = await pool.acquire()
                    // Simulate some work
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 1000...10000))
                    let value = obj.value
                    await pool.release(obj)
                    return value
                }
            }
            
            var sum = 0
            for await value in group {
                sum += value
            }
            return sum
        }
        
        // Then
        let stats = await pool.statistics()
        XCTAssertGreaterThan(results, 0)
        XCTAssertEqual(stats.totalBorrows, 50)
        XCTAssertEqual(stats.totalReturns, 50)
        XCTAssertGreaterThan(stats.hitRate, 0.5) // Should have good hit rate
    }
    
    func testWarmUp() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 100),
            factory: { TestObject() }
        )
        
        // When
        let statsBefore = await pool.statistics()
        await pool.preallocate(count: 20)
        let statsAfter = await pool.statistics()
        
        // Then
        XCTAssertEqual(statsBefore.currentlyAvailable, 0)
        XCTAssertEqual(statsAfter.currentlyAvailable, 20)
        XCTAssertEqual(statsAfter.totalAllocated, 20)
    }
    
    func testClear() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 10),
            factory: { TestObject() }
        )
        
        // Pre-allocate
        await pool.preallocate(count: 5)
        
        // Acquire some objects
        let obj1 = await pool.acquire()
        _ = await pool.acquire()
        await pool.release(obj1)
        
        // When
        await pool.clear()
        let stats = await pool.statistics()
        
        // Then
        XCTAssertEqual(stats.currentlyAvailable, 0)
        XCTAssertEqual(stats.currentlyInUse, 0)
        XCTAssertEqual(stats.totalAllocated, 0)
        XCTAssertEqual(stats.totalBorrows, 0)
    }
    
    func testStatisticsAccuracy() async {
        // Given
        let pool = ObjectPool<TestObject>(
            configuration: ObjectPoolConfiguration(maxSize: 10, trackStatistics: true),
            factory: { TestObject() }
        )
        
        // Pre-allocate
        await pool.preallocate(count: 2)
        
        // When
        // Borrow from pre-allocated (2 hits)
        let obj1 = await pool.acquire()
        let obj2 = await pool.acquire()
        
        // Borrow new (1 miss)
        let obj3 = await pool.acquire()
        
        // Return all
        await pool.release(obj1)
        await pool.release(obj2)
        await pool.release(obj3)
        
        // Borrow again (should be hits)
        let obj4 = await pool.acquire()
        let obj5 = await pool.acquire()
        
        let stats = await pool.statistics()
        
        // Then
        XCTAssertEqual(stats.totalBorrows, 5)
        XCTAssertEqual(stats.hits, 4) // 2 initial + 2 reuse
        XCTAssertEqual(stats.hitRate, 0.8) // 4/5
        XCTAssertEqual(stats.totalAllocated, 3) // 2 pre + 1 new
        XCTAssertEqual(stats.peakUsage, 3)
    }
}
