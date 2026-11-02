import Foundation
import XCTest
@testable import PipelineKitObservability

private let udpLifecyclePayload = Data("lifecycle:1|c".utf8)

@MainActor
final class UDPTransportLifecycleTests: XCTestCase {

    private func makeTransport(
        driver: ScriptedUDPConnection,
        sleeper: ManualUDPSleeper,
        configuration: UDPTransport.Configuration = .init(maxRetries: 2)
    ) throws -> UDPTransport {
        try UDPTransport(configuration: configuration, driver: driver, sleep: { try await sleeper.sleep($0) })
    }

    private func readyTransport(
        driver: ScriptedUDPConnection,
        sleeper: ManualUDPSleeper,
        configuration: UDPTransport.Configuration = .init(maxRetries: 2)
    ) async throws -> UDPTransport {
        let transport = try makeTransport(driver: driver, sleeper: sleeper, configuration: configuration)
        let startup = Task { try await transport.startConnection() }
        await driver.waitForStarts(1)
        await sleeper.waitForPending(1)
        driver.emit(.ready)
        try await startup.value
        await sleeper.join()
        return transport
    }

    // Removing the one-shot registry settlement traps on duplicate callbacks;
    // accepting late ready would permit a send after terminal invalidation.
    func testSetupTerminalStateMatrix() async throws {
        for scenario in ["ready-cancelled", "failed-cancelled", "ready-twice", "cancel-late-ready", "timeout-late-ready", "close-late-ready"] {
            let driver = ScriptedUDPConnection()
            let sleeper = ManualUDPSleeper()
            let ledger = UDPSettlementLedger()
            let transport = try makeTransport(driver: driver, sleeper: sleeper)
            let startup = Task { await ledger.record { try await transport.startConnection() } }
            await driver.waitForStarts(1)
            await sleeper.waitForPending(1)
            let initialPending = await transport.pendingOperationCount
            XCTAssertEqual(initialPending, 1, scenario)

            switch scenario {
            case "ready-cancelled": driver.emit(.ready); driver.emit(.cancelled)
            case "failed-cancelled": driver.emit(.failed(.connectionFailed("fixture-start"))); driver.emit(.cancelled)
            case "ready-twice": driver.emit(.ready); driver.emit(.ready)
            case "cancel-late-ready": driver.emit(.cancelled)
            case "close-late-ready": await transport.close()
            default: sleeper.advanceFirst()
            }
            let result = await startup.value
            let expected = ["ready-cancelled": "success", "failed-cancelled": "connection:fixture-start",
                            "ready-twice": "success", "cancel-late-ready": "closed", "timeout-late-ready": "timeout",
                            "close-late-ready": "closed"]
            XCTAssertEqual(result, expected[scenario], scenario)
            if scenario == "ready-twice" {
                // Completing this send crosses both queued ready callbacks before close.
                let sent = Task { await ledger.record { try await transport.send(udpLifecyclePayload) } }
                await driver.waitForSends(1)
                await sleeper.waitForPending(1)
                driver.completeSend(0, with: .success(()))
                let sendResult = await sent.value
                XCTAssertEqual(sendResult, "success")
            } else {
                driver.emit(.ready)
                // No deadline is advanced here: cancellation/failure must already own
                // the result, even if a send races processing of the queued state.
                let sent = await ledger.record { try await transport.send(udpLifecyclePayload) }
                XCTAssertEqual(sent, scenario == "ready-cancelled" ? "closed" : expected[scenario]!, scenario)
            }
            await transport.close()
            await transport.close()
            driver.emit(.ready)
            driver.emit(.cancelled)
            let afterClose = await ledger.record { try await transport.send(udpLifecyclePayload) }
            XCTAssertEqual(afterClose, "closed", scenario)
            let pending = await transport.pendingOperationCount
            let settlements = await ledger.values
            XCTAssertEqual(pending, 0, scenario)
            XCTAssertEqual(settlements.count, 3, scenario)
            XCTAssertEqual(driver.snapshot.starts, 1, scenario)
            XCTAssertEqual(driver.snapshot.cancels, 1, scenario)
            if scenario == "ready-twice" {
                XCTAssertEqual(driver.snapshot.sends, 1)
            } else if scenario == "ready-cancelled" {
                XCTAssertLessThanOrEqual(driver.snapshot.sends, 1)
            } else {
                XCTAssertEqual(driver.snapshot.sends, 0)
            }
            XCTAssertEqual(driver.snapshot.stateCallbacks,
                           scenario == "ready-twice" ? 4 : (["timeout-late-ready", "close-late-ready"].contains(scenario) ? 3 : (scenario == "cancel-late-ready" ? 4 : 5)))
            await sleeper.join()
        }
    }

