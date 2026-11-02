import XCTest
import PipelineKitCore
import _ResilienceFoundation
@testable import PipelineKitResilience

final class BulkheadMiddlewareTests: XCTestCase {
    // MARK: - Synchronization Helpers

    /// Actor-based signal for coordinating between tasks
    private actor Signal {
        private var triggered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func trigger() {
            triggered = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
        }

        func wait() async {
            if triggered { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    // MARK: - Test Commands

    private struct SlowCommand: Command {
        typealias Result = String
        let id: Int
        let duration: TimeInterval

        func execute() async throws -> String {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return "Command \(id) completed"
        }
    }

    /// A slow command that signals when it has started executing
    private struct SignalingSlowCommand: Command {
        typealias Result = String
        let id: Int
        let duration: TimeInterval
        let startedSignal: Signal

        func execute() async throws -> String {
            await startedSignal.trigger()
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return "Command \(id) completed"
        }
    }

    private struct FastCommand: Command {
        typealias Result = String
        let id: Int

        func execute() async throws -> String {
            "Command \(id) completed"
        }
    }

    private struct FailingCommand: Command {
        typealias Result = String

        func execute() async throws -> String {
            throw TestError.expectedFailure
        }
    }

    private enum TestError: Error {
        case expectedFailure
        case timeout
    }

    // MARK: - Tests

    func testConcurrencyLimiting() async throws {
        // Given - Need to enable queueing for all commands to succeed
        let maxConcurrency = 2
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: maxConcurrency,
                maxQueueSize: 2,  // Allow 2 commands to queue
                rejectionPolicy: .queue
            )
        )

        let commandDuration: TimeInterval = 0.1
        let commands = (0..<4).map { SlowCommand(id: $0, duration: commandDuration) }

        let startTime = Date()

        // When - execute commands concurrently
        let results = await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
            for (index, command) in commands.enumerated() {
                group.addTask {
                    do {
                        let result = try await middleware.execute(command, context: CommandContext()) { cmd, _ in
                            try await cmd.execute()
                        }
                        return (index, .success(result))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            var results: [(Int, Result<String, Error>)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }
        }

        let totalTime = Date().timeIntervalSince(startTime)

        // Then - should take at least 2 batches
        XCTAssertGreaterThanOrEqual(totalTime, commandDuration * 1.8) // Allow some tolerance

        // All commands should succeed
        for (index, result) in results {
            switch result {
            case .success(let value):
                XCTAssertEqual(value, "Command \(index) completed")
            case .failure(let error):
                XCTFail("Command \(index) failed: \(error)")
            }
        }
    }

    func testFailFastRejectionPolicy() async throws {
        // Given
        let middleware = BulkheadMiddleware(
            maxConcurrency: 1,
            maxQueueSize: 0 // No queueing
        )

        // Use a signal to know when the slow command has acquired the semaphore
        let slowCommandStarted = Signal()

        // Start a slow command that signals when it starts executing
        let slowTask = Task {
            try await middleware.execute(
                SignalingSlowCommand(id: 1, duration: 0.2, startedSignal: slowCommandStarted),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Wait until the slow command has actually started (semaphore acquired)
        await slowCommandStarted.wait()

        // When - try another command while first is running
        do {
            _ = try await middleware.execute(
                FastCommand(id: 2),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Expected bulkhead rejection")
        } catch {
            // Then - should be rejected
            if case PipelineError.middlewareError(let middleware, _, _) = error {
                XCTAssertEqual(middleware, "BulkheadMiddleware")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }

        // Cleanup
        _ = try await slowTask.value
    }

    func testQueueingPolicy() async throws {
        // Given
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 1,
                maxQueueSize: 2,
                rejectionPolicy: .queue
            )
        )

        let commandDuration: TimeInterval = 0.05
        let commands = (0..<3).map { SlowCommand(id: $0, duration: commandDuration) }

        let startTime = Date()

        // When - execute 3 commands (1 active, 2 queued)
        let results = await withTaskGroup(of: String?.self) { group in
            for command in commands {
                group.addTask {
                    try? await middleware.execute(command, context: CommandContext()) { cmd, _ in
                        try await cmd.execute()
                    }
                }
            }

            var results: [String] = []
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
            return results
        }

        let totalTime = Date().timeIntervalSince(startTime)

        // Then - all should complete sequentially
        XCTAssertEqual(results.count, 3)
        XCTAssertGreaterThanOrEqual(totalTime, commandDuration * 2.8) // Sequential execution
    }

    private enum TimedWrapper: String, CaseIterable {
        case ordinary, partitioned
    }

    private func timedSubject(
        _ wrapper: TimedWrapper,
        queue: Int,
        timeout: TimeInterval,
        admission: AdmissionGate? = nil
    ) -> BulkheadAdmissionSubject {
        switch wrapper {
        case .ordinary:
            let config = BulkheadMiddleware.Configuration(
                maxConcurrency: 1, maxQueueSize: queue, queueTimeout: timeout, rejectionPolicy: .queue
            )
            let middleware = admission.map { BulkheadMiddleware(configuration: config, admission: $0) }
                ?? BulkheadMiddleware(configuration: config)
            return .ordinary(middleware)
        case .partitioned:
            let config = PartitionedBulkheadMiddleware.Configuration(
                partitions: ["default": .init(capacity: 1, queueSize: queue, queueTimeout: timeout)],
                partitionExtractor: { _, _ in "default" }, allowBorrowing: false
            )
            let middleware = admission.map { PartitionedBulkheadMiddleware(configuration: config, admissions: ["default": $0]) }
                ?? PartitionedBulkheadMiddleware(configuration: config)
            return .partitioned(middleware)
        }
    }

    func testQueueTimeout() async throws {
        for wrapper in TimedWrapper.allCases {
            let ledger = BulkheadHandlerLedger()
            let subject = timedSubject(wrapper, queue: 1, timeout: 0.01)
            let holder = launchBulkhead(subject, id: "held", ledger: ledger)
            while !(await ledger.entered("held")) { await Task.yield() }
            let expiring = launchBulkhead(subject, id: "expired", ledger: ledger)
            let result = await expiring.value
            XCTAssertEqual(result, "timedOut", wrapper.rawValue)
            let state = await subject.snapshot()
            XCTAssertEqual(state.active, 1)
            XCTAssertEqual(state.queued, 0)
            let entries = await ledger.entries
            XCTAssertEqual(entries, ["held"])
            await ledger.release("held")
            let heldResult = await holder.value
            XCTAssertEqual(heldResult, "success")
        }
    }

    func testNonpositiveQueueTimeoutStillAllowsFreeCapacity() async {
        for wrapper in TimedWrapper.allCases {
            for timeout in [0.0, -1.0] {
                for queue in [0, 1] {
                    let ledger = BulkheadHandlerLedger()
                    let subject = timedSubject(wrapper, queue: queue, timeout: timeout)
                    let holder = launchBulkhead(subject, id: "held", ledger: ledger)
                    while !(await ledger.entered("held")) { await Task.yield() }
                    let expiring = launchBulkhead(subject, id: "expired", ledger: ledger)
                    let result = await expiring.value
                    XCTAssertEqual(result, "timedOut", wrapper.rawValue)
                    let state = await subject.snapshot()
                    XCTAssertEqual(state.active, 1)
                    XCTAssertEqual(state.queued, 0)
                    await ledger.release("held")
                    let heldResult = await holder.value
                    XCTAssertEqual(heldResult, "success")
                }
            }
        }
    }

    func testQueueTimeoutRangeAndNormalizationBoundaries() async {
        let maximum: TimeInterval = 86_400
        let cases: [(value: TimeInterval, noWait: Bool)] = [
            (-Double.greatestFiniteMagnitude, true), (-1e30, true), (-1, true),
            (0, true), (Double.leastNonzeroMagnitude, true), (1e-20, true),
            (1e-18, false), (0.001, false), (maximum.nextDown, false), (maximum, false)
        ]
        // Swift 6.2 constructs clock instants from Int64 seconds plus a
        // subsecond remainder. Exercise the Duration-addition headroom bound
        // without decomposing the deliberately extreme result back into Int64.
        let clockSecondsUpperBound = Duration.seconds(Int64.max) + .seconds(1)
        let latestDeadline = clockSecondsUpperBound + .seconds(maximum)
        XCTAssertGreaterThan(latestDeadline, clockSecondsUpperBound)
        let instant = ContinuousClock.now
        XCTAssertEqual(instant.duration(to: instant.advanced(by: .seconds(maximum))), .seconds(maximum))

        for wrapper in TimedWrapper.allCases {
            for item in cases {
                for queue in [0, 1] {
                    let label = "\(wrapper.rawValue), timeout=\(item.value), queue=\(queue)"
                    let clock = ManualAdmissionClock()
                    let gate = AdmissionGate(capacity: 1, maxQueueSize: queue,
                        now: { clock.now() }, sleep: { try await clock.sleep(for: $0) })
                    let ledger = BulkheadHandlerLedger()
                    let subject = timedSubject(wrapper, queue: queue, timeout: item.value, admission: gate)
                    let holder = launchBulkhead(subject, id: "held", ledger: ledger)
                    while !(await ledger.entered("held")) { await Task.yield() }
                    let waiter = launchBulkhead(subject, id: "waiter", ledger: ledger)
                    if !item.noWait && queue > 0 {
                        await clock.waitForSleepers(1)
                        let registered = await gate.snapshot()
                        XCTAssertEqual(registered.queued, 1, label)
                        clock.advance(by: .seconds(item.value))
                    }
                    let result = await waiter.value
                    XCTAssertEqual(result, item.noWait || queue > 0 ? "timedOut" : "rejected", label)
                    await clock.waitForSettlement()
                    XCTAssertEqual(clock.callCount, !item.noWait && queue > 0 ? 1 : 0, label)
                    let retained = await gate.snapshot()
                    XCTAssertEqual(retained.active, 1, label)
                    XCTAssertEqual(retained.queued, 0, label)
                    let entries = await ledger.entries
                    XCTAssertEqual(entries, ["held"], label)
                    await ledger.release("held")
                    let holderResult = await holder.value
                    XCTAssertEqual(holderResult, "success", label)
                    let settled = await gate.snapshot()
                    XCTAssertEqual(settled.active, 0, label)
                    XCTAssertEqual(settled.queued, 0, label)
                }
            }
        }
    }

    // The external timeout driver selects invalid values in isolated test
    // processes and checks the explicit validation diagnostic before a trap.
    // A normal suite invocation checks valid public construction instead.
    func testQueueTimeoutConfigurationValidationProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        let selected = environment["PIPELINEKIT_R02_INVALID_TIMEOUT"]
        let timeout = try XCTUnwrap(Double(selected ?? "86400"))
        let queue = Int(environment["PIPELINEKIT_R02_QUEUE_SIZE"] ?? "0") ?? 0
        let wrapperName = environment["PIPELINEKIT_R02_WRAPPER"]
        let wrappers = wrapperName.map { [TimedWrapper(rawValue: $0)!] } ?? TimedWrapper.allCases
        for wrapper in wrappers {
            let subject = timedSubject(wrapper, queue: queue, timeout: timeout)
            if selected != nil {
                XCTFail("Invalid queue timeout was accepted instead of explicit configuration validation: \(wrapper.rawValue)")
            } else {
                let snapshot = await subject.snapshot()
                XCTAssertEqual(snapshot.active, 0)
                XCTAssertEqual(snapshot.queued, 0)
            }
        }
    }

    @available(*, deprecated, message: "Exercises the supported deprecated tagged compatibility path")
    func testTaggedAndTaskGroupModesRetainSharedCapacity() async {
        let modes: [BulkheadMiddleware.IsolationMode] = [
            .taskGroup(priority: .low),
            .tagged(keyExtractor: { ($0 as? AdmissionCommand)?.id ?? "unknown" })
        ]
        for (index, mode) in modes.enumerated() {
            let middleware = BulkheadMiddleware(configuration: .init(
                maxConcurrency: 1, maxQueueSize: 1, rejectionPolicy: .queue, isolationMode: mode
            ))
            let subject = BulkheadAdmissionSubject.ordinary(middleware)
            let ledger = BulkheadHandlerLedger()
            let firstContext = CommandContext()
            let secondContext = CommandContext()
            let first = launchBulkhead(subject, id: "alpha", ledger: ledger, context: firstContext)
            while !(await ledger.entered("alpha")) { await Task.yield() }
            let second = launchBulkhead(subject, id: "beta", ledger: ledger, context: secondContext)
            while await middleware.admissionSnapshot().queued != 1 { await Task.yield() }
            let rejected = launchBulkhead(subject, id: "gamma", ledger: ledger)
            let rejection = await rejected.value
            XCTAssertEqual(rejection, "rejected")
            let entries = await ledger.entries
            XCTAssertEqual(entries, ["alpha"])
            await ledger.release("alpha")
            while !(await ledger.entered("beta")) { await Task.yield() }
            await ledger.release("beta")
            let firstResult = await first.value
            let secondResult = await second.value
            XCTAssertEqual(firstResult, "success")
            XCTAssertEqual(secondResult, "success")
            XCTAssertEqual(secondContext.getMetadata()["bulkhead.wasQueued"] as? Bool, true)
            if index == 1 {
                XCTAssertEqual(firstContext.getMetadata()["bulkheadTag"] as? String, "alpha")
                XCTAssertEqual(secondContext.getMetadata()["bulkheadTag"] as? String, "beta")
            }
            let state = await middleware.admissionSnapshot()
            XCTAssertEqual(state.active, 0)
            XCTAssertEqual(state.queued, 0)
            let peak = await ledger.peak
            XCTAssertEqual(peak, 1)
        }
    }

    func testFallbackPolicy() async throws {
        // Given
        let fallbackValue = "Fallback response"
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 1,
                rejectionPolicy: .fallback(value: { fallbackValue })
            )
        )

        // Use a signal to know when the slow command has acquired the semaphore
        let slowCommandStarted = Signal()

        // Start a slow command that signals when it starts executing
        let slowTask = Task {
            try await middleware.execute(
                SignalingSlowCommand(id: 1, duration: 0.2, startedSignal: slowCommandStarted),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Wait until the slow command has actually started (semaphore acquired)
        await slowCommandStarted.wait()

        // When - execute another command
        let result = try await middleware.execute(
            FastCommand(id: 2),
            context: CommandContext()
        ) { cmd, _ in
            try await cmd.execute()
        }

        // Then - should get fallback value
        XCTAssertEqual(result, fallbackValue)

        // Cleanup
        _ = try await slowTask.value
    }

    func testCustomRejectionPolicy() async throws {
        // Given
        let customResponse = "Custom handled"
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 1,
                rejectionPolicy: .custom(handler: { _ in
                    customResponse
                })
            )
        )

        // Use a signal to know when the slow command has acquired the semaphore
        let slowCommandStarted = Signal()

        // Start a slow command that signals when it starts executing
        let slowTask = Task {
            try await middleware.execute(
                SignalingSlowCommand(id: 1, duration: 0.2, startedSignal: slowCommandStarted),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Wait until the slow command has actually started (semaphore acquired)
        await slowCommandStarted.wait()

        // When
        let result = try await middleware.execute(
            FastCommand(id: 2),
            context: CommandContext()
        ) { cmd, _ in
            try await cmd.execute()
        }

        // Then
        XCTAssertEqual(result, customResponse)

        // Cleanup
        _ = try await slowTask.value
    }

    func testMetricsTracking() async throws {
        // Given
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 2,
                maxQueueSize: 1,
                rejectionPolicy: .queue,  // Need queue policy for proper metrics
                emitMetrics: true
            )
        )

        let context = CommandContext()

        // When - execute a command
        _ = try await middleware.execute(FastCommand(id: 1), context: context) { cmd, _ in
            try await cmd.execute()
        }

        // Then - check metrics
        let metrics = context.getMetadata()
        XCTAssertNotNil(metrics["bulkhead.duration"])
        XCTAssertEqual(metrics["bulkhead.wasQueued"] as? Bool, false)
        XCTAssertEqual(metrics["bulkhead.activeCount"] as? Int, 0)
        XCTAssertEqual(metrics["bulkhead.queuedCount"] as? Int, 0)
    }

    func testRejectionHandler() async throws {
        // Given
        let expectation = XCTestExpectation(description: "Rejection handler called")
        actor CommandTracker {
            var rejectedCommand: (any Command)?
            func setRejected(_ cmd: any Command) {
                rejectedCommand = cmd
            }
            func getRejected() -> (any Command)? {
                return rejectedCommand
            }
        }
        let tracker = CommandTracker()

        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 1,
                rejectionHandler: { command, _ in
                    Task { @Sendable in await tracker.setRejected(command) }
                    expectation.fulfill()
                }
            )
        )

        // Use a signal to know when the slow command has acquired the semaphore
        let slowCommandStarted = Signal()

        // Start a slow command that signals when it starts executing
        let slowTask = Task {
            try await middleware.execute(
                SignalingSlowCommand(id: 1, duration: 0.2, startedSignal: slowCommandStarted),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Wait until the slow command has actually started (semaphore acquired)
        await slowCommandStarted.wait()

        // When - try to execute another
        _ = try? await middleware.execute(
            FastCommand(id: 2),
            context: CommandContext()
        ) { cmd, _ in
            try await cmd.execute()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        let rejectedCommand = await tracker.getRejected()
        XCTAssertNotNil(rejectedCommand)
        XCTAssertTrue(rejectedCommand is FastCommand)

        // Cleanup
        _ = try await slowTask.value
    }

    func testHighConcurrencyStress() async throws {
        // Given
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 10,
                maxQueueSize: 90,  // Need to queue up to 90 commands for 100 total
                rejectionPolicy: .queue
            )
        )

        let commandCount = 100
        let commands = (0..<commandCount).map { FastCommand(id: $0) }

        // When - execute many commands concurrently
        let results = await withTaskGroup(of: Result<String, Error>.self) { group in
            for command in commands {
                group.addTask {
                    do {
                        let result = try await middleware.execute(command, context: CommandContext()) { cmd, _ in
                            // Add small random delay
                            try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...10_000_000))
                            return try await cmd.execute()
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var results: [Result<String, Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        // Then - all should complete
        var successCount = 0
        var failureCount = 0

        for result in results {
            switch result {
            case .success:
                successCount += 1
            case .failure:
                failureCount += 1
            }
        }

        XCTAssertEqual(successCount, commandCount)
        XCTAssertEqual(failureCount, 0)
    }
}
