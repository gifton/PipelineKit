import Foundation
import Synchronization
import XCTest
@testable import PipelineKitCore
#if canImport(UIKit) && (os(iOS) || os(tvOS))
import UIKit
#endif

@MainActor
final class MemoryPressureLifecycleTests: XCTestCase {
    func testIdleMonitoringDoesNotRetainResponder() async {
        let firstHandler = expectation(description: "First periodic pressure handler entered")
        var responder: MemoryPressureResponder? = MemoryPressureResponder(
            highWaterMark: Int.max,
            lowWaterMark: Int.max
        )
        let witness = WeakMemoryPressureResponder(value: responder)
        await responder?.register { firstHandler.fulfill() }
        await responder?.startMonitoring()
        await fulfillment(of: [firstHandler], timeout: 7)

        let firstCheckFinished = await observe(until: .seconds(2)) {
            await responder?.statistics.periodicChecks == 1
        }
        XCTAssertTrue(firstCheckFinished, "The periodic check must settle before releasing the idle owner")

        responder = nil
        let released = await observe(until: .seconds(2)) { witness.value == nil }
        XCTAssertTrue(released, "A sleeping monitoring task must not retain its responder")

        // The original implementation leaks the responder; release its task even
        // when this regression fails so the fixture cannot keep monitoring.
        await witness.value?.stopMonitoring()
    }

    func testStopDuringSleepDoesNotPerformAnotherPeriodicCheck() async {
        let firstHandler = expectation(description: "First periodic pressure handler entered")
        let responder = MemoryPressureResponder(highWaterMark: Int.max, lowWaterMark: Int.max)
        await responder.register { firstHandler.fulfill() }
        await responder.startMonitoring()
        await fulfillment(of: [firstHandler], timeout: 7)

        let firstCheckFinished = await observe(until: .seconds(2)) {
            await responder.statistics.periodicChecks == 1
        }
        XCTAssertTrue(firstCheckFinished, "The periodic check must settle before stopping during the next sleep")
        let beforeStop = await responder.statistics.periodicChecks

        await responder.stopMonitoring()

        // This is a bounded observation for forbidden work, not a delay used to
        // order the stop: the first completed check acknowledges the idle phase.
        let sampledAfterStop = await observe(until: .milliseconds(250)) {
            await responder.statistics.periodicChecks != beforeStop
        }
        XCTAssertFalse(sampledAfterStop, "Canceling the sleep must not perform a final memory sample")
        await responder.stopMonitoring()
    }

    func testOwnerReleaseCancelsAcknowledgedSleepWithoutSampling() async {
        let sleeping = expectation(description: "Periodic task entered its sleep")
        let cancelled = expectation(description: "Owner release cancelled the sleep")
        let samples = MemoryPressureTestCounter()
        var responder: MemoryPressureResponder? = MemoryPressureResponder(
            sleep: {
                try await withTaskCancellationHandler {
                    sleeping.fulfill()
                    try await Task.sleep(for: .seconds(60))
                } onCancel: {
                    cancelled.fulfill()
                }
            },
            availableMemory: { samples.increment(); return 0 },
            notifications: .disabled
        )
        let witness = WeakMemoryPressureResponder(value: responder)
        await responder?.startMonitoring()
        await fulfillment(of: [sleeping], timeout: 2)

        responder = nil
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertNil(witness.value)
        XCTAssertEqual(samples.value, 0)
        await witness.value?.stopMonitoring()
    }

