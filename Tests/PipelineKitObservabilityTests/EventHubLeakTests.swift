import XCTest
import PipelineKitCore
import PipelineKitObservability

/// Tests that `EventHub` does not leak via its periodic cleanup task.
///
/// `EventHub` is an actor that spawns a long-lived cleanup `Task` in its
/// initializer. If that task captured `self` strongly, the infinite loop would
/// form a permanent retain cycle (the actor retains the task; the task retains
/// the actor) and every `EventHub` instance would leak forever. The fix captures
/// `self` weakly and copies the immutable `cleanupInterval` by value, so the
/// actor can deallocate once external references are dropped.
///
/// These tests verify that behavior is observable and that normal
/// emit/subscribe functionality still works after the change.
final class EventHubLeakTests: XCTestCase {
    /// Number of polling iterations to wait for deallocation.
    private static let pollIterations = 200

    /// Per-iteration sleep while polling for deallocation (5ms).
    private static let pollSleepNanos: UInt64 = 5_000_000

    // MARK: - Deallocation

    /// The hub must deallocate once the last strong reference is dropped.
    ///
    /// Before the fix this FAILS: the cleanup task strongly retains the actor in
    /// an infinite loop, so the weak reference never becomes `nil`. After the fix
    /// the weakly-captured cleanup loop allows the actor to deallocate, and on its
    /// next wake-up the loop exits via `guard let self else { break }`.
    func testEventHubDeallocatesWhenReferenceDropped() async throws {
        weak var weakHub: EventHub?

        // Inner scope holds the only strong reference. A small cleanupInterval
        // makes the cleanup loop wake frequently, so the post-dealloc
        // `guard let self else { break }` path runs quickly during the test.
        do {
            let hub = EventHub(cleanupInterval: 0.01)
            weakHub = hub

            // The initializer spawns `Task { await startCleanupTask() }`, which
            // strongly retains `hub` until it begins executing and the inner
            // closure captures `self` weakly. Let that init task run before we
            // drop our strong reference, otherwise the pending init task would
            // keep the actor alive independently of the cleanup loop.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms

            // Sanity check: the hub is alive while the strong reference exists.
            XCTAssertNotNil(weakHub, "Hub should be alive while strongly referenced")

            // `hub` goes out of scope at the end of this block.
        }

        // Poll for deallocation. The only thing that could retain the actor after
        // the strong reference is gone is the cleanup task, which holds nothing
        // strong while it sleeps, so deallocation should happen promptly once the
        // runtime settles. Polling (rather than a single fixed sleep) keeps the
        // assertion deterministic and fast.
        for _ in 0..<Self.pollIterations {
            if weakHub == nil { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: Self.pollSleepNanos)
        }

        XCTAssertNil(
            weakHub,
            "EventHub leaked: the cleanup task must capture self weakly so the actor can deallocate"
        )
    }

    // MARK: - No Regression

    /// Emit/subscribe must still work after the weak-capture change.
    ///
    /// This guards against accidentally breaking event delivery while fixing the
    /// retain cycle (e.g. by also weakening something that should stay strong).
    func testEmitStillDeliversAfterFix() async throws {
        let hub = EventHub(cleanupInterval: 0.01)
        let subscriber = LeakTestSubscriber()
        await hub.subscribe(subscriber)

        let event = PipelineEvent(
            name: "leak.test",
            properties: [:],
            correlationID: "leak-test-correlation"
        )

        // Use the async emit overload so delivery is observable deterministically.
        await hub.emit(event)

        // Event fan-out happens inside the actor's isolation domain; poll briefly
        // for eventual consistency rather than relying on a single fixed sleep.
        var receivedCount = await subscriber.count
        for _ in 0..<Self.pollIterations {
            if receivedCount >= 1 { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: Self.pollSleepNanos)
            receivedCount = await subscriber.count
        }

        XCTAssertEqual(receivedCount, 1, "Subscriber should receive the emitted event")

        // Keep the hub alive until the end of the test so deallocation timing does
        // not interfere with delivery verification.
        withExtendedLifetime(hub) {}
    }
}

// MARK: - Test Support

/// Minimal subscriber that counts received events.
///
/// Named distinctly from the existing `MockSubscriber` / `EventCapturingSubscriber`
/// in this test target to avoid duplicate module-level declarations.
private actor LeakTestSubscriber: EventSubscriber {
    private(set) var count = 0

    func process(_ event: PipelineEvent) async {
        count += 1
    }
}
