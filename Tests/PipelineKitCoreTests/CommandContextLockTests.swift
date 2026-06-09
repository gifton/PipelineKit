import XCTest
import Foundation
@testable import PipelineKitCore

/// Tests for `CommandContext`'s internal locking, covering the C4 change that
/// swapped the storage lock from `NSLock` to `OSAllocatedUnfairLock` on Apple
/// platforms.
///
/// The lock is the highest-frequency synchronization point in the system —
/// every typed-key get/set, every metadata/metrics mutation, and every
/// snapshot acquires it via the `withLock` helper. These tests verify that
/// the swap preserved correctness under both trivial and heavily-contended
/// concurrent access, with no crashes and a consistent, deterministic final
/// state.
final class CommandContextLockTests: XCTestCase {
    // MARK: - Basic Correctness

    /// A plain single-threaded round trip through the typed subscript and the
    /// property accessors. Guards against any regression in the locked
    /// read/write path introduced by the lock swap.
    func testBasicRoundTripGetSet() {
        let context = CommandContext()

        // Typed-key subscript round trip.
        let intKey = ContextKey<Int>("roundTripInt")
        let stringKey = ContextKey<String>("roundTripString")

        context[intKey] = 42
        context[stringKey] = "hello"

        let readInt: Int? = context[intKey]
        let readString: String? = context[stringKey]
        XCTAssertEqual(readInt, 42)
        XCTAssertEqual(readString, "hello")

        // Property-accessor round trip.
        context.requestID = "req-123"
        context.userID = "user-456"
        XCTAssertEqual(context.requestID, "req-123")
        XCTAssertEqual(context.userID, "user-456")

        // Overwrite and removal.
        context[intKey] = 7
        XCTAssertEqual(context[intKey], 7)

        context[intKey] = nil
        let removed: Int? = context[intKey]
        XCTAssertNil(removed)
    }

    /// Metadata and metrics dictionaries round trip through their locked
    /// accessors.
    func testMetadataAndMetricsRoundTrip() {
        let context = CommandContext()

        context.setMetadata("env", value: "test")
        context.setMetric("latency", value: 0.125)

        let env = context.getMetadata("env") as? String
        let latency = context.getMetric("latency") as? Double

        XCTAssertEqual(env, "test")
        XCTAssertEqual(latency ?? 0, 0.125, accuracy: 1e-9)
    }

    // MARK: - Concurrent Stress

    /// Many concurrent tasks perform interleaved get/set, each on its OWN
    /// dedicated key. Because each key is written by exactly one logical
    /// writer whose final write is deterministic, the post-condition is fully
    /// defined: every key must hold its expected final value. Interleaved
    /// reads on the same task exercise the read path concurrently with all
    /// other writers, maximizing lock traffic.
    ///
    /// Success criteria: no crash / no torn read, and a consistent final
    /// state across every key.
    func testConcurrentInterleavedGetSetIsConsistentAndCrashFree() async {
        let context = CommandContext()
        let writerCount = 256
        let opsPerWriter = 200

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writerCount {
                group.addTask {
                    let key = ContextKey<Int>("writer-\(writer)")
                    // Interleave writes and reads on this writer's own key.
                    for op in 0..<opsPerWriter {
                        context[key] = op
                        // Read back; value is monotonic per-writer but other
                        // writers race on their own keys, so we only assert
                        // non-nil here (final consistency is checked below).
                        let observed: Int? = context[key]
                        XCTAssertNotNil(observed)
                    }
                    // Deterministic final write for this key.
                    context[key] = writer
                }
            }
        }

        // Consistent final state: each key holds its writer's final value.
        for writer in 0..<writerCount {
            let key = ContextKey<Int>("writer-\(writer)")
            let value: Int? = context[key]
            XCTAssertEqual(value, writer, "Key writer-\(writer) lost its final write under contention.")
        }
    }

    /// Maximal contention on a SINGLE shared key: every task races to set and
    /// read the same key. The final value is non-deterministic but must be one
    /// of the written values, and the run must not crash. This is the harshest
    /// exercise of the uncontended-fast-path lock under actual contention.
    func testConcurrentSharedKeyContentionDoesNotCrash() async {
        let context = CommandContext()
        let sharedKey = ContextKey<Int>("shared-counter-key")
        let taskCount = 128
        let opsPerTask = 250

        await withTaskGroup(of: Void.self) { group in
            for task in 0..<taskCount {
                group.addTask {
                    let writeValue = task
                    for _ in 0..<opsPerTask {
                        context[sharedKey] = writeValue
                        _ = context[sharedKey]
                    }
                }
            }
        }

        // The surviving value must be one a task actually wrote.
        let finalValue: Int? = context[sharedKey]
        XCTAssertNotNil(finalValue)
        if let finalValue {
            XCTAssertTrue(
                (0..<taskCount).contains(finalValue),
                "Final shared value \(finalValue) was never written by any task — indicates corruption."
            )
        }
    }

    /// Mixed operation classes (typed keys, metadata, metrics, snapshots) run
    /// concurrently to ensure every locked code path is safe together, not
    /// just the subscript path.
    func testConcurrentMixedLockedOperationsDoNotCrash() async {
        let context = CommandContext()
        let groupSize = 100

        await withTaskGroup(of: Void.self) { group in
            // Typed-key writers.
            for i in 0..<groupSize {
                group.addTask {
                    context[ContextKey<Int>("typed-\(i)")] = i
                }
            }
            // Metadata writers.
            for i in 0..<groupSize {
                group.addTask {
                    context.setMetadata("meta-\(i)", value: i)
                }
            }
            // Metrics writers.
            for i in 0..<groupSize {
                group.addTask {
                    context.setMetric("metric-\(i)", value: Double(i))
                }
            }
            // Snapshot readers contend with all writers.
            for _ in 0..<groupSize {
                group.addTask {
                    _ = context.snapshot()
                }
            }
        }

        // Typed keys are single-writer per key, so they must all be present.
        for i in 0..<groupSize {
            let value: Int? = context[ContextKey<Int>("typed-\(i)")]
            XCTAssertEqual(value, i)
        }

        // Metadata and metrics each accumulated their writes.
        XCTAssertEqual(context.getMetadata().count, groupSize)
        XCTAssertEqual(context.getMetrics().count, groupSize)
    }
}
