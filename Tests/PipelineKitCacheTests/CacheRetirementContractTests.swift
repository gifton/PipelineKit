import Foundation
import Synchronization
import XCTest
import PipelineKit
import PipelineKitCache

// All routes use only public cache APIs and checked Sendable payloads.
// The watchdog bounds a regression that deadlocks during synchronous destruction.
final class CacheRetirementContractTests: XCTestCase {
    func testPublicDiscardRetirementMatrix() async throws {
        for path in DiscardPath.allCases {
            try await exercise(path)
        }
    }

    func testConcurrentMissReplacementRetiresAfterCommittedInsertion() async throws {
        let cache = makeCache()
        let events = CacheRetirementEvents()
        let gate = MissGate()
        let first = Task {
            try await fill(cache, key: "same", value: "first", events: events, gate: gate)
        }
        let second = Task {
            try await fill(cache, key: "same", value: "second", events: events, gate: gate)
        }
        await gate.waitForBothMisses()
        XCTAssertEqual(cache.getStats(), CacheStats(totalEntries: 0, expiredEntries: 0, activeEntries: 0))
        await gate.release("first")
        let firstOutcome = await first.result
        XCTAssertTrue(events.values.isEmpty)
        await gate.release("second")
        let secondOutcome = await second.result
        // Join both fills before unwrapping either error outcome.
        let firstWitness = try firstOutcome.get()
        let secondWitness = try secondOutcome.get()
        events.returned()
        XCTAssertNil(firstWitness.value)
        XCTAssertNotNil(secondWitness.value)
        XCTAssertEqual(events.values, [CacheRelease(value: "first", stats: CacheStats(totalEntries: 1, expiredEntries: 0, activeEntries: 1))])
        XCTAssertTrue(events.didReturn)
        try await assertHit(cache, key: "same", witness: secondWitness)
        cache.clear()
        XCTAssertNil(secondWitness.value)
        XCTAssertEqual(events.values.last, CacheRelease(value: "second", stats: CacheStats(totalEntries: 0, expiredEntries: 0, activeEntries: 0)))
    }

    private func exercise(_ path: DiscardPath) async throws {
        let cache = makeCache(ttl: path.expires ? -1 : 60)
        let events = CacheRetirementEvents()
        let first = try await fill(cache, key: "a", value: "a", events: events)
        let second = try await fill(cache, key: "b", value: "b", events: events)
        XCTAssertNotNil(first.value)
        XCTAssertNotNil(second.value)
        XCTAssertTrue(events.values.isEmpty)
        var replacement: WeakCachePayload?
        switch path {
        case .clear: cache.clear()
        case .sweep: cache.removeExpired()
        case .lookupExpiration:
            replacement = try await fill(cache, key: "a", value: "new-a", events: events)
        case .promoteThenEvict:
            try await assertHit(cache, key: "a", witness: first)
            replacement = try await fill(cache, key: "c", value: "c", events: events)
        }
        events.returned()
        switch path {
        case .clear, .sweep:
            XCTAssertNil(first.value, "\(path)")
            XCTAssertNil(second.value, "\(path)")
            XCTAssertEqual(Set(events.values.map(\.value)), ["a", "b"], "\(path)")
            XCTAssertEqual(events.values.count, 2, "\(path)")
            for event in events.values {
                XCTAssertEqual(event.stats, CacheStats(totalEntries: 0, expiredEntries: 0, activeEntries: 0), "\(path)")
            }
        case .lookupExpiration:
            XCTAssertNil(first.value)
            XCTAssertNotNil(second.value)
            XCTAssertNotNil(replacement?.value)
            XCTAssertEqual(events.values, [CacheRelease(value: "a", stats: CacheStats(totalEntries: 1, expiredEntries: 1, activeEntries: 0))])
        case .promoteThenEvict:
            XCTAssertNotNil(first.value)
            XCTAssertNil(second.value)
            XCTAssertNotNil(replacement?.value)
            XCTAssertEqual(events.values, [CacheRelease(value: "b", stats: CacheStats(totalEntries: 2, expiredEntries: 0, activeEntries: 2))])
            try await assertHit(cache, key: "a", witness: first)
            try await assertHit(cache, key: "c", witness: replacement!)
        }
        XCTAssertTrue(events.didReturn, "\(path)")
        let expectedRemaining = path == .clear || path == .sweep ? 0 : 2
        XCTAssertEqual(cache.getStats().totalEntries, expectedRemaining, "\(path)")
        cache.clear()
        XCTAssertNil(first.value)
        XCTAssertNil(second.value)
        XCTAssertNil(replacement?.value)
        XCTAssertEqual(events.values.count, replacement == nil ? 2 : 3, "\(path)")
    }
}

