import Foundation
import Synchronization
import XCTest
import PipelineKitCore

// Run callback tests under Scripts/validation/run_check.py: a callback under the
// nonrecursive storage lock traps on Apple platforms and can block elsewhere.
final class CommandContextCallbackTests: XCTestCase {
    func testDebugDescriptionReadsSameContextFromStoredValue() {
        let context = CommandContext()
        context.userID = "description-owner"
        let value = CallbackDescription { [weak context] in context?.userID ?? "missing" }
        context[ContextKey<CallbackDescription>("callback")] = value
        XCTAssertEqual(value.description, "description-owner")
        let description = context.debugDescription
        XCTAssertTrue(description.contains("callback: AnySendable(description-owner)"))
        XCTAssertTrue(description.contains("CommandContext(id: \(context.commandMetadata.id),"))
    }

    func testDebugDescriptionMetadataGetterReentry() { exerciseMetadata(.debugDescription) }
    func testSnapshotMetadataGetterReentry() { exerciseMetadata(.snapshot) }
    func testSnapshotRawMetadataGetterReentry() { exerciseMetadata(.snapshotRaw) }
    func testClearMetadataGetterReentry() { exerciseMetadata(.clear) }

    func testOrdinaryMetadataAndContentControls() {
        for path in CallbackPath.allCases {
            let metadata = DefaultCommandMetadata(id: callbackID, timestamp: callbackDate,
                                                  userID: "owner", correlationID: "correlation")
            let context = CommandContext(metadata: metadata)
            context[ContextKey<Int>("content")] = 73
            let result = path.perform(context)
            assertResult(result, path: path, context: context, id: callbackID,
                         user: "owner", correlation: "correlation")
        }
    }

    func testSnapshotsRetainCapturedPayloadUntilResultIsReleased() {
        for path in [CallbackPath.snapshot, .snapshotRaw] {
            let context = CommandContext()
            let released = Mutex<[Int?]>([])
            context[ContextKey<Int>("marker")] = 73
            let witness = installPayload(in: context, key: "payload") { [weak context] in
                let observed = context?[ContextKey<Int>("marker")]
                released.withLock { $0.append(observed) }
            }
            var result: [String: AnySendable]? = path.perform(context).storage
            XCTAssertNotNil(result?["payload"]?.get(CallbackPayload.self))
            context.remove(ContextKey<CallbackPayload>("payload"))
            XCTAssertNotNil(witness.value)
            XCTAssertTrue(released.withLock { $0.isEmpty })
            result = nil
            XCTAssertNil(witness.value)
            XCTAssertEqual(released.withLock { $0 }, [73])
        }
    }

    func testSnapshotMetadataCallbacksCanRemoveCapturedValues() {
        for path in [CallbackPath.snapshot, .snapshotRaw] {
            for key in ["payload", "commandMetadata"] {
                let metadata = CallbackMetadata()
                let context = CommandContext(metadata: metadata)
                context[ContextKey<Date>("timestamp")] = callbackDate
                let released = Mutex<[Bool]>([])
                let witness = installPayload(in: context, key: key) { [weak context] in
                    let removed = context?.contains(ContextKey<CallbackPayload>(key)) == false
                    released.withLock { $0.append(removed) }
                }
                metadata.attach(context, onRead: { context, _ in
                    context.remove(ContextKey<CallbackPayload>(key))
                })
                var result: CallbackResult? = path.perform(context)
                XCTAssertEqual(result?.metadata?["id"] as? String, callbackID.uuidString)
                XCTAssertEqual(result?.metadata?["timestamp"] as? Date, callbackDate)
                if key == "payload" {
                    XCTAssertNotNil(result?.storage?[key]?.get(CallbackPayload.self))
                    XCTAssertNotNil(witness.value)
                    XCTAssertTrue(released.withLock { $0.isEmpty })
                }
                result = nil
                XCTAssertNil(witness.value)
                XCTAssertEqual(released.withLock { $0 }, [true])
            }
        }
    }

    func testAbsentMetadataFieldsRemainAbsentAfterClear() {
        let context = CommandContext(metadata: DefaultCommandMetadata(id: callbackID, timestamp: callbackDate))
        for path in [CallbackPath.snapshot, .snapshotRaw] {
            let result = path.perform(context)
            XCTAssertEqual(result.metadata?["userID"] as? String, "")
            XCTAssertEqual(result.metadata?["correlationID"] as? String, "")
        }
        context.userID = "discarded"
        context.correlationID = "discarded"
        context.requestID = "discarded"
        context.startTime = callbackDate
        context.clear()
        XCTAssertEqual(context[ContextKeys.commandID], callbackID)
        XCTAssertNil(context.userID)
        XCTAssertNil(context.correlationID)
        XCTAssertNil(context.requestID)
        XCTAssertNil(context.startTime)
    }

