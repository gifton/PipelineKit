import Foundation
import PipelineKit
import PipelineKitObservability

/// A simple, synchronous in-memory caching middleware.
///
/// Unlike `CachingMiddleware` which uses the async `Cache` protocol and requires JSON encoding,
/// `SimpleCachingMiddleware` uses direct memory storage with `NSLock` for thread safety.
/// This provides better performance and eliminates the need for `Codable` conformance.
///
/// ## Design Decisions
///
/// **Synchronous Operations**: Uses `NSLock` instead of actor isolation for minimal overhead.
/// Cache operations are synchronous, reducing latency compared to async alternatives.
///
/// **Direct Storage**: Stores command results directly in memory without serialization.
/// This eliminates encoding/decoding overhead and supports any result type.
///
/// **LRU Eviction**: When `maxSize` is set, uses least-recently-used eviction policy.
/// Access order is tracked to ensure frequently accessed items remain cached.
///
/// **Thread Safety**: `@unchecked Sendable` is safe because:
/// - All mutable state protected by `NSLock`
/// - Closures are `@Sendable`
/// - Primitives are `Sendable`
///
/// Supply an explicit `CacheKeyGenerator` including every result-varying
/// argument, verified principal/tenant, and relevant configuration. Key generation
/// is awaited before entering the synchronous storage lock. The cache adds fully
/// qualified command, result, and middleware types to the caller's key.
///
/// ## Storage Performance Characteristics
/// These costs exclude caller key generation and namespace construction.
/// - **Cache Hit**: O(1) dictionary lookup + O(1) LRU promotion
/// - **Cache Miss**: O(1) insertion + O(1) eviction (if needed)
/// - **Memory**: O(k) where k = number of cached entries
///
/// LRU recency is tracked by an O(1) doubly-linked-list + dictionary store
/// (`LRUStorage`), so neither hits nor evictions scan the cache.
///
/// ## Observability
/// Emits cache events for monitoring:
/// - `cache.hit` - Result found in cache
/// - `cache.miss` - Result not in cache, executing command
public final class SimpleCachingMiddleware: Middleware, NextGuardWarningSuppressing, @unchecked Sendable {
    // MARK: - Types

