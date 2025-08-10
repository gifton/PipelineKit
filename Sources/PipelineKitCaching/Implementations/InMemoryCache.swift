import Foundation
import PipelineKitCore

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

    private var storage: [String: CacheEntry] = [:]
    private let maxSize: Int
    private var accessOrder: [String] = [] // For LRU eviction

    /// Creates an in-memory cache with the specified maximum size.
    ///
    /// - Parameter maxSize: Maximum number of entries to store (default: 1000)
    public init(maxSize: Int = 1000) {
        self.maxSize = maxSize
    }

    public func get(key: String) -> Data? {
        guard let entry = storage[key] else { return nil }

        // Check expiration
        if entry.isExpired {
            storage.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
            return nil
        }

        // Update access order for LRU
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)

        return entry.data
    }

    public func set(key: String, value: Data, expiration: Date?) {
        // Remove existing entry from access order
        accessOrder.removeAll { $0 == key }

        // Check if we need to evict
        if storage.count >= maxSize && storage[key] == nil {
            // Evict least recently used
            if let lruKey = accessOrder.first {
                storage.removeValue(forKey: lruKey)
                accessOrder.removeFirst()
            }
        }

        // Store new entry
        storage[key] = CacheEntry(data: value, expiration: expiration)
        accessOrder.append(key)
    }

    public func remove(key: String) {
        storage.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }

    public func clear() {
        storage.removeAll()
        accessOrder.removeAll()
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
