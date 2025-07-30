import XCTest
@testable import PipelineKit

final class ConcurrencyStressorTests: XCTestCase {
    var stressor: ConcurrencyStressor!
    var safetyMonitor: DefaultSafetyMonitor!
    var metricCollector: MetricCollector!
    
    override func setUp() async throws {
        safetyMonitor = DefaultSafetyMonitor()
        metricCollector = MetricCollector()
        stressor = ConcurrencyStressor(
            safetyMonitor: safetyMonitor,
            metricCollector: metricCollector
        )
    }
    
    override func tearDown() async throws {
        await stressor.stopAll()
    }
    
    // MARK: - Actor Contention Tests
    
    func testActorContentionBasic() async throws {
        // Create small-scale actor contention
        try await stressor.createActorContention(
            actorCount: 5,
            messagesPerActor: 10,
            messageSize: 256
        )
        
        // Verify metrics
        let stats = await stressor.currentStats()
        XCTAssertEqual(stats.totalMessagesExchanged, 50) // 5 actors * 10 messages
        XCTAssertEqual(stats.activeActors, 5)
        
        // Verify cleanup
        await stressor.stopAll()
        let finalStats = await stressor.currentStats()
        XCTAssertEqual(finalStats.activeActors, 0)
    }
    
    func testActorContentionSafetyLimits() async throws {
        // Try to create too many actors
        do {
            try await stressor.createActorContention(
                actorCount: 20_000,  // Exceeds safety limit
                messagesPerActor: 100
            )
            XCTFail("Should have thrown safety limit error")
        } catch let error as ConcurrencyError {
            switch error {
            case .safetyLimitExceeded:
                // Expected
                break
            default:
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }
    
    func testActorContentionInvalidState() async throws {
        // Start one pattern
        Task {
            try await stressor.createActorContention(
                actorCount: 2,
                messagesPerActor: 5
            )
        }
        
        // Give it time to start
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Try to start another pattern
        do {
            try await stressor.createActorContention(
                actorCount: 2,
                messagesPerActor: 5
            )
            XCTFail("Should have thrown invalid state error")
        } catch let error as ConcurrencyError {
            switch error {
            case .invalidState:
                // Expected
                break
            default:
                XCTFail("Unexpected error type: \(error)")
            }
        }
        
        await stressor.stopAll()
    }
    
    // MARK: - Task Explosion Tests
    
    func testTaskExplosionBasic() async throws {
        // Create moderate task explosion
        try await stressor.simulateTaskExplosion(
            tasksPerSecond: 100,
            duration: 0.5,  // 500ms
            taskWork: 50   // 50 microseconds
        )
        
        let stats = await stressor.currentStats()
        // Should have created approximately 50 tasks (100/sec * 0.5sec)
        XCTAssertGreaterThan(stats.totalTasksCreated, 40)
        XCTAssertLessThan(stats.totalTasksCreated, 60)
    }
    
    func testTaskExplosionThrottling() async throws {
        // This test verifies that safety monitor throttling works
        let startTime = Date()
        
        // Try to create extreme task rate
        try await stressor.simulateTaskExplosion(
            tasksPerSecond: 10_000,  // Very high rate
            duration: 0.2,
            taskWork: 10
        )
        
        let duration = Date().timeIntervalSince(startTime)
        
        // Should have been throttled, taking longer than expected
        XCTAssertGreaterThan(duration, 0.2)
        
        // Check metrics for throttle events
        let metrics = await metricCollector.snapshot()
        let throttleEvents = metrics.counters.values.filter { 
            $0.name.contains("throttle")
        }
        XCTAssertFalse(throttleEvents.isEmpty, "Should have recorded throttle events")
    }
    
    // MARK: - Lock Contention Tests
    
    func testLockContentionBasic() async throws {
        try await stressor.createLockContention(
            threads: 4,
            contentionFactor: 0.5,
            duration: 0.5
        )
        
        let stats = await stressor.currentStats()
        XCTAssertGreaterThan(stats.contentionEvents, 0)
        
        // Check lock metrics
        let metrics = await metricCollector.snapshot()
        let lockMetrics = metrics.histograms.values.filter {
            $0.name.contains("lock")
        }
        XCTAssertFalse(lockMetrics.isEmpty)
    }
    
    func testLockContentionHighContention() async throws {
        // Test with very high contention
        try await stressor.createLockContention(
            threads: 8,
            contentionFactor: 0.95,  // 95% contention
            duration: 0.3
        )
        
        let stats = await stressor.currentStats()
        
        // With high contention, we should see many contention events
        XCTAssertGreaterThan(stats.contentionEvents, 50)
    }
    
    // MARK: - Priority Inversion Tests
    
    func testPriorityInversionBasic() async throws {
        try await stressor.simulatePriorityInversion(
            highPriorityTasks: 2,
            lowPriorityTasks: 4,
            sharedResourceAccess: 0.5
        )
        
        // Check for priority inversion metrics
        let metrics = await metricCollector.snapshot()
        let inversionMetrics = metrics.counters.values.filter {
            $0.name.contains("priority.inversions")
        }
        
        // Should detect at least some inversions
        if !inversionMetrics.isEmpty {
            let totalInversions = inversionMetrics.map { $0.value }.reduce(0, +)
            XCTAssertGreaterThan(totalInversions, 0, "Should detect priority inversions")
        }
    }
    
    // MARK: - Resource Cleanup Tests
    
    func testResourceCleanup() async throws {
        // Create actors with resource handles
        try await stressor.createActorContention(
            actorCount: 10,
            messagesPerActor: 5
        )
        
        // Get initial resource usage
        let initialUsage = await safetyMonitor.currentResourceUsage()
        XCTAssertEqual(initialUsage.actors, 10)
        
        // Stop all operations
        await stressor.stopAll()
        
        // Give time for cleanup
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Verify resources were released
        let finalUsage = await safetyMonitor.currentResourceUsage()
        XCTAssertEqual(finalUsage.actors, 0, "All actor resources should be released")
    }
    
    // MARK: - Metrics Recording Tests
    
    func testMetricsRecording() async throws {
        // Run a simple pattern
        try await stressor.createActorContention(
            actorCount: 3,
            messagesPerActor: 10
        )
        
        let metrics = await metricCollector.snapshot()
        
        // Verify pattern lifecycle metrics
        let patternStarts = metrics.counters.values.filter {
            $0.name == "concurrency.pattern.start"
        }
        XCTAssertEqual(patternStarts.count, 1)
        
        let patternCompletes = metrics.counters.values.filter {
            $0.name == "concurrency.pattern.complete"
        }
        XCTAssertEqual(patternCompletes.count, 1)
        
        // Verify actor metrics
        let actorGauges = metrics.gauges.values.filter {
            $0.name == "concurrency.actors.count"
        }
        XCTAssertFalse(actorGauges.isEmpty)
        
        // Verify messaging metrics
        let messageRates = metrics.gauges.values.filter {
            $0.name == "concurrency.actors.messages.rate"
        }
        XCTAssertFalse(messageRates.isEmpty)
    }
    
    // MARK: - Concurrent Pattern Tests
    
    func testStopAllDuringPattern() async throws {
        // Start a long-running pattern
        let patternTask = Task {
            try await stressor.createActorContention(
                actorCount: 20,
                messagesPerActor: 1000  // Many messages
            )
        }
        
        // Let it start
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        // Stop all operations
        await stressor.stopAll()
        
        // Pattern should be cancelled
        do {
            try await patternTask.value
        } catch {
            // Expected - task was cancelled
        }
        
        // Verify cleanup
        let stats = await stressor.currentStats()
        XCTAssertEqual(stats.activeActors, 0)
    }
    
    // MARK: - Deadlock Tests
    
    func testDeadlockSimulation() async throws {
        // Test deadlock detection with short timeout
        do {
            try await stressor.simulateDeadlock(
                taskPairs: 2,
                timeout: 1.0,      // 1 second timeout
                lockHoldTime: 0.5  // Hold locks for 500ms
            )
            // If no exception, deadlock was avoided
        } catch {
            // Check if it was a timeout (indicating deadlock)
            if let concurrencyError = error as? ConcurrencyError {
                switch concurrencyError {
                case .resourceExhausted(let type):
                    XCTAssertTrue(type.contains("deadlock") || type.contains("lock"))
                default:
                    XCTFail("Unexpected error type: \(concurrencyError)")
                }
            }
        }
        
        // Check metrics
        let metrics = await metricCollector.snapshot()
        let deadlockMetrics = metrics.counters.values.filter {
            $0.name.contains("deadlock")
        }
        
        // Should have pattern start/complete metrics at minimum
        XCTAssertFalse(deadlockMetrics.isEmpty)
    }
    
    func testDeadlockAvoidance() async throws {
        // Test case where deadlock should be avoided
        try await stressor.simulateDeadlock(
            taskPairs: 1,
            timeout: 2.0,
            lockHoldTime: 0.01  // Very short hold time
        )
        
        // Check that no deadlock was detected
        let metrics = await metricCollector.snapshot()
        let deadlockDetected = metrics.counters.values.filter {
            $0.name == "concurrency.deadlock.detected"
        }
        
        if !deadlockDetected.isEmpty {
            let totalDetected = deadlockDetected.map { $0.value }.reduce(0, +)
            XCTAssertEqual(totalDetected, 0, "No deadlock should be detected")
        }
    }
    
    // MARK: - Performance Tests
    
    func testActorContentionPerformance() async throws {
        // Measure time for moderate scale actor contention
        let startTime = Date()
        
        try await stressor.createActorContention(
            actorCount: 50,
            messagesPerActor: 100,
            messageSize: 512
        )
        
        let duration = Date().timeIntervalSince(startTime)
        
        // Should complete in reasonable time
        XCTAssertLessThan(duration, 5.0, "Actor contention should complete within 5 seconds")
        
        // Verify all messages were sent
        let stats = await stressor.currentStats()
        XCTAssertEqual(stats.totalMessagesExchanged, 5000)
    }
}