    func testDetectorConcurrentStopsJoinCooperativeHandlerSettlement() async {
        let entered = expectation(description: "Cooperative handler entered")
        let cancelled = expectation(description: "Cooperative handler acknowledged cancellation")
        let stopped = expectation(description: "Both detector stop calls returned")
        stopped.expectedFulfillmentCount = 2
        let settlement = MemoryPressureTestGate()
        let returns = MemoryPressureTestCounter()
        let settled = MemoryPressureTestCounter()
        let responder = MemoryPressureResponder(
            sleep: {}, availableMemory: { 0 }, notifications: .disabled
        )
        let detector = MemoryPressureDetector(responder: responder)
        await responder.register {
            entered.fulfill()
            do {
                try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(60))
                } onCancel: {
                    cancelled.fulfill()
                }
            } catch {}
            _ = await settlement.wait()
            settled.increment()
        }
        await detector.startMonitoring()
        await fulfillment(of: [entered], timeout: 2)

        let firstStop = Task {
            await detector.stopMonitoring()
            returns.increment()
            stopped.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        let secondStop = Task {
            await detector.stopMonitoring()
            returns.increment()
            stopped.fulfill()
        }
        let returnedBeforeSettlement = await observe(until: .milliseconds(100)) { returns.value > 0 }
        XCTAssertFalse(returnedBeforeSettlement, "Every external stop must join the retiring handler")

        settlement.open()
        await fulfillment(of: [stopped], timeout: 2)
        await firstStop.value
        await secondStop.value
        XCTAssertEqual(settled.value, 1)
        XCTAssertFalse(settlement.didTimeOut)
    }

    func testCallbackStopReturnsWhileExternalStopJoinsRetiringGeneration() async {
        let callbackStopped = expectation(description: "Callback stop returned without joining itself")
        let externalStopped = expectation(description: "External stop joined the retired generation")
        let settlement = MemoryPressureTestGate()
        let returns = MemoryPressureTestCounter()
        let responder = MemoryPressureResponder(
            sleep: {}, availableMemory: { 0 }, notifications: .disabled
        )
        await responder.register { [weak responder] in
            await responder?.stopMonitoring()
            callbackStopped.fulfill()
            _ = await settlement.wait()
        }
        await responder.startMonitoring()
        await fulfillment(of: [callbackStopped], timeout: 2)

        let externalStop = Task {
            await responder.stopMonitoring()
            returns.increment()
            externalStopped.fulfill()
        }
        let returnedBeforeSettlement = await observe(until: .milliseconds(100)) { returns.value > 0 }
        XCTAssertFalse(returnedBeforeSettlement, "Callback stop must leave its generation joinable")

        settlement.open()
        await fulfillment(of: [externalStopped], timeout: 2)
        await externalStop.value
        XCTAssertFalse(settlement.didTimeOut)
    }

    func testAnotherRespondersCallbackStillJoinsTheStoppedOwner() async {
        let targetEntered = expectation(description: "Target handler entered")
        let targetCancelled = expectation(description: "Target handler acknowledged cancellation")
        let callerReturned = expectation(description: "Other responder's callback completed target stop")
        let settlement = MemoryPressureTestGate()
        let returns = MemoryPressureTestCounter()
        let target = MemoryPressureResponder(sleep: {}, availableMemory: { 0 }, notifications: .disabled)
        await target.register {
            targetEntered.fulfill()
            do {
                try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(60))
                } onCancel: {
                    targetCancelled.fulfill()
                }
            } catch {}
            _ = await settlement.wait()
        }
        await target.startMonitoring()
        await fulfillment(of: [targetEntered], timeout: 2)

        let sleeps = MemoryPressureTestCounter()
        let caller = MemoryPressureResponder(
            sleep: {
                if sleeps.increment() == 1 { return }
                try await Task.sleep(for: .seconds(60))
            },
            availableMemory: { 0 },
            notifications: .disabled
        )
        await caller.register {
            await target.stopMonitoring()
            returns.increment()
            callerReturned.fulfill()
        }
        await caller.startMonitoring()
        await fulfillment(of: [targetCancelled], timeout: 2)
        let returnedBeforeSettlement = await observe(until: .milliseconds(100)) { returns.value > 0 }
        XCTAssertFalse(returnedBeforeSettlement, "Only a callback belonging to the stopped owner may skip its join")

        settlement.open()
        await fulfillment(of: [callerReturned], timeout: 2)
        await caller.stopMonitoring()
        await target.stopMonitoring()
        XCTAssertFalse(settlement.didTimeOut)
    }

    func testCallbackRestartWaitsForPreviousHandlerAndObserverSettlement() async {
        let restartQueued = expectation(description: "Callback queued a restart without joining itself")
        let successorSleeping = expectation(description: "Successor generation began monitoring")
        let settlement = MemoryPressureTestGate()
        let sleeps = MemoryPressureTestCounter()
        let observations = MemoryPressureNotificationProbe()
        let responder = MemoryPressureResponder(
            sleep: {
                if sleeps.increment() == 1 { return }
                successorSleeping.fulfill()
                try await Task.sleep(for: .seconds(60))
            },
            availableMemory: { 0 },
            notifications: observations.source()
        )
        await responder.register { [weak responder] in
            await responder?.stopMonitoring()
            await responder?.startMonitoring()
            restartQueued.fulfill()
            _ = await settlement.wait()
        }
        await responder.startMonitoring()
        await fulfillment(of: [restartQueued], timeout: 2)

        let overlapped = await observe(until: .milliseconds(100)) { observations.registrationCount > 1 }
        XCTAssertFalse(overlapped, "A successor must not register while its predecessor callback is still active")
        settlement.open()
        await fulfillment(of: [successorSleeping], timeout: 2)
        XCTAssertEqual(observations.registrationCount, 2)
        XCTAssertEqual(observations.cancelledIDs, [1])

        await responder.stopMonitoring()
        XCTAssertEqual(observations.cancelledIDs, [1, 2])
        XCTAssertFalse(settlement.didTimeOut)
    }

    func testStopDuringRegistrationRetiresExactTokenBeforeRestart() async {
        let registrationEntered = expectation(description: "First observer registration entered")
        let registrationCancelled = expectation(description: "Stop cancelled pending registration")
        let startsReturned = expectation(description: "Both start calls returned")
        startsReturned.expectedFulfillmentCount = 2
        let stopReturned = expectation(description: "Stop removed the old observer")
        let warningDelivered = expectation(description: "Current observer delivered one warning")
        let registration = MemoryPressureTestGate()
        let observations = MemoryPressureNotificationProbe()
        let callbacks = MemoryPressureTestCounter()
        let starts = MemoryPressureTestCounter()
        let responder = MemoryPressureResponder(
            sleep: { try await Task.sleep(for: .seconds(60)) },
            availableMemory: { Int.max },
            notifications: observations.source(
                firstRegistration: registration,
                entered: registrationEntered,
                cancelled: registrationCancelled
            )
        )
        await responder.register {
            callbacks.increment()
            warningDelivered.fulfill()
        }
        let firstStart = Task {
            await responder.startMonitoring()
            starts.increment()
            startsReturned.fulfill()
        }
        await fulfillment(of: [registrationEntered], timeout: 2)
        XCTAssertEqual(starts.value, 0, "External start must await observer registration")

        let stop = Task {
            await responder.stopMonitoring()
            stopReturned.fulfill()
        }
        await fulfillment(of: [registrationCancelled], timeout: 2)
        let secondStart = Task {
            await responder.startMonitoring()
            starts.increment()
            startsReturned.fulfill()
        }
        let registeredBeforeRetirement = await observe(until: .milliseconds(100)) {
            observations.registrationCount > 1
        }
        XCTAssertFalse(registeredBeforeRetirement)

        registration.open()
        await fulfillment(of: [startsReturned, stopReturned], timeout: 2)
        await firstStart.value
        await stop.value
        await secondStart.value
        XCTAssertEqual(observations.registrationCount, 2)
        XCTAssertEqual(observations.cancelledIDs, [1])

        observations.emit(id: 1)
        observations.emit(id: 2)
        await fulfillment(of: [warningDelivered], timeout: 2)
        XCTAssertEqual(callbacks.value, 1, "A stale observer callback must not enter the restarted generation")
        let statistics = await responder.statistics
        XCTAssertEqual(statistics.systemWarnings, 1)

        await responder.stopMonitoring()
        XCTAssertEqual(observations.cancelledIDs, [1, 2])
        XCTAssertFalse(registration.didTimeOut)
    }

    func testConcurrentStartsAwaitOneObserverRegistration() async {
        let entered = expectation(description: "Shared observer registration entered")
        let returned = expectation(description: "Both starts observed registration completion")
        returned.expectedFulfillmentCount = 2
        let registration = MemoryPressureTestGate()
        let observations = MemoryPressureNotificationProbe()
        let returns = MemoryPressureTestCounter()
        let responder = MemoryPressureResponder(
            sleep: { try await Task.sleep(for: .seconds(60)) },
            availableMemory: { Int.max },
            notifications: observations.source(firstRegistration: registration, entered: entered)
        )
        let first = Task {
            await responder.startMonitoring()
            returns.increment()
            returned.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task {
            await responder.startMonitoring()
            returns.increment()
            returned.fulfill()
        }
        let returnedBeforeRegistration = await observe(until: .milliseconds(100)) { returns.value > 0 }
        XCTAssertFalse(returnedBeforeRegistration)
        XCTAssertEqual(observations.registrationCount, 1)

        registration.open()
        await fulfillment(of: [returned], timeout: 2)
        await first.value
        await second.value
        await responder.stopMonitoring()
        XCTAssertEqual(observations.cancelledIDs, [1])
        XCTAssertFalse(registration.didTimeOut)
    }

    #if canImport(UIKit) && (os(iOS) || os(tvOS))
    func testUIKitWarningObserverStopsDeliveringAfterStop() async {
        let firstHandler = expectation(description: "UIKit warning reached the registered handler")
        let calls = MemoryPressureCallbackCount()
        let responder = MemoryPressureResponder(highWaterMark: 0, lowWaterMark: 0)
        await responder.register {
            if await calls.increment() == 1 { firstHandler.fulfill() }
        }
        await responder.startMonitoring()

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await fulfillment(of: [firstHandler], timeout: 2)
        let firstCount = await calls.value
        XCTAssertEqual(firstCount, 1)

        await responder.stopMonitoring()
        let warningsBeforePost = await responder.statistics.systemWarnings
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        let deliveredAfterStop = await observe(until: .milliseconds(250)) {
            await responder.statistics.systemWarnings != warningsBeforePost
        }
        XCTAssertFalse(deliveredAfterStop, "Stop must remove the block observer returned by NotificationCenter")
        let finalCount = await calls.value
        XCTAssertEqual(finalCount, 1)
        await responder.stopMonitoring()
    }
    #endif

    private func observe(
        until timeout: Duration,
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if await condition() { return true }
            await Task.yield()
        } while ContinuousClock.now < deadline
        return await condition()
    }
}

