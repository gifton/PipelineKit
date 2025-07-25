import XCTest
@testable import PipelineKit

/// Tests that verify Sendable conformance for Swift 6 concurrency
final class SendableConformanceTests: XCTestCase {
    
    // MARK: - Compile-time Sendable Tests
    
    func testCommandContextPoolIsSendable() {
        // This test verifies CommandContextPool satisfies Sendable at compile time
        func requiresSendable<T: Sendable>(_: T.Type) {}
        
        // These should compile without errors
        requiresSendable(CommandContextPool.self)
        requiresSendable(PooledCommandContext.self)
        
        // Verify we can use in Sendable contexts
        let _: any Sendable = CommandContextPool.shared
        let _: any Sendable = CommandContextPool(maxSize: 10)
    }
    
    func testContextPoolMonitorProtocolRequiresSendable() {
        // Verify that all monitors must be Sendable
        struct ValidMonitor: ContextPoolMonitor {
            // This should compile because struct is implicitly Sendable
            func poolDidBorrow(context: CommandContext, hitRate: Double) {}
            func poolDidReturn(context: CommandContext) {}
            func poolDidExpand(newSize: Int) {}
        }
        
        // This verifies the protocol requires Sendable
        let _: any Sendable = ValidMonitor()
    }
    
    // MARK: - Runtime Sendable Tests
    
    func testPoolCanBeSentAcrossActors() async {
        // Define an actor that uses a pool
        actor PoolUser {
            private let pool: CommandContextPool
            
            init(pool: CommandContextPool) {
                self.pool = pool
            }
            
            func usePool() -> Int {
                let ctx = pool.borrow(metadata: StandardCommandMetadata())
                defer { ctx.returnToPool() }
                
                return pool.getStatistics().totalBorrows
            }
        }
        
        // Create pool and send to actor
        let pool = CommandContextPool(maxSize: 20)
        let user = PoolUser(pool: pool)
        
        // Use from actor
        let borrows = await user.usePool()
        XCTAssertGreaterThan(borrows, 0)
    }
    
    func testPooledContextCanBeSentAcrossIsolation() async {
        // This verifies PooledCommandContext is Sendable
        let pool = CommandContextPool.shared
        let context = pool.borrow(metadata: StandardCommandMetadata())
        
        // Send across isolation boundary
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // Access context from different task
                let value = context.value
                return (value.commandMetadata.correlationId?.count ?? 0) > 0
            }
            
            let result = await group.next() ?? false
            XCTAssertTrue(result)
        }
        
        context.returnToPool()
    }
    
    func testConcurrentPoolAccess() async {
        // Verify thread safety with concurrent access
        let pool = CommandContextPool(maxSize: 50)
        let iterations = 100
        
        // Concurrent borrows and returns
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    for j in 0..<iterations {
                        let metadata = StandardCommandMetadata(
                            userId: "user-\(i)",
                            correlationId: "task-\(i)-\(j)"
                        )
                        let ctx = pool.borrow(metadata: metadata)
                        
                        // Simulate some work
                        if j % 10 == 0 {
                            try? await Task.sleep(nanoseconds: 100_000) // 0.1ms
                        }
                        
                        ctx.returnToPool()
                    }
                }
            }
        }
        
        // Verify pool is still consistent
        let stats = pool.getStatistics()
        XCTAssertEqual(stats.totalBorrows, 10 * iterations)
        XCTAssertEqual(stats.totalReturns, 10 * iterations)
        XCTAssertEqual(stats.currentlyInUse, 0)
    }
    
    func testConfigurationActorIsSendable() async {
        // ContextPoolConfiguration is an actor, so it's implicitly Sendable
        // This test verifies we can use it correctly
        
        actor ConfigUser {
            func updateConfig() async {
                await ContextPoolConfiguration.shared.updatePoolSize(200)
            }
            
            func readConfig() async -> Int {
                await ContextPoolConfiguration.shared.poolSize
            }
        }
        
        let user = ConfigUser()
        await user.updateConfig()
        let size = await user.readConfig()
        XCTAssertEqual(size, 200)
        
        // Reset
        await ContextPoolConfiguration.shared.reset()
    }
    
    func testMonitorAcrossIsolation() async {
        // Create an actor-based monitor
        actor MetricsMonitor: ContextPoolMonitor {
            private var metrics: [String: Int] = [:]
            
            nonisolated func poolDidBorrow(context: CommandContext, hitRate: Double) {
                Task { await record("borrows") }
            }
            
            nonisolated func poolDidReturn(context: CommandContext) {
                Task { await record("returns") }
            }
            
            nonisolated func poolDidExpand(newSize: Int) {
                Task { await record("expands") }
            }
            
            private func record(_ event: String) {
                metrics[event, default: 0] += 1
            }
            
            func getMetrics() -> [String: Int] {
                metrics
            }
        }
        
        let monitor = MetricsMonitor()
        
        // Install monitor from main isolation
        await ContextPoolConfiguration.shared.installMonitor(monitor)
        
        // Use pool from different isolation
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let pool = CommandContextPool.shared
                for _ in 0..<5 {
                    let ctx = pool.borrow(metadata: StandardCommandMetadata())
                    ctx.returnToPool()
                }
            }
        }
        
        // Brief delay for async monitor updates
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Verify monitor received events across isolation
        let metrics = await monitor.getMetrics()
        XCTAssertGreaterThan(metrics["borrows"] ?? 0, 0)
        XCTAssertGreaterThan(metrics["returns"] ?? 0, 0)
    }
}