import Foundation
import Synchronization
import XCTest
import PipelineKitCore

// A release under the context lock either traps or blocks at the callback read.
// Run this class with the execution watchdog, including old-source controls.
final class CommandContextRetirementTests: XCTestCase {
    func testTypedReplacementReentry() {
        exercise(.typedReplace)
    }

    func testPublicMutationRetirementMatrix() {
        for path in MutationPath.allCases where path != .typedReplace {
            exercise(path)
        }
    }

    func testClearReleasesEveryPayloadAfterRestoringMetadata() {
        let context = CommandContext(metadata: DefaultCommandMetadata(userID: "owner", correlationID: "correlation"))
        let observations = RetirementObservations()
        var witnesses: [WeakContextPayload] = []
        for key in ["custom", "metadata", "metrics", "requestID", "commandID"] {
            witnesses.append(install(in: context, key: key, observations: observations) { context in
                context.snapshotRaw().count == 5 && context.userID == "owner" &&
                    context.requestID == "correlation" && context.correlationID == "correlation" &&
                    context[ContextKeys.commandID] == context.commandMetadata.id &&
                    context.getMetadata().isEmpty && context.getMetrics().isEmpty
            })
        }
        XCTAssertTrue(witnesses.allSatisfy { $0.value != nil })
        context.clear()
        observations.returned()
        XCTAssertTrue(witnesses.allSatisfy { $0.value == nil })
        XCTAssertEqual(observations.states, Array(repeating: true, count: witnesses.count))
        XCTAssertTrue(observations.didReturn)
    }

    func testConcurrentMetadataAndMetricsMergesConserveDisjointUpdatesAndRetireValues() async {
        let context = CommandContext()
        let observations = RetirementObservations()
        let count = 64
        var witnesses: [WeakContextPayload] = []
        for index in 0..<count {
            let key = "item-\(index)"
            let payload = ContextPayload { [weak context] in
                guard let context else { observations.record(false); return }
                observations.record(context.getMetadata(key) as? Int == index && context.getMetric(key) as? Int == index)
            }
            context.setMetadata(key, value: payload)
            context.setMetric(key, value: payload)
            witnesses.append(WeakContextPayload(value: payload))
        }
        let gate = RetirementStartGate(expected: count)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    await gate.arrive()
                    let key = "item-\(index)"
                    context.updateMetadata([key: index, "added-\(index)": index])
                    context.updateMetrics([key: index, "added-\(index)": index])
                }
            }
        }
        observations.returned()
        XCTAssertEqual(context.getMetadata().count, count * 2)
        XCTAssertEqual(context.getMetrics().count, count * 2)
        for index in 0..<count {
            XCTAssertEqual(context.getMetadata("added-\(index)") as? Int, index)
            XCTAssertEqual(context.getMetric("added-\(index)") as? Int, index)
        }
        XCTAssertTrue(witnesses.allSatisfy { $0.value == nil })
        XCTAssertEqual(observations.states, Array(repeating: true, count: count))
        XCTAssertTrue(observations.didReturn)
    }

    private func exercise(_ path: MutationPath) {
        let context = CommandContext()
        let observations = RetirementObservations()
        context[ContextKey<Int>("unrelated")] = 73
        let witness = install(in: context, key: path.key, nested: path.nested, observations: observations) { context in
            path.isCommitted(in: context) && context[ContextKey<Int>("unrelated")] == 73
        }
        XCTAssertNotNil(witness.value, "\(path)")
        FileHandle.standardError.write(Data("CONTEXT-RETIRE before \(path)\n".utf8))
        path.mutate(context)
        observations.returned()
        FileHandle.standardError.write(Data("CONTEXT-RETIRE returned \(path)\n".utf8))
        XCTAssertNil(witness.value, "\(path)")
        XCTAssertEqual(observations.states, [true], "\(path)")
        XCTAssertTrue(observations.didReturn, "\(path)")
    }

    private func install(
        in context: CommandContext,
        key: String,
        nested: Bool = false,
        observations: RetirementObservations,
        isCommitted: @escaping @Sendable (CommandContext) -> Bool
    ) -> WeakContextPayload {
        let payload = ContextPayload { [weak context] in
            FileHandle.standardError.write(Data("CONTEXT-RETIRE callback-enter \(key)\n".utf8))
            guard let context else { observations.record(false); return }
            observations.record(isCommitted(context))
            FileHandle.standardError.write(Data("CONTEXT-RETIRE callback-return \(key)\n".utf8))
        }
        if nested {
            context[ContextKey<[String: any Sendable]>(key)] = ["old": payload, "keep": 7]
        } else {
            context[ContextKey<ContextPayload>(key)] = payload
        }
        return WeakContextPayload(value: payload)
    }
}

private enum MutationPath: CaseIterable, Sendable {
    case typedReplace, typedNil, remove, updateClosure
    case metadataReplace, metadataSet, metadataMerge, metadataProperty, metadataTyped, metadataDynamic
    case metricsReplace, metricSet, metricStore, metricsMerge, metricsProperty, metricsTyped, metricsDynamic, duration
    case metadataCollisionReplace, metadataCollisionSet, metadataCollisionMerge
    case metricsCollisionReplace, metricsCollisionSet, metricsCollisionStore, metricsCollisionMerge
    case requestProperty, userProperty, correlationProperty, startProperty, dynamicTrace, cancellation

