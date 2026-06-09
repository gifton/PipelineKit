import XCTest
import Foundation
@testable import PipelineKitCache
@testable import PipelineKit
@testable import PipelineKitCore
import PipelineKitTestSupport

/// Tests covering the O(1) LRU evolution: the reusable `LRUStorage` map and its
/// adoption by `InMemoryCache` and `SimpleCachingMiddleware`.
///
/// These exercise recency/eviction ordering, update-in-place promotion, and
/// expiration, complementing the existing behavioral tests for the two cache
/// types.
final class LRUEvolutionTests: XCTestCase {
    // MARK: - InMemoryCache LRU ordering
    //
    // Values are round-tripped through the cache's typed Codable API
    // (`set(key:value:)` JSON-encodes, `get(key:type:)` JSON-decodes). Using the
    // raw `Data` API asymmetrically (encoding `set` + raw `get`) would compare a
    // base64-of-bytes blob against the plain string; the typed API is symmetric.

    /// With `maxSize == 3`, insert a, b, c; promote `a` via a read; insert d.
    /// `b` is now the least-recently-used entry and must be evicted; a, c, d
    /// remain.
    func testInMemoryCacheLRUEvictionOrder() async throws {
        let cache = InMemoryCache(maxSize: 3)

        await cache.set(key: "a", value: "A", expiration: nil)
        await cache.set(key: "b", value: "B", expiration: nil)
        await cache.set(key: "c", value: "C", expiration: nil)

        // Access `a` -> promotes it to most-recently-used. Order (LRU..MRU): b, c, a
        let aHit = await cache.get(key: "a", type: String.self)
        XCTAssertEqual(aHit, "A")

        // Insert `d` at capacity -> evicts LRU which is now `b`. Order: c, a, d
        await cache.set(key: "d", value: "D", expiration: nil)

        // `b` evicted.
        let bAfter = await cache.get(key: "b", type: String.self)
        XCTAssertNil(bAfter, "b should have been evicted as the least-recently-used entry")

        // a, c, d survive.
        let aAfter = await cache.get(key: "a", type: String.self)
        let cAfter = await cache.get(key: "c", type: String.self)
        let dAfter = await cache.get(key: "d", type: String.self)
        XCTAssertEqual(aAfter, "A")
        XCTAssertEqual(cAfter, "C")
        XCTAssertEqual(dAfter, "D")
    }

    /// Updating an existing key while at capacity promotes that key and must not
    /// evict anything; the entry count stays at `maxSize`.
    func testInMemoryCacheUpdateInPlacePromotesNoEvict() async throws {
        let cache = InMemoryCache(maxSize: 3)

        await cache.set(key: "a", value: "A", expiration: nil)
        await cache.set(key: "b", value: "B", expiration: nil)
        await cache.set(key: "c", value: "C", expiration: nil)

        // Update `a` in place (at capacity). This must NOT evict; it promotes `a`.
        // Order before update (LRU..MRU): a, b, c. After: b, c, a.
        await cache.set(key: "a", value: "A2", expiration: nil)

        // All three keys still present, `a` carries the new value. Reading them in
        // the order a, b, c re-promotes each, leaving the order (LRU..MRU): a, b, c.
        let aVal = await cache.get(key: "a", type: String.self) // order -> b, c, a
        let bVal = await cache.get(key: "b", type: String.self) // order -> c, a, b
        let cVal = await cache.get(key: "c", type: String.self) // order -> a, b, c
        XCTAssertEqual(aVal, "A2", "in-place update should replace the value")
        XCTAssertNotNil(bVal, "updating an existing key must not evict another entry")
        XCTAssertNotNil(cVal, "updating an existing key must not evict another entry")

        // Insert a genuinely new key `d` at capacity. The LRU is now `a`
        // (order a, b, c), so `a` is evicted.
        await cache.set(key: "d", value: "D", expiration: nil)
        let aGone = await cache.get(key: "a", type: String.self)
        XCTAssertNil(aGone, "the least-recently-used key should be evicted on new insert")
    }

