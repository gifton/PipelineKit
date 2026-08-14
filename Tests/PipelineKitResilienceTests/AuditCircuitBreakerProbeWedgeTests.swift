//
//  AuditCircuitBreakerProbeWedgeTests.swift
//  PipelineKit
//
//  Audit evidence tests (2026-08): demonstrate a liveness defect found during the
//  pre-integration audit.
//
//  Defect: when the single half-open probe request throws an error that
//  `shouldTriggerCircuit` classifies as non-triggering (e.g. `CancellationError`,
//  hardcoded to `false`), the breaker records neither success nor failure. The
//  `probeInProgress` flag — set when the probe was admitted — is never cleared, and
//  the `.halfOpen` branch of `allowRequest()` has no time-based escape. The breaker
//  then rejects every subsequent request forever while reporting half-open.
//
//  `testWedge_...` PASSES while the defect exists (it pins the buggy behavior as
//  evidence). When the defect is fixed, it will fail and should be replaced by the
//  inverse assertion. `testControl_...` proves the harness itself is sound: absent
//  an abandoned probe, the breaker recovers normally.
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

    /// Evidence of the defect: a probe abandoned via a non-triggering error
    /// (CancellationError) wedges the breaker permanently — no amount of waiting
    /// re-admits traffic.
    func testWedge_AbandonedProbeRejectsAllTrafficForever_KnownDefect() async throws {
        let breaker = makeBreaker()
        await trip(breaker)

        try await Task.sleep(nanoseconds: 200_000_000) // > recoveryTimeout

        // The probe IS admitted (open -> halfOpen) — we observe its own error, not a
        // fast-fail rejection — then aborts with a non-triggering error.
        do {
            _ = try await breaker.execute(ProbeCommand(), context: CommandContext()) { _, _ in
                throw CancellationError()
            }
            XCTFail("probe should rethrow its own error")
        } catch is CancellationError {
            // expected: admitted, then aborted; neither recordSuccess nor recordFailure ran
        } catch {
            XCTFail("probe was rejected instead of admitted: \(error)")
        }

        // From here on the breaker is wedged: every request is rejected no matter how
        // long we wait (each wait is 2x the recovery timeout).
        for round in 1...3 {
            try await Task.sleep(nanoseconds: 200_000_000)
            do {
                _ = try await breaker.execute(ProbeCommand(), context: CommandContext()) { _, _ in "should-not-run" }
                XCTFail("round \(round): breaker recovered — defect appears FIXED; " +
                        "invert this test into a recovery assertion and delete the wedge pin")
            } catch let error as PipelineError {
                // expected: fast-fail rejection — the wedge persists
                _ = error
            }
        }
    }
}
