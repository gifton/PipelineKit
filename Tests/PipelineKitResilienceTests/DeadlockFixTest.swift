import XCTest
@testable import PipelineKitResilience
@testable import PipelineKitCore

final class DeadlockFixTest: XCTestCase {
    /// Test that verifies the lost wakeup bug is fixed
    func testNoDeadlockWithConcurrentQueueing() async throws {
        // Given - Aggressive settings to trigger the race condition
        let middleware = BackPressureMiddleware(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .suspend
        )
        
        let context = CommandContext()
        
        // When - Execute multiple concurrent commands that will queue
        // This should have deadlocked before the fix
        let results = await withTaskGroup(of: String?.self) { group in
            // Launch 5 concurrent tasks
            for i in 0..<5 {
                group.addTask { @Sendable in
                    do {
                        let command = TestCommand(
                            id: i,
                            delay: i == 0 ? 0.05 : 0.01 // First takes longer
                        )
                        let result = try await middleware.execute(command, context: context) { cmd, _ in
                            // Simulate work
                            try await Task.sleep(nanoseconds: UInt64(cmd.delay * 1_000_000_000))
                            return "completed-\(cmd.id)"
                        }
                        return result
                    } catch {
                        // Expected for commands that exceed outstanding limit
                        return nil
                    }
                }
            }
            
            // Collect results with timeout
            var collected: [String] = []
            for await result in group {
                if let result = result {
                    collected.append(result)
                }
            }
            return collected
        }
        
        // Then - At least some commands should complete
        // Before the fix, this would hang forever
        XCTAssertGreaterThan(results.count, 0, "Some commands should complete")
        XCTAssertLessThanOrEqual(results.count, 5, "No more than 5 can complete")
    }
    
    /// Test rapid permit acquire/release cycles
    func testRapidAcquireRelease() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 2,
            maxOutstanding: 4,
            strategy: .suspend
        )
        
        let context = CommandContext()
        
        // When - Rapid fire acquire/release
        let results = await withTaskGroup(of: Int.self) { group in
            for i in 0..<20 {
                group.addTask { @Sendable in
                    do {
                        let command = TestCommand(id: i, delay: 0.001) // Very short
                        _ = try await middleware.execute(command, context: context) { cmd, _ in
                            try await Task.sleep(nanoseconds: UInt64(cmd.delay * 1_000_000_000))
                            return "done"
                        }
                        return 1
                    } catch {
                        return 0
                    }
                }
            }
            
            var total = 0
            for await result in group {
                total += result
            }
            return total
        }
        
        // The strict outstanding limit admits four initial operations; settled
        // work may free slots before later submissions reach admission.
        XCTAssertGreaterThanOrEqual(results, 4, "The initial capacity should complete")
        XCTAssertLessThanOrEqual(results, 20, "At most 20 commands can complete")
        let stats = await middleware.getStats()
        XCTAssertEqual(stats.activeOperations, 0)
        XCTAssertEqual(stats.queuedRequests, 0)
    }
    
    /// Test that drop strategies still work after deadlock fix
    func testDropStrategiesStillWork() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .dropNewest
        )
        
        let context = CommandContext()
        // Admitted handlers wait at this gate, so nothing completes and frees capacity
        // while the five commands arrive. With 10-100ms sleeps as the work, a runner
        // that started the tasks far enough apart let each one finish before the next
        // arrived, and nothing was dropped.
        let gate = DropGate()
        // If nothing is ever dropped, open the gate anyway so the assertion below
        // fails instead of the test hanging.
        let fallback = Task {
            try? await Task.sleep(for: .seconds(10))
            await gate.release()
        }
        defer { fallback.cancel() }
        
        // When - Send more than outstanding limit
        let dropped = await withTaskGroup(of: Int.self) { group in
            for i in 0..<5 {
                group.addTask { @Sendable in
                    do {
                        let command = TestCommand(
                            id: i,
                            delay: i == 0 ? 0.1 : 0.01
                        )
                        _ = try await middleware.execute(command, context: context) { _, _ in
                            await gate.wait()
                            return "done"
                        }
                        return 0
                    } catch {
                        if let pipelineError = error as? PipelineError,
                           case .backPressure(let reason) = pipelineError,
                           case .commandDropped = reason {
                            return 1
                        }
                        return 0
                    }
                }
            }
            
            var total = 0
            for await count in group {
                total += count
                // The first drop is the behaviour under test; let the admitted work finish.
                if count > 0 { await gate.release() }
            }
            return total
        }
        
        // Then - Some should be dropped per strategy
        XCTAssertGreaterThan(dropped, 0, "Some commands should be dropped")
    }
}

private struct TestCommand: Command, Sendable {
    typealias Result = String
    let id: Int
    let delay: TimeInterval
}

/// Holds any number of waiters until released.
private actor DropGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