    // A deadline/close must settle callers while every send callback is withheld.
    func testMissingSendCallbackSettlesOnTimeoutOrClose() async throws {
        for terminal in ["timeout", "close", "cancel", "failed", "network-cancelled"] {
            let driver = ScriptedUDPConnection()
            let sleeper = ManualUDPSleeper()
            let transport = try await readyTransport(driver: driver, sleeper: sleeper)
            let ledger = UDPSettlementLedger()
            let first = Task { await ledger.record { try await transport.send(udpLifecyclePayload) } }
            await driver.waitForSends(1)
            let second = Task { await ledger.record { try await transport.send(udpLifecyclePayload) } }
            await driver.waitForSends(2)
            await sleeper.waitForPending(2)
            let registered = await transport.pendingOperationCount
            XCTAssertEqual(registered, 2)
            switch terminal {
            case "timeout": sleeper.advanceFirst()
            case "close": await transport.close()
            case "cancel": first.cancel()
            case "failed": driver.emit(.failed(.connectionFailed("fixture-live")))
            default: driver.emit(.cancelled)
            }
            let results = [await first.value, await second.value]
            let expected = ["timeout": "timeout", "close": "closed", "cancel": "cancelled",
                            "failed": "connection:fixture-live", "network-cancelled": "closed"]
            XCTAssertEqual(results, [expected[terminal]!, expected[terminal]!], terminal)
            XCTAssertEqual(driver.snapshot.sendCallbacks, 0, "Callers settled without a callback")
            driver.completeSend(0, with: .success(()))
            driver.completeSend(0, with: .failure(.connectionFailed("late")))
            driver.completeSend(1, with: .success(()))
            driver.emit(.ready)
            let later = await ledger.record { try await transport.send(udpLifecyclePayload) }
            XCTAssertEqual(later, expected[terminal], "Late callbacks cannot revive an invalid connection")
            await transport.close()
            let pending = await transport.pendingOperationCount
            let settlements = await ledger.values
            XCTAssertEqual(pending, 0)
            XCTAssertEqual(settlements.count, 3)
            XCTAssertEqual(driver.snapshot.cancels, 1)
            XCTAssertEqual(driver.snapshot.sends, 2)
            XCTAssertEqual(driver.snapshot.sendCallbacks, 3)
            await sleeper.join()
        }
    }

