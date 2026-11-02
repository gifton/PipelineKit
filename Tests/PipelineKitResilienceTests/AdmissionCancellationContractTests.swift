import XCTest
import Synchronization
@testable import _ResilienceFoundation
import PipelineKit
import PipelineKitResilience

private final class SemaphoreWallClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_000))
    func now() -> Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0.addTimeInterval(seconds) } }
}

private struct SemaphoreAdmissionCommand: Command { typealias Result = Int }

private actor SemaphoreAdmissionLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0
    func wait() async {
        entered += 1
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct SemaphoreAdmissionHandler: CommandHandler {
    let latch: SemaphoreAdmissionLatch
    func handle(_ command: SemaphoreAdmissionCommand, context: CommandContext) async throws -> Int {
        await latch.wait()
        return 7
    }
}

private func signalThenCancel<Value: Sendable, Failure: Error>(
    _ semaphore: isolated AsyncSemaphore, task: Task<Value, Failure>
) {
    // One actor turn forces signal to remove/resume before cancellation can remove.
    semaphore.signal()
    task.cancel()
}

final class AdmissionCancellationContractTests: XCTestCase {
    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    func testAsyncSemaphoreCancellationSchedulesForBothWaitPaths() async throws {
        for timed in [false, true] {
            for schedule in 0..<3 {
                let semaphore = AsyncSemaphore(value: schedule == 0 ? 1 : 0)
                let start = SemaphoreAdmissionLatch()
                let task = Task { () -> Bool in
                    await start.wait()
                    if timed { return await semaphore.acquire(timeout: 60) }
                    do { try await semaphore.wait(); return true } catch { return false }
                }
                if schedule == 0 { task.cancel() }
                await start.release()
                if schedule != 0 {
                    let registered = await eventually { await semaphore.waiterCount() == 1 }
                    XCTAssertTrue(registered)
                    if schedule == 1 { task.cancel() }
                    else { await signalThenCancel(semaphore, task: task) }
                }
                let acquired = await task.value
                XCTAssertFalse(acquired, "timed=\(timed), schedule=\(schedule)")
                let count = await semaphore.waiterCount()
                let resources = await semaphore.availableResourcesCount()
                XCTAssertEqual(count, 0)
                XCTAssertEqual(resources, schedule == 1 ? 0 : 1)
            }
        }
    }

    func testPreCancelledBackPressureAcquisitionDoesNotConsumeFreePermit() async throws {
        let semaphore = BackPressureSemaphore(maxConcurrency: 1)
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let token = try await semaphore.acquire()
                token.release()
                return true
            } catch is CancellationError { return false }
            catch { XCTFail("Unexpected cancellation error: \(error)"); return false }
        }
        let acquired = await task.value
        XCTAssertFalse(acquired)
        let recovered = await eventually { await semaphore.getStats().availableResources == 1 }
        XCTAssertTrue(recovered)
        await semaphore.shutdown()
    }

    func testOrdinaryExecutionHonorsStrategyDeadlineWithinAndBeyondOutstandingLimit() async throws {
        for limit in [1, 2] {
            let pipeline = ConcurrentPipeline(options: PipelineOptions(
                maxConcurrency: 1, maxOutstanding: limit, backPressureStrategy: .error(timeout: 0)
            ))
            let latch = SemaphoreAdmissionLatch()
            await pipeline.register(SemaphoreAdmissionCommand.self, pipeline: StandardPipeline(handler: SemaphoreAdmissionHandler(latch: latch)))
            let running = Task { try await pipeline.execute(SemaphoreAdmissionCommand()) }
            let entered = await eventually { await latch.entered == 1 }
            XCTAssertTrue(entered)
            let finished = expectation(description: "ordinary admission deadline")
            let rejected = Task {
                do {
                    _ = try await pipeline.execute(SemaphoreAdmissionCommand())
                    XCTFail("Saturated ordinary execution must time out")
                } catch let error as PipelineError {
                    guard case .backPressure(.timeout(let duration)) = error else {
                        XCTFail("Expected back-pressure timeout, got \(error)")
                        finished.fulfill()
                        return
                    }
                    XCTAssertEqual(duration, 0)
                } catch { XCTFail("Expected back-pressure timeout, got \(error)") }
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 1)
            rejected.cancel()
            await rejected.value
            let stats = await pipeline.getCapacityStats()
            XCTAssertEqual(stats.activeOperations, 1)
            XCTAssertEqual(stats.queuedOperations, 0)
            let handlerCount = await latch.entered
            XCTAssertEqual(handlerCount, 1)
            await latch.release()
            _ = try await running.value
        }
    }

    func testUnlimitedPresetAdmitsMoreThanDefaultConcurrency() async throws {
        let pipeline = ConcurrentPipeline(options: .unlimited())
        let latch = SemaphoreAdmissionLatch()
        await pipeline.register(SemaphoreAdmissionCommand.self, pipeline: StandardPipeline(handler: SemaphoreAdmissionHandler(latch: latch)))
        let tasks = (0..<12).map { _ in Task { try await pipeline.execute(SemaphoreAdmissionCommand()) } }
        let allEntered = await eventually { await latch.entered == 12 }
        XCTAssertTrue(allEntered)
        let stats = await pipeline.getCapacityStats()
        XCTAssertEqual(stats.activeOperations, 12)
        XCTAssertEqual(stats.queuedOperations, 0)
        XCTAssertNil(stats.maxOutstanding)
        let atCapacity = await pipeline.isAtCapacity()
        XCTAssertFalse(atCapacity)
        await latch.release()
        for task in tasks { _ = try await task.value }
    }

    func testUnlimitedConcurrencyStillEnforcesFiniteOutstandingLimit() async throws {
        let pipeline = ConcurrentPipeline(options: PipelineOptions(
            maxConcurrency: nil, maxOutstanding: 1, backPressureStrategy: .error(timeout: nil)
        ))
        let latch = SemaphoreAdmissionLatch()
        await pipeline.register(SemaphoreAdmissionCommand.self, pipeline: StandardPipeline(handler: SemaphoreAdmissionHandler(latch: latch)))
        let running = Task { try await pipeline.execute(SemaphoreAdmissionCommand()) }
        let entered = await eventually { await latch.entered == 1 }
        XCTAssertTrue(entered)
        let completed = expectation(description: "finite outstanding rejection")
        let rejected = Task {
            do {
                _ = try await pipeline.execute(SemaphoreAdmissionCommand())
                XCTFail("Finite outstanding limit must reject excess admission")
            } catch let error as PipelineError {
                guard case .backPressure(.queueFull(let current, let limit)) = error else {
                    XCTFail("Expected queue full, got \(error)")
                    completed.fulfill()
                    return
                }
                XCTAssertEqual(current, 2)
                XCTAssertEqual(limit, 1)
            } catch { XCTFail("Unexpected error: \(error)") }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        await latch.release()
        _ = try await running.value
        await rejected.value
    }

    func testTimedQueueReleasesOwnershipAndKeepsHandlerPermitUntilSettlement() async throws {
        let pipeline = ConcurrentPipeline(options: PipelineOptions(
            maxConcurrency: 1, maxOutstanding: 2, backPressureStrategy: .error(timeout: 0.01)
        ))
        let latch = SemaphoreAdmissionLatch()
        await pipeline.register(SemaphoreAdmissionCommand.self, pipeline: StandardPipeline(handler: SemaphoreAdmissionHandler(latch: latch)))
        let running = Task { try await pipeline.execute(SemaphoreAdmissionCommand()) }
        let entered = await eventually { await latch.entered == 1 }
        XCTAssertTrue(entered)
        running.cancel() // The handler deliberately waits for settlement despite cancellation.
        do {
            _ = try await pipeline.execute(SemaphoreAdmissionCommand())
            XCTFail("Admission should expire while the first handler is still unsettled")
        } catch let error as PipelineError {
            guard case .backPressure(.timeout(let duration)) = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
            XCTAssertEqual(duration, 0.01, accuracy: 0.000001)
        }
        let blocked = await pipeline.getCapacityStats()
        XCTAssertEqual(blocked.activeOperations, 1)
        XCTAssertEqual(blocked.queuedOperations, 0)
        await latch.release()
        _ = try? await running.value
        let recovered = await eventually { await pipeline.getCapacityStats().activeOperations == 0 }
        XCTAssertTrue(recovered)
        let next = try await pipeline.execute(SemaphoreAdmissionCommand())
        XCTAssertEqual(next, 7)
    }

    func testNilOutstandingAllowsQueueBeyondLegacyTenTimesConcurrency() async throws {
        let pipeline = ConcurrentPipeline(options: PipelineOptions(
            maxConcurrency: 1, maxOutstanding: nil, backPressureStrategy: .error(timeout: nil)
        ))
        let latch = SemaphoreAdmissionLatch()
        await pipeline.register(SemaphoreAdmissionCommand.self, pipeline: StandardPipeline(handler: SemaphoreAdmissionHandler(latch: latch)))
        let tasks = (0..<12).map { _ in Task { try await pipeline.execute(SemaphoreAdmissionCommand()) } }
        let queued = await eventually { await pipeline.getCapacityStats().queuedOperations == 11 }
        XCTAssertTrue(queued)
        await latch.release()
        for task in tasks { _ = try await task.value }
        let stats = await pipeline.getCapacityStats()
        XCTAssertNil(stats.maxOutstanding)
    }

    func testBackPressureQueuedCancellationAndGrantConservePermit() async throws {
        for timed in [false, true] {
            let semaphore = BackPressureSemaphore(maxConcurrency: 1)
            let held = try await semaphore.acquire()
            let waiter = Task { () throws -> SemaphoreToken in
                if timed {
                    let token = try await semaphore.acquire(timeout: 60)
                    return try XCTUnwrap(token)
                }
                return try await semaphore.acquire()
            }
            let registered = await eventually { await semaphore.getStats().queuedOperations == 1 }
            XCTAssertTrue(registered)
            waiter.cancel()
            held.release()
            do {
                let token = try await waiter.value
                token.release()
                XCTFail("Cancelled acquisition returned a permit")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            let recovered = await eventually {
                let stats = await semaphore.getStats()
                return stats.availableResources == 1 && stats.queuedOperations == 0 && stats.activeOperations == 0
            }
            XCTAssertTrue(recovered)
            await semaphore.shutdown()
        }
    }

    func testCapacityArithmeticBoundaries() async throws {
        XCTAssertEqual(BackPressureSemaphore.saturatingMultiply(Int.max, by: 10), Int.max)
        XCTAssertEqual(BackPressureSemaphore.saturatingMultiply(Int.max / 2 + 1, by: 2), Int.max)
        XCTAssertEqual(BackPressureSemaphore.saturatingMultiply(3, by: 10), 30)
        XCTAssertEqual(BackPressureSemaphore.saturatingAdd(Int.max, 1), Int.max)
        XCTAssertEqual(BackPressureSemaphore.saturatingAdd(Int.max - 1, 1), Int.max)
        let huge = BackPressureSemaphore(maxConcurrency: Int.max)
        let token = try await huge.acquire()
        let stats = await huge.getStats()
        XCTAssertEqual(stats.maxOutstanding, Int.max)
        XCTAssertEqual(stats.availableResources, Int.max - 1)
        let health = await huge.healthCheck()
        XCTAssertTrue(health.queueUtilization.isFinite)
        token.release()
        await huge.shutdown()

        let empty = BackPressureSemaphore(maxConcurrency: 0, maxOutstanding: 0, maxQueueMemory: 0)
        let emptyHealth = await empty.healthCheck()
        XCTAssertTrue(emptyHealth.queueUtilization.isFinite)
        XCTAssertTrue(emptyHealth.memoryUtilization.isFinite)
        await empty.shutdown()
    }

    func testMemoryBoundaryRejectsAdditionOverflowAndSaturatesUnlimitedStats() async throws {
        for bounded in [true, false] {
            let semaphore = BackPressureSemaphore(
                maxConcurrency: 1, maxOutstanding: 4,
                maxQueueMemory: bounded ? Int.max : nil, strategy: .error(timeout: nil)
            )
            let held = try await semaphore.acquire()
            let first = Task { try await semaphore.acquire(estimatedSize: Int.max) }
            let registered = await eventually { await semaphore.getStats().queuedOperations == 1 }
            XCTAssertTrue(registered)
            let second = Task { try await semaphore.acquire(estimatedSize: 1) }
            if bounded {
                do { _ = try await second.value; XCTFail("Overflow must reject excess queue memory") }
                catch let error as PipelineError {
                    guard case .backPressure(.memoryPressure) = error else {
                        return XCTFail("Expected memory pressure, got \(error)")
                    }
                }
            } else {
                let queued = await eventually { await semaphore.getStats().queuedOperations == 2 }
                XCTAssertTrue(queued)
                let stats = await semaphore.getStats()
                XCTAssertEqual(stats.queueMemoryUsage, Int.max)
            }
            first.cancel()
            second.cancel()
            _ = try? await first.value
            _ = try? await second.value
            held.release()
            await semaphore.shutdown()
        }
    }

    func testValidTimeoutBoundariesAllowImmediateAcquisition() async throws {
        for timeout in [-Double.greatestFiniteMagnitude, -1, 0, 86_400] {
            let semaphore = BackPressureSemaphore(maxConcurrency: 1, strategy: .error(timeout: timeout))
            let configured = try await semaphore.acquire()
            configured.release()
            let restored = await eventually { await semaphore.getStats().availableResources == 1 }
            XCTAssertTrue(restored)
            let explicit = try await semaphore.acquire(timeout: timeout)
            XCTAssertNotNil(explicit)
            explicit?.release()
            await semaphore.shutdown()
        }
    }

    // Invoked in subprocesses by Scripts/validation/check_admission_timeout_bounds.py.
    // The sentinel identifies reaching this exact boundary before its precondition.
    func testTimeoutConfigurationProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["PIPELINEKIT_ADMISSION_TIMEOUT"] else { return }
        let timeout = Double(value)!
        FileHandle.standardError.write(Data("ADMISSION_TIMEOUT_BOUNDARY_REACHED\n".utf8))
        switch environment["PIPELINEKIT_ADMISSION_ENTRY"] {
        case "pipeline":
            _ = ConcurrentPipeline(options: PipelineOptions(backPressureStrategy: .error(timeout: timeout)))
        case "explicit":
            let semaphore = BackPressureSemaphore(maxConcurrency: 1)
            _ = try await semaphore.acquire(timeout: timeout)
        default:
            _ = BackPressureSemaphore(maxConcurrency: 1, strategy: .error(timeout: timeout))
        }
        FileHandle.standardError.write(Data("ADMISSION_TIMEOUT_BOUNDARY_ACCEPTED\n".utf8))
    }

    func testPipelineOptionsDoNotInheritLegacyFiveMinuteCleanup() async throws {
        for strategy: BackPressureStrategy in [.suspend, .error(timeout: nil), .error(timeout: 600)] {
            let clock = SemaphoreWallClock()
            let semaphore = BackPressureSemaphore(options: PipelineOptions(
                maxConcurrency: 1, maxOutstanding: 2, backPressureStrategy: strategy
            ), now: { clock.now() })
            let held = try await semaphore.acquire()
            let waiter = Task { try await semaphore.acquire() }
            let registered = await eventually { await semaphore.getStats().queuedOperations == 1 }
            XCTAssertTrue(registered)
            clock.advance(301)
            await semaphore.cleanupExpiredWaiters()
            let stats = await semaphore.getStats()
            XCTAssertEqual(stats.queuedOperations, 1, "Legacy cleanup shortened \(strategy)")
            waiter.cancel()
            do { _ = try await waiter.value; XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Legacy cleanup replaced cancellation: \(error)") }
            held.release()
            await semaphore.shutdown()
        }
    }
}