    var key: String {
        switch self {
        case .metadataReplace, .metadataSet, .metadataMerge, .metadataProperty, .metadataTyped, .metadataDynamic,
             .metadataCollisionReplace, .metadataCollisionSet, .metadataCollisionMerge: "metadata"
        case .metricsReplace, .metricSet, .metricStore, .metricsMerge, .metricsProperty, .metricsTyped, .metricsDynamic,
             .duration, .metricsCollisionReplace, .metricsCollisionSet, .metricsCollisionStore, .metricsCollisionMerge: "metrics"
        case .requestProperty: "requestID"
        case .userProperty: "userID"
        case .correlationProperty: "correlationID"
        case .startProperty: "startTime"
        case .dynamicTrace: "traceID"
        case .cancellation: "cancellationReason"
        default: "custom"
        }
    }

    var nested: Bool {
        switch self {
        case .metadataReplace, .metadataSet, .metadataMerge, .metadataProperty, .metadataTyped, .metadataDynamic,
             .metricsReplace, .metricSet, .metricStore, .metricsMerge, .metricsProperty, .metricsTyped, .metricsDynamic, .duration: true
        default: false
        }
    }

    func mutate(_ context: CommandContext) {
        switch self {
        case .typedReplace: context[ContextKey<Int>(key)] = 9
        case .typedNil: context[ContextKey<ContextPayload>(key)] = nil
        case .remove: context.remove(ContextKey<ContextPayload>(key))
        case .updateClosure: context.update { $0[ContextKey<Int>(key)] = 9 }
        case .metadataReplace, .metadataCollisionReplace: context.setMetadata(["old": 9])
        case .metadataSet, .metadataCollisionSet: context.setMetadata("old", value: 9)
        case .metadataMerge, .metadataCollisionMerge: context.updateMetadata(["old": 9, "new": 11])
        case .metadataProperty: context.metadata = ["old": 9]
        case .metadataTyped: context[ContextKeys.metadata] = ["old": 9]
        case .metadataDynamic: context[dynamicMember: \.metadata] = ["old": 9]
        case .metricsReplace, .metricsCollisionReplace: context.setMetrics(["old": 9])
        case .metricSet, .metricsCollisionSet: context.setMetric("old", value: 9)
        case .metricStore, .metricsCollisionStore: context.storeMetric("old", value: 9)
        case .metricsMerge, .metricsCollisionMerge: context.updateMetrics(["old": 9, "new": 11])
        case .metricsProperty: context.metrics = ["old": 9]
        case .metricsTyped: context[ContextKeys.metrics] = ["old": 9]
        case .metricsDynamic: context[dynamicMember: \.metrics] = ["old": 9]
        case .duration:
            context.startTime = Date(timeIntervalSinceNow: -1)
            context.recordDuration("old")
        case .requestProperty: context.requestID = "new"
        case .userProperty: context.userID = "new"
        case .correlationProperty: context.correlationID = "new"
        case .startProperty: context.startTime = Date(timeIntervalSince1970: 42)
        case .dynamicTrace: context[dynamicMember: \.traceID] = "new"
        case .cancellation: context.markAsCancelled(reason: .userCancellation)
        }
    }

    func isCommitted(in context: CommandContext) -> Bool {
        switch self {
        case .typedNil, .remove: return !context.contains(ContextKey<Int>(key))
        case .typedReplace, .updateClosure: return context[ContextKey<Int>(key)] == 9
        case .requestProperty, .userProperty, .correlationProperty, .dynamicTrace:
            return context[ContextKey<String>(key)] == "new"
        case .startProperty: return context.startTime == Date(timeIntervalSince1970: 42)
        case .cancellation: return context.getCancellationReason() == .userCancellation
        case .duration: return (context.getMetric("old") as? TimeInterval ?? -1) >= 0 && context.getMetric("keep") as? Int == 7
        default:
            let values = key == "metadata" ? context.getMetadata() : context.getMetrics()
            let preserves = self == .metadataSet || self == .metadataMerge || self == .metricSet || self == .metricStore || self == .metricsMerge
            let merges = self == .metadataMerge || self == .metadataCollisionMerge || self == .metricsMerge || self == .metricsCollisionMerge
            return values["old"] as? Int == 9 &&
                (preserves ? values["keep"] as? Int == 7 : values["keep"] == nil) &&
                (merges ? values["new"] as? Int == 11 : values["new"] == nil)
        }
    }
}

private final class ContextPayload: Sendable {
    let onRelease: @Sendable () -> Void
    init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

private struct WeakContextPayload: Sendable { weak var value: ContextPayload? }

private final class RetirementObservations: Sendable {
    private struct State { var values: [Bool] = []; var returned = false }
    private let state = Mutex(State())
    func record(_ value: Bool) { state.withLock { $0.values.append(value) } }
    func returned() { state.withLock { $0.returned = true } }
    var states: [Bool] { state.withLock { $0.values } }
    var didReturn: Bool { state.withLock { $0.returned } }
}

private actor RetirementStartGate {
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
