import XCTest
@testable import PipelineKit

/// Tests for the new actor-based ContextPoolConfiguration
/// Verifies thread safety, Sendable conformance, and proper integration
final class ContextPoolConfigurationTests: XCTestCase {
    
    func testConfigurationActorThreadSafety() async {
        // Reset to known state
        await ContextPoolConfiguration.shared.reset()
        
        // Test concurrent configuration updates
        await withTaskGroup(of: Void.self) { group in
            for i in 1...100 {
                group.addTask {
                    await ContextPoolConfiguration.shared.updatePoolSize(i)
                }
            }
        }
        
        // Verify final state is consistent
        let finalSize = await ContextPoolConfiguration.shared.poolSize
        XCTAssertTrue(finalSize >= 1 && finalSize <= 100)
    }
    
    func testPoolCreationWithConfiguration() async {
        // Set custom configuration
        await ContextPoolConfiguration.shared.updatePoolSize(50)
        
        // Create configured pool
        let pool = await CommandContextPool.createConfigured()
        
        // Verify it works
        let metadata = StandardCommandMetadata(userId: "test", correlationId: "123")
        let context = pool.borrow(metadata: metadata)
        XCTAssertNotNil(context)
        
        // Return to pool
        context.returnToPool()
    }
    
    func testPoolSendableConformance() async {
        // This test verifies that CommandContextPool can be passed across concurrency boundaries
        let pool = CommandContextPool.shared
        
        // Pass pool to async function (requires Sendable)
        await usePoolConcurrently(pool)
        
        // Verify pool still works
        let stats = pool.getStatistics()
        XCTAssertGreaterThan(stats.totalBorrows, 0)
    }
    
    func testMonitorSendableConformance() async {
        // Create a Sendable monitor
        struct TestMonitor: ContextPoolMonitor {
            func poolDidBorrow(context: CommandContext, hitRate: Double) {
                // Thread-safe implementation
            }
            
            func poolDidReturn(context: CommandContext) {
                // Thread-safe implementation
            }
            
            func poolDidExpand(newSize: Int) {
                // Thread-safe implementation
            }
        }
        
        // Install monitor
        await ContextPoolConfiguration.shared.installMonitor(TestMonitor())
        
        // Verify it's installed
        let monitor = await ContextPoolConfiguration.shared.currentMonitor
        XCTAssertNotNil(monitor)
    }
    
    func testConfigurationReset() async {
        // Given: Modified configuration
        await ContextPoolConfiguration.shared.configure(
            poolSize: 200,
            poolingEnabled: false,
            monitor: ConsoleContextPoolMonitor()
        )
        
        // When: Reset is called
        await ContextPoolConfiguration.shared.reset()
        
        // Then: Values return to defaults
        let size = await ContextPoolConfiguration.shared.poolSize
        let enabled = await ContextPoolConfiguration.shared.poolingEnabled
        let monitor = await ContextPoolConfiguration.shared.currentMonitor
        
        XCTAssertEqual(size, 100)
        XCTAssertTrue(enabled)
        XCTAssertNil(monitor)
    }
    
    func testConfigurationIsolation() async {
        // This test verifies actor isolation prevents data races
        let iterations = 1000
        var results: Set<Int> = []
        
        await withTaskGroup(of: Int.self) { group in
            // Concurrent reads and writes
            for i in 1...iterations {
                if i % 2 == 0 {
                    // Write
                    group.addTask {
                        await ContextPoolConfiguration.shared.updatePoolSize(i)
                        return i
                    }
                } else {
                    // Read
                    group.addTask {
                        return await ContextPoolConfiguration.shared.poolSize
                    }
                }
            }
            
            for await result in group {
                results.insert(result)
            }
        }
        
        // Verify no crashes or data corruption occurred
        XCTAssertTrue(results.count > 0)
        
        // Final value should be valid
        let finalSize = await ContextPoolConfiguration.shared.poolSize
        XCTAssertTrue(finalSize > 0 && finalSize <= iterations)
    }
    
    func testPoolCreationConsistency() async {
        // Given: A specific configuration
        await ContextPoolConfiguration.shared.updatePoolSize(75)
        
        // When: Creating multiple pools concurrently
        let pools = await withTaskGroup(of: CommandContextPool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await CommandContextPool.createConfigured()
                }
            }
            
            var pools: [CommandContextPool] = []
            for await pool in group {
                pools.append(pool)
            }
            return pools
        }
        
        // Then: All pools have consistent configuration
        XCTAssertEqual(pools.count, 10)
        // Note: We can't directly access maxSize, but we can verify they work
        for pool in pools {
            let metadata = StandardCommandMetadata(userId: "test", correlationId: "123")
            let context = pool.borrow(metadata: metadata)
            XCTAssertNotNil(context)
            context.returnToPool()
        }
    }
    
    func testSendableCompilerRequirement() async {
        // This test verifies that our types satisfy Sendable requirements
        // at compile time by using them in contexts that require Sendable
        
        // Test 1: Pass pool across isolation boundary
        let pool = CommandContextPool.shared
        let _: any Sendable = pool // Compile-time check
        
        // Test 2: Use in TaskGroup (requires Sendable)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = pool.borrow(metadata: StandardCommandMetadata())
            }
        }
        
        // Test 3: Actor method parameter (requires Sendable)
        actor TestActor {
            func usePool(_ pool: CommandContextPool) {
                _ = pool.getStatistics()
            }
        }
        
        let actor = TestActor()
        await actor.usePool(pool)
        
        // If this compiles, our Sendable conformance is correct
        XCTAssertTrue(true)
    }
    
    // Helper function that requires Sendable pool
    private func usePoolConcurrently(_ pool: CommandContextPool) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let metadata = StandardCommandMetadata(userId: "test", correlationId: UUID().uuidString)
                    let context = pool.borrow(metadata: metadata)
                    // Simulate some work
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    context.returnToPool()
                }
            }
        }
    }
    
    // MARK: - Performance Tests
    
    func testConfigurationAccessPerformance() async throws {
        // Measure the overhead of async configuration access
        let iterations = 10000
        
        let start = Date()
        for _ in 0..<iterations {
            _ = await ContextPoolConfiguration.shared.poolSize
        }
        let duration = Date().timeIntervalSince(start)
        
        let avgTime = duration / Double(iterations) * 1_000_000 // microseconds
        print("Average configuration access time: \(String(format: "%.2f", avgTime))μs")
        
        // Should be fast even with actor isolation
        XCTAssertLessThan(avgTime, 100, "Configuration access should be under 100μs")
    }
    
    func testPoolBorrowReturnPerformance() async throws {
        // Verify that Sendable conformance doesn't impact performance
        let pool = CommandContextPool.shared
        let iterations = 10000
        
        let start = Date()
        for _ in 0..<iterations {
            let ctx = pool.borrow(metadata: StandardCommandMetadata())
            ctx.returnToPool()
        }
        let duration = Date().timeIntervalSince(start)
        
        let avgTime = duration / Double(iterations) * 1_000_000 // microseconds
        print("Average borrow/return time: \(String(format: "%.2f", avgTime))μs")
        
        // Should remain fast with @unchecked Sendable
        XCTAssertLessThan(avgTime, 10, "Borrow/return should be under 10μs")
    }
}