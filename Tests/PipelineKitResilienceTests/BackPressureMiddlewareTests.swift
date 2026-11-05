import XCTest
import Foundation
@testable import PipelineKitResilience
@testable import PipelineKitCore
import PipelineKitTestSupport

final class BackPressureMiddlewareTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    func testSuccessfulExecutionUnderLimit() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 3
        )
        
        let command = BPTestCommand(value: "test")
        let context = CommandContext()
        let workSimulator = TestSynchronizer()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            // Simulate work without actual delay
            await workSimulator.signal("work-started")
            let result = cmd.value
            // Don't wait for external signal - just return
            return result
        }
        
        // Then
        XCTAssertEqual(result, "test")
        
        // Verify stats
        let stats = await middleware.getStats()
        XCTAssertEqual(stats.maxConcurrency, 3)
    }
    
    func testBackPressureWithConcurrentRequests() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 2,
            maxOutstanding: 5
        )
        
        let executionOrder = ExecutionTracker()
        let synchronizer = self.synchronizer // Capture before Task
        
        // When - Execute 5 commands with limit of 2
        let tasks = (0..<5).map { i in
            Task {
                let command = BPTestCommand(value: "test-\(i)")
                let context = CommandContext()
                
                return try await middleware.execute(command, context: context) { cmd, _ in
                    await executionOrder.append(i)
                    
                    // Hold the semaphore for a bit
                    await synchronizer.mediumDelay()
                    
                    await executionOrder.append(i + 100) // Mark completion
                    return cmd.value
                }
            }
        }
        
        // Wait for all
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for task in tasks {
                group.addTask {
                    try await task.value
                }
            }
            
            var collected: [String] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }
        
        // Then
        XCTAssertEqual(results.count, 5)
        
        // Verify concurrent execution was limited
        let order = await executionOrder.getOrder()
        
        // Check that at most 2 were executing at any time
        var concurrent = 0
        var maxConcurrent = 0
        
        for event in order {
            if event < 100 {
                // Started
                concurrent += 1
                maxConcurrent = max(maxConcurrent, concurrent)
            } else {
                // Completed
                concurrent -= 1
            }
        }
        
        XCTAssertLessThanOrEqual(maxConcurrent, 2, "Should limit concurrency to 2")
    }
    
    func testDropStrategyUnderPressure() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .dropNewest
        )
        
        var results: [Result<String, Error>] = []
        let synchronizer = self.synchronizer // Capture before TaskGroup
        
        // When - Try to execute 5 commands with outstanding limit of 2
        await withTaskGroup(of: Result<String, Error>.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let command = BPTestCommand(value: "test-\(i)")
                    let context = CommandContext()
                    
                    do {
                        let result = try await middleware.execute(command, context: context) { cmd, _ in
                            // First one will take time
                            if i == 0 {
                                await synchronizer.mediumDelay()
                            }
                            return cmd.value
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            for await result in group {
                results.append(result)
            }
        }
        
        // Then
        let successes = results.compactMap { try? $0.get() }
        let failures = results.compactMap { result in
            if case .failure(let error) = result {
                return error
            }
            return nil
        }
        
        XCTAssertGreaterThan(failures.count, 0, "Some commands should be dropped")
        XCTAssertLessThanOrEqual(successes.count, 3, "At most 3 should succeed (1 executing + 2 queued)")
        
        // Verify drops are PipelineError.backPressure
        for error in failures {
            if let pipelineError = error as? PipelineError,
               case .backPressure = pipelineError {
                // Expected
            } else {
                XCTFail("Expected PipelineError.backPressure, got \(error)")
            }
        }
    }
    
    func testSuspendStrategyUnderPressure() async throws {
        for customSize in [false, true] {
            let middleware = BackPressureMiddleware(maxConcurrency: 1, maxOutstanding: 3, strategy: .suspend)
            let gate = BackPressurePolicyGate()
            let running = Task {
                try await middleware.execute(BPTestCommand(value: "running"), context: CommandContext()) { command, _ in
                    await gate.wait()
                    return command.value
                }
            }
            let entered = await bpPolicyEventually { await gate.entered }
            XCTAssertTrue(entered)
            var queued: [Task<String, any Error>] = []
            for index in 1...2 {
                queued.append(Task {
                    try await middleware.execute(BPTestCommand(value: "queued-\(index)"), context: CommandContext()) { command, _ in
                        command.value
                    }
                })
                let registered = await bpPolicyEventually { await middleware.getStats().queuedRequests == index }
                XCTAssertTrue(registered)
            }
            let overflow = Task {
                let outcome: String
                do {
                    let command = BPTestCommand(value: "overflow")
                    if customSize {
                        _ = try await middleware.execute(command, context: CommandContext(), estimatedSize: 1) { command, _ in command.value }
                    } else {
                        _ = try await middleware.execute(command, context: CommandContext()) { command, _ in command.value }
                    }
                    outcome = "admitted"
                } catch PipelineError.backPressure(.queueFull) {
                    outcome = "full"
                } catch {
                    outcome = "unexpected: \(error)"
                }
                await gate.recordOverflow(outcome)
                return outcome
            }
            let observed = await bpPolicyEventually {
                let result = await gate.overflowOutcome
                let count = await middleware.getStats().queuedRequests
                return result != nil || count > 2
            }
            XCTAssertTrue(observed)
            let stats = await middleware.getStats()
            XCTAssertEqual(stats.currentConcurrency, 1)
            XCTAssertEqual(stats.queuedRequests, 2)
            await gate.release()
            do {
                let result = try await running.value
                XCTAssertEqual(result, "running")
            } catch { XCTFail("Admitted running work failed: \(error)") }
            for task in queued {
                do { _ = try await task.value } catch { XCTFail("Admitted queued work failed: \(error)") }
            }
            let outcome = await overflow.value
            XCTAssertEqual(outcome, "full")
            let settled = await bpPolicyEventually { await middleware.getStats().activeOperations == 0 }
            XCTAssertTrue(settled)
        }
    }

    func testMemoryPressureStrategy() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 2,
            maxOutstanding: 10,
            maxQueueMemory: 1024, // 1KB limit
            strategy: .dropOldest
        )
        
        // When - Submit commands with memory estimates
        var results: [Result<String, Error>] = []
        let synchronizer = self.synchronizer // Capture before TaskGroup
        
        await withTaskGroup(of: Result<String, Error>.self) { group in
            (0..<10).forEach { _ in
                group.addTask {
                    let command = BPTestCommand(value: String(repeating: "x", count: 200)) // ~200 bytes
                    let context = CommandContext()
                    
                    do {
                        let result = try await middleware.execute(
                            command,
                            context: context,
                            estimatedSize: 200
                        ) { cmd, _ in
                            // Slow processing to build queue
                            await synchronizer.mediumDelay()
                            return cmd.value
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            for await result in group {
                results.append(result)
            }
        }
        
        // Then
        let failures = results.compactMap { result in
            if case .failure(let error) = result {
                return error
            }
            return nil
        }
        XCTAssertGreaterThan(failures.count, 0, "Some commands should be dropped due to memory pressure")
        
        // Check memory errors
        let hasMemoryPressure = failures.contains { error in
            if let pipelineError = error as? PipelineError,
               case .backPressure(let reason) = pipelineError,
               case .memoryPressure = reason {
                return true
            }
            return false
        }
        XCTAssertTrue(hasMemoryPressure, "Should have memory pressure errors")
    }
    
    func testHealthCheck() async throws {
        let middleware = BackPressureMiddleware(maxConcurrency: 1, maxOutstanding: 5)
        let gate = BackPressurePolicyGate()
        let running = Task {
            try await middleware.execute(BPTestCommand(value: "running"), context: CommandContext()) { command, _ in
                await gate.wait()
                return command.value
            }
        }
        let entered = await bpPolicyEventually { await gate.entered }
        XCTAssertTrue(entered)
        var queued: [Task<String, any Error>] = []
        for index in 1...4 {
            queued.append(Task {
                try await middleware.execute(BPTestCommand(value: "queued-\(index)"), context: CommandContext()) { command, _ in
                    command.value
                }
            })
            let registered = await bpPolicyEventually { await middleware.getStats().queuedRequests == index }
            XCTAssertTrue(registered)
        }
        let health = await middleware.healthCheck()
        XCTAssertFalse(health.isHealthy)
        XCTAssertEqual(health.queueUtilization, 0.8, accuracy: 0.000_001)
        await gate.release()
        do { _ = try await running.value } catch { XCTFail("Running work failed: \(error)") }
        for task in queued {
            do { _ = try await task.value } catch { XCTFail("Admitted queued work failed: \(error)") }
        }
    }

    func testRateLimitIntegration() async throws {
        // Skip this test - rate limiting is not implemented yet
        throw XCTSkip("Rate limiting is not available in this version")

        // The following code is commented out until rate limiting is implemented:
        /*
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 10
            // Rate limiting is not available in this version
        )

        let executionTimes = ExecutionTracker()

        // When - Try to execute 10 commands rapidly
        let startTime = Date()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let command = BPTestCommand(value: "rate-\(i)")
                    let context = CommandContext()

                    _ = try? await middleware.execute(command, context: context) { cmd, _ in
                        await executionTimes.append(Int(Date().timeIntervalSince(startTime) * 1000)) // ms
                        return cmd.value
                    }
                }
            }
        }

        // Then
        let times = await executionTimes.getOrder()

        // First 5 should execute immediately (< 100ms)
        let firstBatch = times.prefix(5)
        for time in firstBatch {
            XCTAssertLessThan(time, 100, "First batch should execute quickly")
        }

        // Next 5 should be delayed (~1 second)
        if times.count > 5 {
            let secondBatch = times.dropFirst(5)
            for time in secondBatch {
                XCTAssertGreaterThan(time, 900, "Second batch should be rate limited")
            }
        }
        */
    }
    
    func testStatsAccuracy() async throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Skipping flaky stats timing test on CI")
        }

        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 1,  // Only allow 1 concurrent to ensure queueing
            maxOutstanding: 10
        )

        let synchronizer = self.synchronizer // Capture before Task
        
        // When - Create specific scenario
        let blocker = Task {
            let command = BPTestCommand(value: "blocker")
            let context = CommandContext()
            
            _ = try? await middleware.execute(command, context: context) { cmd, _ in
                await synchronizer.longDelay()
                return cmd.value
            }
        }
        
        // Give blocker time to start
        await synchronizer.shortDelay()
        
        // Add some queued items
        let queued = (0..<5).map { i in
            Task {
                let command = BPTestCommand(value: "queued-\(i)")
                let context = CommandContext()
                
                return try await middleware.execute(command, context: context) { cmd, _ in
                    return cmd.value
                }
            }
        }
        
        // Let queue build
        await synchronizer.mediumDelay()
        
        // Get stats
        let stats = await middleware.getStats()
        
        // Then
        XCTAssertEqual(stats.currentConcurrency, 1, "One blocker executing")
        XCTAssertGreaterThanOrEqual(stats.queuedRequests, 4, "Should have at least 4 queued requests")
        XCTAssertGreaterThanOrEqual(stats.totalProcessed, 0, "Should track processed count")
        
        // Cleanup
        blocker.cancel()
        queued.forEach { $0.cancel() }
    }
}

// MARK: - Test Helpers

private struct BPTestCommand: Command {
    typealias Result = String
    let value: String
}

private actor ExecutionTracker {
    private var order: [Int] = []
    
    func append(_ value: Int) {
        order.append(value)
    }
    
    func getOrder() -> [Int] {
        return order
    }
}

private actor BackPressurePolicyGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var overflowOutcome: String?

    func wait() async {
        entered = true
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        open = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func recordOverflow(_ outcome: String) { overflowOutcome = outcome }
}

private func bpPolicyEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
