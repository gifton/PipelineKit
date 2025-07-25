import XCTest
@testable import PipelineKit

/// Integration tests for ContextPoolConfiguration with real pipeline usage
final class ContextPoolIntegrationTests: XCTestCase {
    
    override func setUp() async throws {
        // Reset configuration to defaults before each test
        await ContextPoolConfiguration.shared.reset()
    }
    
    func testConfigurationIntegrationWithPipeline() async throws {
        // Given: Custom pool configuration
        await ContextPoolConfiguration.shared.configure(
            poolSize: 5,  // Small pool to test exhaustion
            poolingEnabled: true
        )
        
        // Create a configured pool
        let customPool = await CommandContextPool.createConfigured()
        
        // Borrow all contexts
        var contexts: [PooledCommandContext] = []
        for i in 0..<5 {
            let ctx = customPool.borrow(
                metadata: StandardCommandMetadata(userId: "user\(i)", correlationId: "test")
            )
            contexts.append(ctx)
        }
        
        // Pool should be exhausted
        let stats1 = customPool.getStatistics()
        XCTAssertEqual(stats1.currentlyAvailable, 0)
        XCTAssertEqual(stats1.currentlyInUse, 5)
        
        // Return one context
        contexts[0].returnToPool()
        
        // Should have one available
        let stats2 = customPool.getStatistics()
        XCTAssertEqual(stats2.currentlyAvailable, 1)
        XCTAssertEqual(stats2.currentlyInUse, 4)
        
        // Return all contexts
        for ctx in contexts {
            ctx.returnToPool()
        }
    }
    
    func testPoolingEnabledFlag() async throws {
        // Test that poolingEnabled configuration is respected
        struct TestCommand: Command {
            typealias Result = String
            let id: String
        }
        
        struct TestHandler: CommandHandler {
            typealias CommandType = TestCommand
            func handle(_ command: TestCommand) async throws -> String {
                return "Handled: \(command.id)"
            }
        }
        
        // Given: Pooling disabled in configuration
        await ContextPoolConfiguration.shared.enablePooling(false)
        
        // When: Check configuration
        let poolingEnabled = await ContextPoolConfiguration.shared.poolingEnabled
        XCTAssertFalse(poolingEnabled)
        
        // Re-enable for other tests
        await ContextPoolConfiguration.shared.enablePooling(true)
    }
    
    func testMonitorIntegration() async throws {
        // Given: A monitor that tracks events
        actor TestMonitor: ContextPoolMonitor {
            private(set) var borrowCount = 0
            private(set) var returnCount = 0
            private(set) var expandCount = 0
            
            nonisolated func poolDidBorrow(context: CommandContext, hitRate: Double) {
                Task { await incrementBorrow() }
            }
            
            nonisolated func poolDidReturn(context: CommandContext) {
                Task { await incrementReturn() }
            }
            
            nonisolated func poolDidExpand(newSize: Int) {
                Task { await incrementExpand() }
            }
            
            func incrementBorrow() { borrowCount += 1 }
            func incrementReturn() { returnCount += 1 }
            func incrementExpand() { expandCount += 1 }
            
            func getCounts() -> (borrows: Int, returns: Int, expands: Int) {
                (borrowCount, returnCount, expandCount)
            }
        }
        
        let monitor = TestMonitor()
        await ContextPoolConfiguration.shared.installMonitor(monitor)
        
        // When: Using the pool
        let pool = CommandContextPool.shared
        let ctx1 = pool.borrow(metadata: StandardCommandMetadata())
        let ctx2 = pool.borrow(metadata: StandardCommandMetadata())
        
        ctx1.returnToPool()
        ctx2.returnToPool()
        
        // Give monitor time to process events
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Then: Monitor should have recorded events
        let counts = await monitor.getCounts()
        XCTAssertGreaterThan(counts.borrows, 0)
        XCTAssertGreaterThan(counts.returns, 0)
    }
    
    func testThreadSafetyStressTest() async throws {
        // Stress test to ensure no data races or crashes
        let iterations = 100
        let concurrency = 10
        
        await withTaskGroup(of: Void.self) { group in
            // Concurrent configuration changes
            for i in 0..<concurrency {
                group.addTask {
                    for j in 0..<iterations {
                        if j % 3 == 0 {
                            await ContextPoolConfiguration.shared.updatePoolSize(50 + i)
                        } else if j % 3 == 1 {
                            await ContextPoolConfiguration.shared.enablePooling(j % 2 == 0)
                        } else {
                            _ = await ContextPoolConfiguration.shared.poolSize
                        }
                    }
                }
            }
            
            // Concurrent pool usage
            for _ in 0..<concurrency {
                group.addTask {
                    let pool = CommandContextPool.shared
                    for _ in 0..<iterations {
                        let ctx = pool.borrow(metadata: StandardCommandMetadata())
                        try? await Task.sleep(nanoseconds: 100_000) // 0.1ms
                        ctx.returnToPool()
                    }
                }
            }
        }
        
        // If we get here without crashes, thread safety is working
        XCTAssertTrue(true)
    }
}