    func testCancellationBeforeRegistrationAndAfterCompletion() async throws {
        for beforeRegistration in [true, false] {
            let driver = ScriptedUDPConnection()
            let sleeper = ManualUDPSleeper()
            let transport = try await readyTransport(driver: driver, sleeper: sleeper)
            let gate = UDPEntryGate()
            let ledger = UDPSettlementLedger()
            let send = Task {
                await gate.wait()
                return await ledger.record { try await transport.send(udpLifecyclePayload) }
            }
            await gate.waitForEntry()
            if beforeRegistration { send.cancel() }
            await gate.release()
            if !beforeRegistration {
                await driver.waitForSends(1)
                await sleeper.waitForPending(1)
                driver.completeSend(0, with: .success(()))
            }
            let result = await send.value
            send.cancel()
            XCTAssertEqual(result, beforeRegistration ? "cancelled" : "success")
            if !beforeRegistration {
                let next = Task { await ledger.record { try await transport.send(udpLifecyclePayload) } }
                await driver.waitForSends(2)
                await sleeper.waitForPending(1)
                // The first operation's late callbacks precede the second operation's
                // completion in the stream, so success proves they were ignored.
                driver.completeSend(0, with: .success(()))
                driver.completeSend(0, with: .failure(.connectionFailed("late-completed-send")))
                driver.completeSend(1, with: .success(()))
                let nextResult = await next.value
                XCTAssertEqual(nextResult, "success", "Completed cancellation cannot invalidate a later send")
            }
            await transport.close()
            let pending = await transport.pendingOperationCount
            XCTAssertEqual(pending, 0)
            XCTAssertEqual(driver.snapshot.sends, beforeRegistration ? 0 : 2)
            XCTAssertEqual(driver.snapshot.sendCallbacks, beforeRegistration ? 0 : 4)
            XCTAssertEqual(driver.snapshot.cancels, 1)
            await sleeper.join()
        }
    }

    func testSetupCallerCancellationBeforeAndAfterRegistration() async throws {
        for beforeRegistration in [true, false] {
            let driver = ScriptedUDPConnection()
            let sleeper = ManualUDPSleeper()
            let transport = try makeTransport(driver: driver, sleeper: sleeper)
            let gate = UDPEntryGate()
            let ledger = UDPSettlementLedger()
            let startup = Task {
                await gate.wait()
                return await ledger.record { try await transport.startConnection() }
            }
            await gate.waitForEntry()
            if beforeRegistration { startup.cancel() }
            await gate.release()
            if !beforeRegistration {
                await driver.waitForStarts(1)
                await sleeper.waitForPending(1)
                startup.cancel()
            }
            let result = await startup.value
            XCTAssertEqual(result, "cancelled")
            await transport.close()
            let pending = await transport.pendingOperationCount
            XCTAssertEqual(pending, 0)
            XCTAssertEqual(driver.snapshot.starts, beforeRegistration ? 0 : 1)
            XCTAssertEqual(driver.snapshot.cancels, 1)
            await sleeper.join()
        }
    }

    func testConcurrentSendBatchFailureSettlesSiblings() async throws {
        for failure in [TransportError.sendFailed("retry-exhausted"), .connectionFailed("fatal")] {
            let driver = ScriptedUDPConnection()
            let sleeper = ManualUDPSleeper()
            let transport = try await readyTransport(driver: driver, sleeper: sleeper, configuration: .init(maxRetries: 1))
            let ledger = UDPSettlementLedger()
            let batch = Task { await ledger.record { try await transport.sendBatch([udpLifecyclePayload, udpLifecyclePayload, udpLifecyclePayload]) } }
            await driver.waitForSends(3)
            await sleeper.waitForPending(3)
            driver.completeSend(0, with: .failure(failure))
            let result = await batch.value
            switch failure {
            case .sendFailed: XCTAssertEqual(result, "send:retry-exhausted")
            default: XCTAssertEqual(result, "connection:fatal")
            }
            let pending = await transport.pendingOperationCount
            XCTAssertEqual(pending, 0)
            XCTAssertEqual(driver.snapshot.sendCallbacks, 1)
            XCTAssertEqual(driver.snapshot.cancels, 1)
            await transport.close()
            await sleeper.join()
        }
    }

