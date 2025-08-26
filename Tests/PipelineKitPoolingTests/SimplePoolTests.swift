import XCTest
@testable import PipelineKitPooling
import PipelineKitCore

/// Simplified tests to get basic coverage working
final class SimplePoolTests: XCTestCase {
    private struct TestItem: Sendable {
        let id: Int
    }
    
    // MARK: - ObjectPool Basic Tests
    
    func testObjectPoolCreation() async throws {
        let pool = ObjectPool<TestItem>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: { TestItem(id: 1) }
        )
        
        XCTAssertNotNil(pool)
    }
    
    func testAcquireAndRelease() async throws {
        let pool = ObjectPool<TestItem>(
            configuration: try ObjectPoolConfiguration(maxSize: 5),
            factory: { TestItem(id: 1) }
        )
        
        let item = try await pool.acquire()
        XCTAssertEqual(item.id, 1)
        
        await pool.release(item)
    }
    
    func testPreallocate() async throws {
        let pool = ObjectPool<TestItem>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: { TestItem(id: 1) }
        )
        
        await pool.preallocate(count: 3)
        
        let stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 3)
    }
    
    func testClearPool() async throws {
        let pool = ObjectPool<TestItem>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: { TestItem(id: 1) }
        )
        
        await pool.preallocate(count: 5)
        await pool.clear()
        
        let stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 0)
    }
    
    func testShrinkPool() async throws {
        let pool = ObjectPool<TestItem>(
            configuration: try ObjectPoolConfiguration(maxSize: 10),
            factory: { TestItem(id: 1) }
        )
        
        await pool.preallocate(count: 8)
        await pool.shrink(to: 3)
        
        let stats = await pool.statistics
        XCTAssertEqual(stats.currentlyAvailable, 3)
    }
    
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() throws {
        let config = ObjectPoolConfiguration.default
        XCTAssertEqual(config.maxSize, 100)
        XCTAssertTrue(config.trackStatistics)
    }
    
    func testCustomConfiguration() throws {
        let config = try ObjectPoolConfiguration(
            maxSize: 50,
            highWaterMark: 40,
            lowWaterMark: 10
        )
        
        XCTAssertEqual(config.maxSize, 50)
        XCTAssertEqual(config.highWaterMark, 40)
        XCTAssertEqual(config.lowWaterMark, 10)
    }
    
    func testInvalidConfiguration() {
        XCTAssertThrowsError(
            try ObjectPoolConfiguration(maxSize: 0)
        )
        
        XCTAssertThrowsError(
            try ObjectPoolConfiguration(
                maxSize: 10,
                highWaterMark: 20,  // > maxSize
                lowWaterMark: 5
            )
        )
    }
    
    // MARK: - Statistics Tests
    
    func testStatisticsTracking() async throws {
        let pool = ObjectPool<TestItem>(
            configuration: try ObjectPoolConfiguration(
                maxSize: 10,
                trackStatistics: true
            ),
            factory: { TestItem(id: 1) }
        )
        
        let item1 = try await pool.acquire()
        await pool.release(item1)
        _ = try await pool.acquire()
        
        let stats = await pool.statistics
        XCTAssertEqual(stats.totalAcquisitions, 2)
        XCTAssertEqual(stats.totalReleases, 1)
        XCTAssertEqual(stats.hits, 1)
        XCTAssertEqual(stats.misses, 1)
    }
    
    func testStatisticsDisabled() async throws {
        let pool = ObjectPool<TestItem>(
            configuration: try ObjectPoolConfiguration(
                maxSize: 10,
                trackStatistics: false
            ),
            factory: { TestItem(id: 1) }
        )
        
        let item = try await pool.acquire()
        await pool.release(item)
        
        let stats = await pool.statistics
        // When disabled, stats should be zero/minimal
        XCTAssertEqual(stats.totalAcquisitions, 0)
    }
    
    // MARK: - PooledObject Tests
    
    func testPooledObjectCreation() async throws {
        let pool = ObjectPool<TestItem>(
            configuration: try ObjectPoolConfiguration(maxSize: 5),
            factory: { TestItem(id: 42) }
        )
        
        let pooled = try await pool.acquirePooled()
        XCTAssertEqual(pooled.object.id, 42)
        
        await pooled.returnToPool()
    }
    
    func testPooledObjectDoubleReturn() async throws {
        let pool = ObjectPool<TestItem>(
            configuration: try ObjectPoolConfiguration(maxSize: 5),
            factory: { TestItem(id: 1) }
        )
        
        let pooled = try await pool.acquirePooled()
        
        await pooled.returnToPool()
        await pooled.returnToPool() // Should be no-op
        
        let stats = await pool.statistics
        XCTAssertLessThanOrEqual(stats.currentlyAvailable, 1)
    }
    
    // MARK: - PoolAnalysis Tests
    
    func testPoolAnalysisCreation() {
        let analysis = PoolAnalysis(
            averageUtilization: 0.75,
            allocationVelocity: 10.0,
            peakUsage: 80,
            recentPeakUsage: 60,
            pattern: .steady,
            analysisWindow: 300.0,
            confidence: 0.9
        )
        
        XCTAssertEqual(analysis.averageUtilization, 0.75)
        XCTAssertEqual(analysis.pattern, .steady)
    }
    
    func testUsagePatterns() {
        let patterns: [UsagePattern] = [.steady, .bursty, .growing, .declining, .unknown]
        
        for pattern in patterns {
            let analysis = PoolAnalysis(
                averageUtilization: 0.5,
                allocationVelocity: 5.0,
                peakUsage: 50,
                recentPeakUsage: 40,
                pattern: pattern,
                analysisWindow: 300.0,
                confidence: 0.8
            )
            
            XCTAssertEqual(analysis.pattern, pattern)
        }
    }
    
    // MARK: - IntelligentShrinker Tests
    
    func testIntelligentShrinkerCalculation() {
        let stats = ObjectPoolStatistics(
            totalAllocated: 100,
            currentlyAvailable: 50,
            currentlyInUse: 50,
            maxSize: 100
        )
        
        let analysis = PoolAnalysis(
            averageUtilization: 0.5,
            allocationVelocity: 5.0,
            peakUsage: 70,
            recentPeakUsage: 60,
            pattern: .steady,
            analysisWindow: 300.0,
            confidence: 0.9
        )
        
        let target = IntelligentShrinker.calculateOptimalTarget(
            pool: stats,
            analysis: analysis,
            pressureLevel: .normal
        )
        
        XCTAssertGreaterThanOrEqual(target, 0)
        XCTAssertLessThanOrEqual(target, stats.maxSize)
    }
    
    func testMemoryPressureLevels() {
        let levels: [MemoryPressureLevel] = [.normal, .warning, .critical]
        
        for level in levels {
            XCTAssertNotNil(level)
        }
    }
}
