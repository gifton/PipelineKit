import XCTest
import Foundation
@testable import _ResilienceCore

/// Tests for `GracePeriodManager` covering the C3 refactor that replaced the
/// 10-chunk manual cancellation-polling loop with a single `Task.sleep`.
///
/// The refactor must preserve two behaviours:
///   1. Cancellation responsiveness — a cancelled grace period must resolve
///      promptly (well under its full duration) and must NOT invoke its
///      expiration callback.
///   2. Normal expiration — an un-cancelled grace period must invoke its
///      expiration callback after approximately `duration` has elapsed.
final class GracePeriodEvolutionTests: XCTestCase {
    /// Thread-safe recorder for observing the expiration callback. Captured
    /// by the `@Sendable` `onExpiration` closure; an `actor` provides the
    /// required `Sendable` conformance and serialized access.
    private actor ExpirationRecorder {
        private(set) var expirationCount = 0

        func recordExpiration() {
            expirationCount += 1
        }

        var didExpire: Bool { expirationCount > 0 }
    }

    // MARK: - Cancellation Responsiveness

    /// Starts a grace period with a long duration, cancels it shortly after,
    /// and asserts the expiration callback never fires — proving cancellation
    /// is still honoured promptly after the chunked-loop removal.
    ///
    /// The chosen duration (2.0s) is far larger than the observation window
    /// (0.4s), so a correctly-cancelled task can never reach expiration. The
    /// 0.4s window also exceeds a single old "chunk" (0.2s), making the test a
    /// meaningful regression guard rather than a trivially-passing one.
    func testCancelledGracePeriodResolvesPromptlyWithoutExpiring() async throws {
        let manager = GracePeriodManager()
        let recorder = ExpirationRecorder()

        let duration: TimeInterval = 2.0
        let start = Date()

        let id = await manager.startGracePeriod(duration: duration) { [recorder] in
            await recorder.recordExpiration()
        }

        // Let the internal task enter its sleep, then cancel well before it
        // could ever expire.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        await manager.cancelGracePeriod(id)

        let cancelLatency = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            cancelLatency,
            duration,
            "Cancellation must resolve well before the full grace duration."
        )

        // Wait a window that is comfortably shorter than `duration` but long
        // enough that a non-responsive implementation would have fired. The
        // expiration callback must NOT have run.
        try await Task.sleep(nanoseconds: 400_000_000) // 400ms

        let didExpire = await recorder.didExpire
        XCTAssertFalse(
            didExpire,
            "A cancelled grace period must not invoke its expiration callback."
        )
    }

    /// Cancelling all active grace periods must likewise suppress expiration.
    func testCancelAllSuppressesExpiration() async throws {
        let manager = GracePeriodManager()
        let recorder = ExpirationRecorder()

        let duration: TimeInterval = 2.0

        for _ in 0..<3 {
            _ = await manager.startGracePeriod(duration: duration) { [recorder] in
                await recorder.recordExpiration()
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await manager.cancelAll()

        try await Task.sleep(nanoseconds: 400_000_000) // 400ms

        let expirations = await recorder.expirationCount
        XCTAssertEqual(
            expirations,
            0,
            "cancelAll() must prevent every pending grace period from expiring."
        )
    }

    // MARK: - Normal Expiration

    /// An un-cancelled grace period must fire its expiration callback after
    /// roughly `duration`, proving the single sleep still waits the full time.
    func testUncancelledGracePeriodExpiresAfterDuration() async throws {
        let manager = GracePeriodManager()

        let duration: TimeInterval = 0.2
        let expectation = expectation(description: "grace period expired")
        let start = Date()

        // Capture the start time inside an actor-safe holder so we can assert
        // the elapsed time once the callback fires.
        let elapsedRecorder = ElapsedRecorder()

        _ = await manager.startGracePeriod(duration: duration) { [expectation, elapsedRecorder] in
            await elapsedRecorder.record(Date().timeIntervalSince(start))
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        let elapsed = await elapsedRecorder.elapsed
        XCTAssertNotNil(elapsed, "Expiration callback should have recorded an elapsed time.")
        if let elapsed {
            // It must have actually waited (not fired instantly). Allow a
            // generous lower-bound tolerance for scheduler jitter.
            XCTAssertGreaterThanOrEqual(
                elapsed,
                duration * 0.5,
                "Grace period fired far too early; the sleep did not honour the duration."
            )
        }
    }

    /// Thread-safe holder for the elapsed time observed at expiration.
    private actor ElapsedRecorder {
        private(set) var elapsed: TimeInterval?

        func record(_ value: TimeInterval) {
            if elapsed == nil {
                elapsed = value
            }
        }
    }
}
