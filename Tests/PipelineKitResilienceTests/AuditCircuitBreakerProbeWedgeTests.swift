//
//  AuditCircuitBreakerProbeWedgeTests.swift
//  PipelineKit
//
//  Audit evidence tests (2026-08): pin the fixed behavior for a liveness defect
//  found during the pre-integration audit (#92).
//
//  Former defect: when the single half-open probe request threw an error that
//  `shouldTriggerCircuit` classified as non-triggering (e.g. `CancellationError`,
//  hardcoded to `false`), the breaker recorded neither success nor failure. The
//  `probeInProgress` flag — set when the probe was admitted — was never cleared, and
//  the `.halfOpen` branch of `allowRequest()` had no time-based escape. The breaker
//  then rejected every subsequent request forever while reporting half-open.
//
//  Fix: `State` now classifies admission via `admitRequest() -> Admission`, and
//  `execute` guarantees resolution of an admitted probe — via `abandonProbe()` in a
//  `defer` — on every exit path, including a non-triggering error. `testAbandoned...`
//  pins that recovery: an abandoned probe releases its slot so the next request
//  becomes the new probe and can close the circuit. `testControl_...` proves the
//  harness itself is sound: absent an abandoned probe, the breaker recovers normally.
//

import XCTest
@testable import PipelineKitCore
import PipelineKitResilience

private struct ProbeCommand: Command {
    typealias Result = String
}

private enum GenericFailure: Error {
    case boom // maps to `.unknown`, which the default configuration treats as triggering
}

final class AuditCircuitBreakerProbeWedgeTests: XCTestCase {
    private func makeBreaker() -> CircuitBreakerMiddleware {
        CircuitBreakerMiddleware(
            configuration: CircuitBreakerMiddleware.Configuration(
                failureThreshold: 1,
                recoveryTimeout: 0.1, // clamped minimum
                halfOpenSuccessThreshold: 1
            )
        )
    }

    private func trip(_ breaker: CircuitBreakerMiddleware) async {
        do {
            _ = try await breaker.execute(ProbeCommand(), context: CommandContext()) { _, _ in
                throw GenericFailure.boom
            }
            XCTFail("tripping call should rethrow")
        } catch {
            // expected: breaker records the failure and opens
        }
    }

    /// Control: after the recovery timeout, a successful probe closes the circuit and
    /// traffic flows again. Proves the fixture drives the breaker correctly.
    func testControl_SuccessfulProbeClosesCircuitAfterRecoveryTimeout() async throws {
        let breaker = makeBreaker()
        await trip(breaker)

        // While open, requests are rejected fast.
        do {
            _ = try await breaker.execute(ProbeCommand(), context: CommandContext()) { _, _ in "unreachable" }
            XCTFail("open breaker should reject")
        } catch { /* expected */ }

        try await Task.sleep(nanoseconds: 200_000_000) // > recoveryTimeout

        // Probe succeeds -> circuit closes.
        let probeResult = try await breaker.execute(ProbeCommand(), context: CommandContext()) { _, _ in "probe-ok" }
        XCTAssertEqual(probeResult, "probe-ok")

        // Circuit closed: subsequent request flows immediately.
        let after = try await breaker.execute(ProbeCommand(), context: CommandContext()) { _, _ in "closed-ok" }
        XCTAssertEqual(after, "closed-ok")
    }

    /// After the fix: a probe abandoned via a non-triggering error releases the
    /// probe slot; the next request becomes the new probe and closes the circuit.
    func testAbandonedProbeReleasesProbeSlot() async throws {
        let breaker = makeBreaker()
        await trip(breaker)

        try await Task.sleep(nanoseconds: 200_000_000) // > recoveryTimeout

        // Probe admitted (open -> halfOpen), then abandoned without an outcome.
        do {
            _ = try await breaker.execute(ProbeCommand(), context: CommandContext()) { _, _ in
                throw CancellationError()
            }
            XCTFail("probe should rethrow its own error")
        } catch is CancellationError {
            // expected: admitted, then abandoned
        } catch {
            XCTFail("probe was rejected instead of admitted: \(error)")
        }

        // The abandoned probe released its slot: this request is admitted as
        // the new probe and its success closes the circuit.
        let recovered = try await breaker.execute(ProbeCommand(), context: CommandContext()) { _, _ in "recovered" }
        XCTAssertEqual(recovered, "recovered")

        let after = try await breaker.execute(ProbeCommand(), context: CommandContext()) { _, _ in "closed-ok" }
        XCTAssertEqual(after, "closed-ok")
    }
}
