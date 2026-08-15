//
//  CircuitBreakerProbeAccountingTests.swift
//  PipelineKit
//
//  Half-open transitions must be driven solely by the probe's outcome.
//  A stale request admitted while the circuit was CLOSED and completing
//  during HALF-OPEN must not clear the probe slot, count toward
//  halfOpenSuccessThreshold, or re-open the circuit.
//

import XCTest
@testable import PipelineKitCore
import PipelineKitResilience

private struct AccountingCommand: Command {
    typealias Result = String
}

private enum AccountingFailure: Error {
    case boom // maps to `.unknown`, triggering under the default configuration
}

/// Minimal async gate: `wait()` suspends until `open()`; `open()` before
/// `wait()` makes `wait()` return immediately.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

final class CircuitBreakerProbeAccountingTests: XCTestCase {
    private func makeBreaker() -> CircuitBreakerMiddleware {
        CircuitBreakerMiddleware(
            configuration: CircuitBreakerMiddleware.Configuration(
                failureThreshold: 1,
                recoveryTimeout: 0.1, // clamped minimum
                halfOpenSuccessThreshold: 1
            )
        )
    }

    func testStaleSuccessDuringHalfOpenDoesNotDriveProbeAccounting() async throws {
        let breaker = makeBreaker()
        let staleEntered = Gate(), staleRelease = Gate()
        let probeEntered = Gate(), probeRelease = Gate()

        // R1: admitted while CLOSED, parks inside the chain.
        let stale = Task {
            try await breaker.execute(AccountingCommand(), context: CommandContext()) { _, _ in
                await staleEntered.open()
                await staleRelease.wait()
                return "stale-ok"
            }
        }
        await staleEntered.wait()

        // Trip the breaker -> OPEN.
        do {
            _ = try await breaker.execute(AccountingCommand(), context: CommandContext()) { _, _ in
                throw AccountingFailure.boom
            }
            XCTFail("tripping call should rethrow")
        } catch { /* expected */ }

        try await Task.sleep(nanoseconds: 200_000_000) // > recoveryTimeout

        // R2: admitted as the half-open probe, parks inside the chain.
        let probe = Task {
            try await breaker.execute(AccountingCommand(), context: CommandContext()) { _, _ in
                await probeEntered.open()
                await probeRelease.wait()
                return "probe-ok"
            }
        }
        await probeEntered.wait()

        // The stale closed-era request completes successfully DURING half-open.
        await staleRelease.open()
        let staleResult = try await stale.value
        XCTAssertEqual(staleResult, "stale-ok")

        // Stale success must not close the circuit or free the probe slot:
        // while the real probe is still in flight, new traffic stays rejected.
        do {
            _ = try await breaker.execute(AccountingCommand(), context: CommandContext()) { _, _ in "should-not-run" }
            XCTFail("stale success drove half-open accounting: traffic admitted while the probe was still in flight")
        } catch let error as PipelineError {
            _ = error // expected fast-fail rejection
        }

        // The real probe's success closes the circuit.
        await probeRelease.open()
        let probeResult = try await probe.value
        XCTAssertEqual(probeResult, "probe-ok")

        let after = try await breaker.execute(AccountingCommand(), context: CommandContext()) { _, _ in "closed-ok" }
        XCTAssertEqual(after, "closed-ok")
    }
}