    func testConcurrentClearsRestoreMetadataBeforeRetiringValues() async {
        let metadata = CallbackMetadata()
        let context = CommandContext(metadata: metadata)
        metadata.attach(context)
        let released = Mutex<[Bool]>([])
        let witness = installPayload(in: context, key: "payload") { [weak context] in
            guard let context else { released.withLock { $0.append(false) }; return }
            let restored = context[ContextKeys.commandID] == callbackID && context.userID == "owner" &&
                context.correlationID == "correlation" && context.requestID == "correlation" &&
                !context.contains(ContextKey<CallbackPayload>("payload"))
            released.withLock { $0.append(restored) }
        }
        let count = 64
        let gate = CallbackStartGate(expected: count)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    await gate.arrive()
                    context.clear()
                }
            }
        }
        XCTAssertNil(witness.value)
        XCTAssertEqual(released.withLock { $0 }, [true])
        XCTAssertEqual(context[ContextKeys.commandID], callbackID)
        XCTAssertEqual(context.userID, "owner")
        XCTAssertEqual(context.correlationID, "correlation")
        XCTAssertEqual(context.requestID, "correlation")
        XCTAssertEqual(metadata.reads.count, count * 3)
    }

    func testDebugDescriptionRetainsValuesWhileCallbackRemovesStorage() {
        let context = CommandContext()
        context.userID = "retained-owner"
        let released = DescriptionReleases()
        let witness = installDescription(in: context, released: released)
        // Assert the weak lifetime as a Bool so XCTest cannot format this
        // CustomStringConvertible payload before the operation under test.
        let retainedBeforeDescription = witness.value != nil
        XCTAssertTrue(retainedBeforeDescription)
        XCTAssertTrue(context.contains(ContextKey<CallbackDescription>("callback")))
        let result = context.debugDescription
        XCTAssertTrue(result.contains("callback: AnySendable(retained-owner)"), result)
        XCTAssertFalse(context.contains(ContextKey<CallbackDescription>("callback")))
        XCTAssertNil(witness.value)
        XCTAssertEqual(released.values, ["retained-owner"])
    }

    private func exerciseMetadata(_ path: CallbackPath) {
        let metadata = CallbackMetadata()
        let context = CommandContext(metadata: metadata)
        // Each getter returns a value read from this context, rather than a stub.
        context[ContextKeys.commandID] = callbackReplacementID
        context.userID = "changed-owner"
        context.correlationID = "changed-correlation"
        context.requestID = "old-request"
        context[ContextKey<Date>("timestamp")] = callbackDate
        context[ContextKey<Int>("content")] = 73
        metadata.attach(context)
        let result = path.perform(context)
        assertResult(result, path: path, context: context, id: callbackReplacementID,
                     user: "changed-owner", correlation: "changed-correlation")
        let expected: [String] = switch path {
        case .debugDescription: ["id"]
        case .snapshot, .snapshotRaw: ["id", "timestamp", "userID", "correlationID"]
        case .clear: ["id", "userID", "correlationID"]
        }
        XCTAssertEqual(metadata.reads, expected)
    }

    private func assertResult(
        _ result: CallbackResult,
        path: CallbackPath,
        context: CommandContext,
        id: UUID,
        user: String,
        correlation: String
    ) {
        switch path {
        case .debugDescription:
            XCTAssertEqual(result.description?.contains("CommandContext(id: \(id),"), true)
            XCTAssertEqual(result.description?.contains("content: AnySendable(73)"), true)
        case .snapshot, .snapshotRaw:
            XCTAssertEqual(result.storage?["content"]?.get(Int.self), 73)
            XCTAssertEqual(result.metadata?["id"] as? String, id.uuidString)
            XCTAssertEqual(result.metadata?["timestamp"] as? Date, callbackDate)
            XCTAssertEqual(result.metadata?["userID"] as? String, user)
            XCTAssertEqual(result.metadata?["correlationID"] as? String, correlation)
        case .clear:
            XCTAssertEqual(context[ContextKeys.commandID], id)
            XCTAssertEqual(context.userID, user)
            XCTAssertEqual(context.correlationID, correlation)
            XCTAssertEqual(context.requestID, correlation)
            XCTAssertFalse(context.contains(ContextKey<Int>("content")))
            XCTAssertNil(context.startTime)
        }
    }

    private func installPayload(
        in context: CommandContext,
        key: String,
        onRelease: @escaping @Sendable () -> Void
    ) -> WeakCallbackPayload {
        let value = CallbackPayload(onRelease: onRelease)
        context[ContextKey<CallbackPayload>(key)] = value
        return WeakCallbackPayload(value: value)
    }

    private func installDescription(in context: CommandContext,
                                    released: DescriptionReleases) -> WeakCallbackDescription {
        let value = CallbackDescription(read: { [weak context] in
            guard let context else { return "missing" }
            context.remove(ContextKey<CallbackDescription>("callback"))
            return context.userID ?? "missing"
        }, onRelease: { [weak context] in
            let user = context?.userID
            released.record(user)
        })
        context[ContextKey<CallbackDescription>("callback")] = value
        return WeakCallbackDescription(value: value)
    }
}