    /// An expired entry must return `nil` from `get` and be removed from the
    /// cache (not merely reported as expired).
    func testInMemoryCacheExpiredReturnsNilAndRemoved() async throws {
        let cache = InMemoryCache(maxSize: 10)

        // Expire 50ms in the future, then sleep past it.
        let expiration = Date().addingTimeInterval(0.05)
        await cache.set(key: "k", value: "V", expiration: expiration)

        // Immediately available.
        let live = await cache.get(key: "k", type: String.self)
        XCTAssertEqual(live, "V")

        try await Task.sleep(nanoseconds: 120_000_000) // 120ms

        // Expired -> nil and removed.
        let expired = await cache.get(key: "k", type: String.self)
        XCTAssertNil(expired, "expired entry should return nil from get")

        // A subsequent get is still nil (entry was removed, not lingering).
        let afterRemoval = await cache.get(key: "k", type: String.self)
        XCTAssertNil(afterRemoval, "expired entry should have been removed on the prior get")

        // The slot is free: we can re-insert and read it back.
        await cache.set(key: "k", value: "V2", expiration: nil)
        let reinserted = await cache.get(key: "k", type: String.self)
        XCTAssertEqual(reinserted, "V2")
    }

    /// `clear()` empties the cache; `remove(key:)` drops a single entry.
    func testInMemoryCacheRemoveAndClear() async throws {
        let cache = InMemoryCache(maxSize: 10)
        await cache.set(key: "a", value: "A", expiration: nil)
        await cache.set(key: "b", value: "B", expiration: nil)

        await cache.remove(key: "a")
        let aGone = await cache.get(key: "a", type: String.self)
        let bStill = await cache.get(key: "b", type: String.self)
        XCTAssertNil(aGone)
        XCTAssertNotNil(bStill)

        await cache.clear()
        let bAfterClear = await cache.get(key: "b", type: String.self)
        XCTAssertNil(bAfterClear)
    }

    // MARK: - LRUStorage direct unit tests

    /// Direct unit test of the generic `LRUStorage`: value/setValue/removeValue,
    /// promotion, eviction, and LRU-ordering inspection. Synchronous on purpose:
    /// `LRUStorage` is non-Sendable and must not cross isolation boundaries.
    func testLRUStorageBasics() {
        let storage = LRUStorage<Int>(maxSize: 3)
        XCTAssertEqual(storage.count, 0)
        XCTAssertNil(storage.value(forKey: "missing"))
        XCTAssertFalse(storage.contains("missing"))

        // Insert a, b, c.
        XCTAssertNil(storage.setValue(1, forKey: "a"))
        XCTAssertNil(storage.setValue(2, forKey: "b"))
        XCTAssertNil(storage.setValue(3, forKey: "c"))
        XCTAssertEqual(storage.count, 3)
        XCTAssertEqual(storage.keysInLRUOrder(), ["a", "b", "c"]) // LRU..MRU

        // peek does not promote.
        XCTAssertEqual(storage.peek(forKey: "a"), 1)
        XCTAssertEqual(storage.keysInLRUOrder(), ["a", "b", "c"])

        // value(forKey:) promotes `a` to MRU.
        XCTAssertEqual(storage.value(forKey: "a"), 1)
        XCTAssertEqual(storage.keysInLRUOrder(), ["b", "c", "a"])

        // Insert `d` at capacity -> evicts LRU `b`, returns "b".
        let evicted = storage.setValue(4, forKey: "d")
        XCTAssertEqual(evicted, "b")
        XCTAssertEqual(storage.count, 3)
        XCTAssertFalse(storage.contains("b"))
        XCTAssertEqual(storage.keysInLRUOrder(), ["c", "a", "d"])

        // Update existing `c` -> no eviction, promotes `c`.
        let noEvict = storage.setValue(30, forKey: "c")
        XCTAssertNil(noEvict)
        XCTAssertEqual(storage.value(forKey: "c"), 30)
        XCTAssertEqual(storage.keysInLRUOrder(), ["a", "d", "c"])
        XCTAssertEqual(storage.count, 3)

        // removeValue drops a key and repairs ordering.
        storage.removeValue(forKey: "d")
        XCTAssertFalse(storage.contains("d"))
        XCTAssertEqual(storage.keysInLRUOrder(), ["a", "c"])
        XCTAssertEqual(storage.count, 2)

        // Removing a missing key is a no-op.
        storage.removeValue(forKey: "nope")
        XCTAssertEqual(storage.count, 2)

        // values returns all stored values (order unspecified) -> compare as sets.
        XCTAssertEqual(Set(storage.values), Set([1, 30]))

        // removeAll empties it.
        storage.removeAll()
        XCTAssertEqual(storage.count, 0)
        XCTAssertTrue(storage.keysInLRUOrder().isEmpty)
        XCTAssertNil(storage.value(forKey: "a"))
    }

