import Foundation
import PipelineKit

/// Thread-safe in-memory cache implementation with LRU eviction.
///
/// This implementation provides:
/// - Configurable maximum size with LRU eviction
/// - Optional expiration for entries
/// - Both typed and data-based access
/// - Thread-safe operations via actor isolation
///
/// ## Example Usage
/// ```swift
/// let cache = InMemoryCache(maxSize: 1000)
/// await cache.set(key: "user:123", value: userData, expiration: nil)
/// let cached = await cache.get(key: "user:123")
/// ```
public actor InMemoryCache: Cache {
    private struct CacheEntry {
        let data: Data
        let expiration: Date?

        var isExpired: Bool {
            guard let expiration = expiration else { return false }
            return Date() > expiration
        }
    }

    /// O(1) LRU-ordered backing store (doubly-linked list + dictionary).
    ///
    /// Replaces the former `storage` dictionary plus `accessOrder` array, whose
    /// per-access `removeAll { $0 == key }` scan was O(n). The store handles
    /// recency promotion and least-recently-used eviction internally in O(1).
    private let storage: LRUStorage<CacheEntry>

    /// Creates an in-memory cache with the specified maximum size.
    ///
    /// - Parameter maxSize: Maximum number of entries to store (default: 1000)
    public init(maxSize: Int = 1000) {
        self.storage = LRUStorage<CacheEntry>(maxSize: maxSize)
    }

    public func get(key: String) -> Data? {
        // Inspect without promoting first so an expired entry is not counted as a
        // use before removal.
        guard let entry = storage.peek(forKey: key) else { return nil }

        // Check expiration
        if entry.isExpired {
            storage.removeValue(forKey: key)
            return nil
        }

        // Live entry: promote to most-recently-used (O(1)) and return its data.
        _ = storage.value(forKey: key)
        return entry.data
    }

    public func set(key: String, value: Data, expiration: Date?) {
        // Insert/update + promote, evicting the least-recently-used entry if a new
        // key pushes the store past `maxSize`. Updating an existing key never
        // evicts; both behaviors are handled by `setValue`, matching the prior
        // `storage.count >= maxSize && storage[key] == nil` eviction rule.
        storage.setValue(CacheEntry(data: value, expiration: expiration), forKey: key)
    }

    public func remove(key: String) {
        storage.removeValue(forKey: key)
    }

    public func clear() {
        storage.removeAll()
    }
}

/// Simplified in-memory cache without size limits or expiration.
///
/// Useful for testing or when cache management isn't critical.
public actor SimpleCache: Cache {
    private var storage: [String: Data] = [:]

    public init() {}

    public func get(key: String) -> Data? {
        storage[key]
    }

    public func set(key: String, value: Data, expiration: Date?) {
        // Ignores expiration for simplicity
        storage[key] = value
    }

    public func remove(key: String) {
        storage.removeValue(forKey: key)
    }

    public func clear() {
        storage.removeAll()
    }
}

/// No-operation cache that doesn't store anything.
///
/// Useful as a default when caching is not needed or for testing.
public struct NoOpCache: Cache, Sendable {
    public init() {}

    public func get(key: String) async -> Data? {
        nil
    }

    public func set(key: String, value: Data, expiration: Date?) async {
        // No-op
    }

    public func remove(key: String) async {
        // No-op
    }

    public func clear() async {
        // No-op
    }
}