private struct WeakMemoryPressureResponder: Sendable {
    weak var value: MemoryPressureResponder?
}

private final class MemoryPressureTestCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }

    @discardableResult
    func increment() -> Int {
        count.withLock { $0 += 1; return $0 }
    }
}

/// A fixture-controlled hold with a deadline; the timeout task is always joined.
private final class MemoryPressureTestGate: Sendable {
    private struct State {
        var result: Bool?
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }

    private let state = Mutex(State())
    var didTimeOut: Bool { state.withLock { $0.result == false } }

    func wait() async -> Bool {
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.complete(false)
        }
        let result = await withCheckedContinuation { continuation in
            let existing = state.withLock { state -> Bool? in
                if let result = state.result { return result }
                state.waiters.append(continuation)
                return nil
            }
            if let existing { continuation.resume(returning: existing) }
        }
        timeout.cancel()
        await timeout.value
        return result
    }

    func open() { complete(true) }

    private func complete(_ result: Bool) {
        let waiters = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            guard state.result == nil else { return [] }
            state.result = result
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: result) }
    }
}

private final class MemoryPressureNotificationProbe: Sendable {
    private struct State {
        var nextID = 0
        var callbacks: [Int: @Sendable () -> Void] = [:]
        var cancelledIDs: [Int] = []
    }

    private let state = Mutex(State())
    var registrationCount: Int { state.withLock { $0.nextID } }
    var cancelledIDs: [Int] { state.withLock { $0.cancelledIDs } }

    func source(
        firstRegistration: MemoryPressureTestGate? = nil,
        entered: XCTestExpectation? = nil,
        cancelled: XCTestExpectation? = nil
    ) -> MemoryPressureNotificationSource {
        MemoryPressureNotificationSource { [self] callback in
            let id = state.withLock { state in
                state.nextID += 1
                state.callbacks[state.nextID] = callback
                return state.nextID
            }
            if id == 1, let firstRegistration {
                entered?.fulfill()
                _ = await withTaskCancellationHandler {
                    await firstRegistration.wait()
                } onCancel: {
                    cancelled?.fulfill()
                }
            }
            return MemoryPressureObservation { [self] in
                state.withLock { $0.cancelledIDs.append(id) }
            }
        }
    }

    func emit(id: Int) {
        // Retaining the callback after cancellation lets the regression model a
        // notification already queued before exact-token removal completed.
        let callback = state.withLock { $0.callbacks[id] }
        callback?()
    }
}

#if canImport(UIKit) && (os(iOS) || os(tvOS))
private actor MemoryPressureCallbackCount {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}
#endif