    /// Re-touching the most-recently-used key (already the tail) keeps ordering
    /// intact and remains a no-op promotion. Also covers removing the head and
    /// the tail explicitly.
    func testLRUStorageEdgeRecency() {
        let storage = LRUStorage<String>(maxSize: 4)
        storage.setValue("A", forKey: "a")
        storage.setValue("B", forKey: "b")
        storage.setValue("C", forKey: "c")

        // Touch the current tail (c) -> still tail, order unchanged.
        XCTAssertEqual(storage.value(forKey: "c"), "C")
        XCTAssertEqual(storage.keysInLRUOrder(), ["a", "b", "c"])

        // Remove the head (a).
        storage.removeValue(forKey: "a")
        XCTAssertEqual(storage.keysInLRUOrder(), ["b", "c"])

        // Remove the tail (c).
        storage.removeValue(forKey: "c")
        XCTAssertEqual(storage.keysInLRUOrder(), ["b"])

        // Single element: promotion is a no-op.
        XCTAssertEqual(storage.value(forKey: "b"), "B")
        XCTAssertEqual(storage.keysInLRUOrder(), ["b"])

        // Removing the last element empties the list cleanly (head/tail nil path).
        storage.removeValue(forKey: "b")
        XCTAssertEqual(storage.count, 0)
        XCTAssertTrue(storage.keysInLRUOrder().isEmpty)
    }

    /// A store with `maxSize == 1` keeps only the most recent key.
    func testLRUStorageCapacityOne() {
        let storage = LRUStorage<Int>(maxSize: 1)
        XCTAssertNil(storage.setValue(1, forKey: "a"))
        XCTAssertEqual(storage.keysInLRUOrder(), ["a"])

        let evicted = storage.setValue(2, forKey: "b")
        XCTAssertEqual(evicted, "a")
        XCTAssertEqual(storage.count, 1)
        XCTAssertEqual(storage.keysInLRUOrder(), ["b"])
        XCTAssertNil(storage.value(forKey: "a"))
        XCTAssertEqual(storage.value(forKey: "b"), 2)
    }

    // MARK: - SimpleCachingMiddleware LRU via stats

    /// Mirrors the existing `SimpleCachingMiddlewareTests.testLRUEviction` style:
    /// fill to capacity, promote one entry, insert a third, and confirm the count
    /// stays at the size limit while the re-execution of the evicted key proves
    /// which entry was dropped.
    func testSimpleCachingMiddlewareLRUEvictionAndPromotion() async throws {
        let executionCounts = TestActor<[String: Int]>([:])

        let cache = SimpleCachingMiddleware(
            ttl: 60,
            maxSize: 2,
            keyGenerator: { command in
                if let cmd = command as? KeyedCommand {
                    return "k-\(cmd.key)"
                }
                return String(describing: type(of: command))
            }
        )

        let pipeline = StandardPipeline(handler: KeyedHandler(counts: executionCounts))
        try await pipeline.addMiddleware(cache)
        let context = CommandContext()

        // Fill: a, b (order LRU..MRU: a, b).
        _ = try await pipeline.execute(KeyedCommand(key: "a"), context: context)
        _ = try await pipeline.execute(KeyedCommand(key: "b"), context: context)
        XCTAssertEqual(cache.getStats().totalEntries, 2)

        // Promote `a` via a cache hit -> order: b, a.
        _ = try await pipeline.execute(KeyedCommand(key: "a"), context: context)

        // Insert `c` at capacity -> evicts LRU `b`. Order: a, c.
        _ = try await pipeline.execute(KeyedCommand(key: "c"), context: context)
        XCTAssertEqual(cache.getStats().totalEntries, 2)

        // `a` should still be cached (hit -> no new execution).
        _ = try await pipeline.execute(KeyedCommand(key: "a"), context: context)
        // `b` should have been evicted (miss -> re-execution).
        _ = try await pipeline.execute(KeyedCommand(key: "b"), context: context)

        let counts = await executionCounts.get()
        XCTAssertEqual(counts["a"], 1, "a stayed cached after promotion")
        XCTAssertEqual(counts["b"], 2, "b was evicted and re-executed")
        XCTAssertEqual(counts["c"], 1, "c was cached on insert")
    }

    // MARK: - Test fixtures

    private struct KeyedCommand: Command {
        typealias Result = String
        let key: String
    }

    private final class KeyedHandler: CommandHandler {
        typealias CommandType = KeyedCommand
        let counts: TestActor<[String: Int]>

        init(counts: TestActor<[String: Int]>) {
            self.counts = counts
        }

        func handle(_ command: KeyedCommand, context: CommandContext) async throws -> String {
            await counts.incrementCount(for: command.key)
            return "result-\(command.key)"
        }
    }
}