private let callbackID = UUID(uuidString: "00000000-0000-0000-0000-000000000073")!
private let callbackReplacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000074")!
private let callbackDate = Date(timeIntervalSince1970: 73)

private enum CallbackPath: CaseIterable {
    case debugDescription, snapshot, snapshotRaw, clear

    func perform(_ context: CommandContext) -> CallbackResult {
        switch self {
        case .debugDescription: return CallbackResult(description: context.debugDescription)
        case .snapshot:
            let snapshot = context.snapshot()
            return CallbackResult(storage: snapshot.compactMapValues { $0 as? AnySendable },
                                  metadata: snapshot["commandMetadata"] as? [String: any Sendable])
        case .snapshotRaw:
            let snapshot = context.snapshotRaw()
            return CallbackResult(storage: snapshot,
                                  metadata: snapshot["commandMetadata"]?.get([String: any Sendable].self))
        case .clear:
            context.clear()
            return CallbackResult()
        }
    }
}

private struct CallbackResult {
    var description: String?
    var storage: [String: AnySendable]?
    var metadata: [String: any Sendable]?
}

private final class CallbackMetadata: CommandMetadata {
    private struct State {
        weak var context: CommandContext?
        var reads: [String] = []
        var onRead: (@Sendable (CommandContext, String) -> Void)?
    }
    private let state = Mutex(State())

    func attach(_ context: CommandContext,
                onRead: (@Sendable (CommandContext, String) -> Void)? = nil) {
        state.withLock { $0.context = context; $0.onRead = onRead }
    }

    private func owner(_ field: String) -> CommandContext? {
        let (context, callback) = state.withLock { state in
            if state.context != nil { state.reads.append(field) }
            return (state.context, state.onRead)
        }
        if let context { callback?(context, field) }
        return context
    }

    var reads: [String] { state.withLock { $0.reads } }
    var id: UUID { owner("id")?[ContextKeys.commandID] ?? callbackID }
    var timestamp: Date { owner("timestamp")?[ContextKey<Date>("timestamp")] ?? callbackDate }
    var userID: String? {
        guard let context = owner("userID") else { return "owner" }
        return context.userID
    }
    var correlationID: String? {
        guard let context = owner("correlationID") else { return "correlation" }
        return context.correlationID
    }
}

private final class CallbackDescription: Sendable, CustomStringConvertible {
    let read: @Sendable () -> String
    let onRelease: @Sendable () -> Void
    init(read: @escaping @Sendable () -> String, onRelease: @escaping @Sendable () -> Void = {}) {
        self.read = read
        self.onRelease = onRelease
    }
    var description: String { read() }
    deinit { onRelease() }
}

private final class CallbackPayload: Sendable {
    let onRelease: @Sendable () -> Void
    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

private struct WeakCallbackPayload { weak var value: CallbackPayload? }
private struct WeakCallbackDescription { weak var value: CallbackDescription? }

private final class DescriptionReleases: Sendable {
    private let state = Mutex<[String?]>([])
    func record(_ value: String?) { state.withLock { $0.append(value) } }
    var values: [String?] { state.withLock { $0 } }
}

private actor CallbackStartGate {
    let expected: Int
    var arrivals: [CheckedContinuation<Void, Never>] = []
    init(expected: Int) { self.expected = expected }
    func arrive() async {
        await withCheckedContinuation { continuation in
            arrivals.append(continuation)
            if arrivals.count == expected {
                let waiting = arrivals
                arrivals.removeAll()
                for waiter in waiting { waiter.resume() }
            }
        }
    }
}
