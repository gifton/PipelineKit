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
/// ## Example Usage
/// ```swift
/// // Basic usage with 5-minute TTL
/// let cache = SimpleCachingMiddleware(ttl: 300)
/// try await pipeline.addMiddleware(cache)
///
/// // With size limit and custom key generation
/// let cache = SimpleCachingMiddleware(
///     ttl: 600,
///     maxSize: 1000,
///     keyGenerator: { command in
///         if let hashable = command as? any Hashable {
///             return "\(type(of: command))-\(hashable.hashValue)"
///         }
///         return String(describing: type(of: command))
///     }
/// )
///
/// // Cache specific command types only
/// let cache = SimpleCachingMiddleware(
///     ttl: 300,
///     commandType: GetUserCommand.self
/// )
/// ```
///
/// ## Performance Characteristics
/// - **Cache Hit**: O(1) dictionary lookup + O(n) LRU update (n = cache size)
/// - **Cache Miss**: O(1) insertion + O(1) eviction (if needed)
/// - **Memory**: O(k) where k = number of cached entries
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
    private let keyGenerator: @Sendable (Any) -> String
    private let shouldCache: @Sendable (Any) -> Bool

    private var cache: [String: CacheEntry] = [:]
    private var accessOrder: [String] = [] // For LRU eviction
    private let lock = NSLock()

    // MARK: - Initialization

    /// Creates a simple caching middleware with the specified configuration.
    ///
    /// - Parameters:
    ///   - ttl: Time-to-live in seconds for cached entries
    ///   - maxSize: Maximum number of entries to cache (nil = unlimited)
    ///   - priority: Execution priority (default: `.preProcessing`)
    ///   - keyGenerator: Function to generate cache keys from commands (default: uses type name)
    ///   - shouldCache: Predicate to determine if a command should be cached (default: cache all)
    public init(
        ttl: TimeInterval,
        maxSize: Int? = nil,
        priority: ExecutionPriority = .preProcessing,
        keyGenerator: @escaping @Sendable (Any) -> String = { command in
            String(describing: type(of: command))
        },
        shouldCache: @escaping @Sendable (Any) -> Bool = { _ in true }
    ) {
        self.ttl = ttl
        self.maxSize = maxSize
        self.priority = priority
        self.keyGenerator = keyGenerator
        self.shouldCache = shouldCache
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

        let key = keyGenerator(command)

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

        guard let entry = cache[key] else {
            return nil
        }

        // Check if expired
        if entry.isExpired {
            cache.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
            return nil
        }

        // Update LRU order
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)

        return entry.value as? T
    }

    private func setCachedResult<T>(_ result: T, for key: String) {
        lock.lock()
        defer { lock.unlock() }

        // Remove from access order if exists
        accessOrder.removeAll { $0 == key }

        // Check size limit and evict if needed
        if let maxSize = maxSize, cache.count >= maxSize && cache[key] == nil {
            // Evict least recently used entry
            if let lruKey = accessOrder.first {
                cache.removeValue(forKey: lruKey)
                accessOrder.removeFirst()
            }
        }

        // Store new entry
        cache[key] = CacheEntry(value: result, timestamp: Date(), ttl: ttl)
        accessOrder.append(key)
    }

    /// Clears all cached entries.
    ///
    /// This operation is thread-safe and removes all entries from the cache,
    /// including expired ones.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// Removes expired entries from the cache.
    ///
    /// Call this periodically to free memory from expired entries that haven't
    /// been accessed (and thus auto-removed).
    public func removeExpired() {
        lock.lock()
        defer { lock.unlock() }

        let expiredKeys = cache.compactMap { key, entry in
            entry.isExpired ? key : nil
        }

        for key in expiredKeys {
            cache.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
    }

    /// Gets current cache statistics.
    ///
    /// Returns real-time statistics about cache state including total entries,
    /// expired entries, and active entries.
    public func getStats() -> CacheStats {
        lock.lock()
        defer { lock.unlock() }

        let expired = cache.values.filter { $0.isExpired }.count

        return CacheStats(
            totalEntries: cache.count,
            expiredEntries: expired,
            activeEntries: cache.count - expired
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
    /// Creates a simple caching middleware with command-type-based key generation.
    ///
    /// This uses the command's type name as the cache key, which works well for
    /// commands where all instances should share the same cached result.
    ///
    /// - Parameters:
    ///   - ttl: Time-to-live in seconds for cached entries
    ///   - maxSize: Maximum number of entries to cache (nil = unlimited)
    convenience init(ttl: TimeInterval, maxSize: Int? = nil) {
        self.init(
            ttl: ttl,
            maxSize: maxSize,
            keyGenerator: { command in
                String(describing: type(of: command))
            }
        )
    }

    /// Creates a simple caching middleware that only caches specific command types.
    ///
    /// Other command types will bypass the cache entirely.
    ///
    /// - Parameters:
    ///   - ttl: Time-to-live in seconds for cached entries
    ///   - maxSize: Maximum number of entries to cache (nil = unlimited)
    ///   - commandType: The specific command type to cache
    convenience init<C: Command>(
        ttl: TimeInterval,
        maxSize: Int? = nil,
        commandType: C.Type
    ) {
        self.init(
            ttl: ttl,
            maxSize: maxSize,
            shouldCache: { command in command is C }
        )
    }

    /// Creates a simple caching middleware with hashable-based key generation.
    ///
    /// For commands that conform to Hashable, this generates unique cache keys
    /// based on the command's hash value, allowing different command instances
    /// to have different cached results.
    ///
    /// - Parameters:
    ///   - ttl: Time-to-live in seconds for cached entries
    ///   - maxSize: Maximum number of entries to cache (nil = unlimited)
    ///   - useHashableKeys: If true, uses hash values for key generation
    convenience init(ttl: TimeInterval, maxSize: Int? = nil, useHashableKeys: Bool) {
        self.init(
            ttl: ttl,
            maxSize: maxSize,
            keyGenerator: { command in
                if useHashableKeys, let hashable = command as? any Hashable {
                    return "\(type(of: command))-\(hashable.hashValue)"
                }
                return String(describing: type(of: command))
            }
        )
    }
}