    func testRetryBackoffIsOwnedByCancellationAndClose() async throws {
        for terminal in ["retry", "cancel", "close"] {
            let driver = ScriptedUDPConnection()
            let sleeper = ManualUDPSleeper()
            let transport = try await readyTransport(driver: driver, sleeper: sleeper)
            let ledger = UDPSettlementLedger()
            let send = Task { await ledger.record { try await transport.send(udpLifecyclePayload) } }
            await driver.waitForSends(1)
            await sleeper.waitForPending(1)
            driver.completeSend(0, with: .failure(.sendFailed("transient")))
            // This acknowledges backoff entry, not just disappearance of its send timer.
            while sleeper.durations != [.milliseconds(100)] { await Task.yield() }
            let pending = await transport.pendingOperationCount
            XCTAssertEqual(pending, 1)
            if terminal == "retry" {
                sleeper.advanceFirst()
                await driver.waitForSends(2)
                await sleeper.waitForPending(1)
                driver.completeSend(1, with: .success(()))
            } else if terminal == "cancel" {
                send.cancel()
            } else {
                await transport.close()
            }
            let result = await send.value
            XCTAssertEqual(result, ["retry": "success", "cancel": "cancelled", "close": "closed"][terminal])
            XCTAssertEqual(driver.snapshot.sends, terminal == "retry" ? 2 : 1)
            XCTAssertEqual(driver.payloads, Array(repeating: udpLifecyclePayload, count: terminal == "retry" ? 2 : 1))
            await transport.close()
            await sleeper.join()
        }
    }

    func testRecoverableFailuresStopAtConfiguredAttemptCount() async throws {
        let driver = ScriptedUDPConnection()
        let sleeper = ManualUDPSleeper()
        let transport = try await readyTransport(driver: driver, sleeper: sleeper, configuration: .init(maxRetries: 3))
        let ledger = UDPSettlementLedger()
        let send = Task { await ledger.record { try await transport.send(udpLifecyclePayload) } }
        for attempt in 0..<3 {
            await driver.waitForSends(attempt + 1)
            await sleeper.waitForPending(1)
            driver.completeSend(attempt, with: .failure(.sendFailed("attempt-\(attempt)")))
            if attempt < 2 {
                while sleeper.durations != [.milliseconds(100 * (attempt + 1))] { await Task.yield() }
                sleeper.advanceFirst()
            }
        }
        let result = await send.value
        XCTAssertEqual(result, "send:attempt-2")
        XCTAssertEqual(driver.snapshot.sends, 3)
        XCTAssertEqual(driver.snapshot.cancels, 0)
        let pending = await transport.pendingOperationCount
        XCTAssertEqual(pending, 0)
        await transport.close()
        await sleeper.join()
    }

    func testConfigurationValidationPrecedesDriverStartAndDurationConversion() async throws {
        let invalid: [UDPTransport.Configuration] = [
            .init(port: 0), .init(port: -1), .init(port: 65_536), .init(port: Int.max),
            .init(timeout: 0), .init(timeout: -1), .init(timeout: .nan), .init(timeout: .infinity),
            .init(connectionTimeout: 0), .init(connectionTimeout: -1), .init(connectionTimeout: .nan),
            .init(connectionTimeout: .infinity), .init(maxRetries: 0), .init(maxRetries: -1)
        ]
        for configuration in invalid {
            let driver = ScriptedUDPConnection()
            let sleeper = ManualUDPSleeper()
            XCTAssertThrowsError(try makeTransport(driver: driver, sleeper: sleeper, configuration: configuration)) { error in
                guard case TransportError.invalidConfiguration = error else { return XCTFail("Unexpected \(error)") }
            }
            XCTAssertEqual(driver.snapshot.starts, 0)
            XCTAssertEqual(sleeper.snapshot.entered, 0)
        }
        // A finite duration beyond Duration's representable seconds must not trap.
        let driver = ScriptedUDPConnection()
        let sleeper = ManualUDPSleeper()
        let transport = try await readyTransport(driver: driver, sleeper: sleeper, configuration: .init(
            port: 65_535, timeout: .greatestFiniteMagnitude, connectionTimeout: .greatestFiniteMagnitude, maxRetries: Int.max
        ))
        let send = Task { try await transport.send(udpLifecyclePayload) }
        await driver.waitForSends(1)
        await sleeper.waitForPending(1)
        driver.completeSend(0, with: .success(()))
        try await send.value
        await transport.close()
        await sleeper.join()
    }
}