private enum DiscardPath: CaseIterable {
    case clear, lookupExpiration, sweep, promoteThenEvict
    var expires: Bool { self == .lookupExpiration || self == .sweep }
}

private struct RetirementCommand: Command {
    typealias Result = CachePayload
    let key: String
}

private final class CachePayload: Sendable {
    let value: String
    let onRelease: @Sendable () -> Void
    init(value: String, onRelease: @escaping @Sendable () -> Void) {
        self.value = value
        self.onRelease = onRelease
    }
    deinit { onRelease() }
}

private struct WeakCachePayload: Sendable { weak var value: CachePayload? }
private struct CacheRelease: Sendable, Equatable { let value: String; let stats: CacheStats? }

private final class CacheRetirementEvents: Sendable {
    private struct State { var values: [CacheRelease] = []; var returned = false }
    private let state = Mutex(State())
    func record(_ value: CacheRelease) { state.withLock { $0.values.append(value) } }
    func returned() { state.withLock { $0.returned = true } }
    var values: [CacheRelease] { state.withLock { $0.values } }
    var didReturn: Bool { state.withLock { $0.returned } }
}

private func makeCache(ttl: TimeInterval = 60) -> SimpleCachingMiddleware {
    SimpleCachingMiddleware(ttl: ttl, maxSize: 2, keyGenerator: ClosureCacheKeyGenerator { command, _, _ in
        (command as! RetirementCommand).key
    })
}

private func makePayload(value: String, cache: SimpleCachingMiddleware, events: CacheRetirementEvents) -> CachePayload {
    CachePayload(value: value) { [weak cache] in
        events.record(CacheRelease(value: value, stats: cache?.getStats()))
    }
}

private func fill(
    _ cache: SimpleCachingMiddleware, key: String, value: String,
    events: CacheRetirementEvents, gate: MissGate? = nil
) async throws -> WeakCachePayload {
    let result = try await cache.execute(RetirementCommand(key: key), context: CommandContext()) { _, _ in
        if let gate { await gate.arrive(value) }
        return makePayload(value: value, cache: cache, events: events)
    }
    XCTAssertEqual(result.value, value)
    return WeakCachePayload(value: result)
}

private func assertHit(_ cache: SimpleCachingMiddleware, key: String, witness: WeakCachePayload) async throws {
    let result = try await cache.execute(RetirementCommand(key: key), context: CommandContext()) { _, _ in
        XCTFail("Expected cached identity for \(key)")
        return CachePayload(value: "unexpected", onRelease: {})
    }
    XCTAssertTrue(result === witness.value)
}

private actor MissGate {
    var arrivals: [String: CheckedContinuation<Void, Never>] = [:]
    var both: CheckedContinuation<Void, Never>?
    func arrive(_ value: String) async {
        await withCheckedContinuation { continuation in
            arrivals[value] = continuation
            if arrivals.count == 2 { both?.resume(); both = nil }
        }
    }
    func waitForBothMisses() async {
        if arrivals.count == 2 { return }
        await withCheckedContinuation { both = $0 }
    }
    func release(_ value: String) { arrivals.removeValue(forKey: value)!.resume() }
}