    private struct CacheEntry {
        let value: Any
        let timestamp: Date
        let ttl: TimeInterval

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > ttl
        }
    }

    // MARK: - Properties

    public let priority: ExecutionPriority
    private let ttl: TimeInterval
    private let maxSize: Int?
    private let keyGenerator: any CacheKeyGenerator
    private let shouldCache: @Sendable (Any) -> Bool

    /// O(1) LRU-ordered backing store (doubly-linked list + dictionary).
    ///
    /// Replaces the former `cache` dictionary plus `accessOrder` array, whose
    /// per-access `removeAll { $0 == key }` scan was O(n). The store is **not**
    /// thread-safe on its own; every access below is performed while holding
    /// `lock`, preserving this type's existing `NSLock`-based synchronization
    /// model unchanged.
    ///
    /// A `nil` `maxSize` (unlimited) maps to `Int.max`, so eviction never fires.
    private let storage: LRUStorage<CacheEntry>
    private let lock = NSLock()

    // MARK: - Initialization

    /// Creates a simple caching middleware with the specified configuration.
    ///
    /// - Parameters:
    ///   - ttl: Time-to-live in seconds for cached entries
    ///   - maxSize: Maximum number of entries to cache (nil = unlimited)
    ///   - priority: Execution priority (default: `.preProcessing`)
    ///   - keyGenerator: Complete caller identity; see `CacheKeyGenerator`
    ///   - shouldCache: Predicate to determine if a command should be cached (default: cache all)
    public init(
        ttl: TimeInterval,
        maxSize: Int? = nil,
        priority: ExecutionPriority = .preProcessing,
        keyGenerator: any CacheKeyGenerator,
        shouldCache: @escaping @Sendable (Any) -> Bool = { _ in true }
    ) {
        self.ttl = ttl
        self.maxSize = maxSize
        self.priority = priority
        self.keyGenerator = keyGenerator
        self.shouldCache = shouldCache
        // `nil` means unlimited; map it to `Int.max` so `LRUStorage` never evicts.
        self.storage = LRUStorage<CacheEntry>(maxSize: maxSize ?? Int.max)
    }

    // MARK: - Middleware

    public func execute<C: Command>(
        _ command: C,
        context: CommandContext,
        next: @escaping MiddlewareNext<C>
    ) async throws -> C.Result {
        // Check if this command should be cached
        guard shouldCache(command) else {
            return try await next(command, context)
        }

        let key = await CacheKeyNamespace.generate(
            for: command, context: context, middleware: String(reflecting: Self.self), using: keyGenerator
        )

        // Check cache (synchronous operation)
        if let cachedResult = getCachedResult(for: key, as: C.Result.self) {
            await context.emitEvent("cache.hit", properties: [
                "key": key,
                "commandType": String(describing: C.self)
            ])
            return cachedResult
        }

        // Cache miss - execute command
        await context.emitEvent("cache.miss", properties: [
            "key": key,
            "commandType": String(describing: C.self)
        ])

        let result = try await next(command, context)

        // Store in cache (synchronous operation)
        setCachedResult(result, for: key)

        return result
    }

    // MARK: - Cache Management

    private func getCachedResult<T>(for key: String, as type: T.Type) -> T? {
        lock.lock()
        defer { lock.unlock() }

        // Inspect without promoting first so an expired entry is not counted as a
        // use before removal.
        guard let entry = storage.peek(forKey: key) else {
            return nil
        }

        // Check if expired
        if entry.isExpired {
            storage.removeValue(forKey: key)
            return nil
        }

        // Live entry: promote to most-recently-used (O(1)).
        _ = storage.value(forKey: key)

        return entry.value as? T
    }

    private func setCachedResult<T>(_ result: T, for key: String) {
        lock.lock()
        defer { lock.unlock() }

        // Insert/update + promote. When a new key pushes the store past its
        // capacity, `LRUStorage` evicts the least-recently-used entry; updating an
        // existing key never evicts. This preserves the prior
        // `cache.count >= maxSize && cache[key] == nil` eviction rule. An unlimited
        // (`nil`) `maxSize` was mapped to `Int.max`, so eviction never fires.
        storage.setValue(CacheEntry(value: result, timestamp: Date(), ttl: ttl), forKey: key)
    }

    /// Clears all cached entries.
    ///
    /// This operation is thread-safe and removes all entries from the cache,
    /// including expired ones.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    /// Removes expired entries from the cache.
    ///
    /// Call this periodically to free memory from expired entries that haven't
    /// been accessed (and thus auto-removed).
    public func removeExpired() {
        lock.lock()
        defer { lock.unlock() }

        // Snapshot keys, then drop those whose entry is expired. `peek` is used so
        // the inspection does not alter recency. Removal of each key is O(1).
        let expiredKeys = storage.keysInLRUOrder().filter { key in
            storage.peek(forKey: key)?.isExpired ?? false
        }

        for key in expiredKeys {
            storage.removeValue(forKey: key)
        }
    }

    /// Gets current cache statistics.
    ///
    /// Returns real-time statistics about cache state including total entries,
    /// expired entries, and active entries.
    public func getStats() -> CacheStats {
        lock.lock()
        defer { lock.unlock() }

        let total = storage.count
        let expired = storage.values.filter { $0.isExpired }.count

        return CacheStats(
            totalEntries: total,
            expiredEntries: expired,
            activeEntries: total - expired
        )
    }
}

// MARK: - Supporting Types

/// Statistics about the current state of the cache.
public struct CacheStats: Sendable, Equatable {
    /// Total number of entries in the cache (including expired)
    public let totalEntries: Int

    /// Number of expired entries still in cache
    public let expiredEntries: Int

    /// Number of active (non-expired) entries
    public let activeEntries: Int

    public init(totalEntries: Int, expiredEntries: Int, activeEntries: Int) {
        self.totalEntries = totalEntries
        self.expiredEntries = expiredEntries
        self.activeEntries = activeEntries
    }
}

// MARK: - Convenience Initializers

public extension SimpleCachingMiddleware {
    /// Caches only the selected command type using an explicit complete identity.
    /// Other types bypass both key generation and storage.
    convenience init<C: Command>(
        ttl: TimeInterval,
        maxSize: Int? = nil,
        commandType: C.Type,
        keyGenerator: any CacheKeyGenerator
    ) {
        self.init(
            ttl: ttl,
            maxSize: maxSize,
            keyGenerator: keyGenerator,
            shouldCache: { command in command is C }
        )
    }
}
