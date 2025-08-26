import Foundation

/// Protocol for cache backends used throughout PipelineKit.
///
/// This protocol defines a common interface for cache implementations,
/// supporting both typed and data-based storage patterns.
///
/// ## Design Decisions
///
/// 1. **Dual Interface**: Supports both typed access (for test mocks) and 
///    data-based access (for production middleware) to accommodate different use cases.
///
/// 2. **Async/Await**: All operations are async to support both in-memory
///    and potentially remote cache backends.
///
/// 3. **Sendable**: Required for thread-safe usage across actor boundaries.
///
/// ## Example Implementation
/// ```swift
/// actor MyCache: Cache {
///     private var storage: [String: Data] = [:]
///     
///     func get(key: String) async -> Data? {
///         storage[key]
///     }
///     
///     func get<T: Sendable>(key: String, type: T.Type) async -> T? {
///         // Implementation for typed access
///     }
///     
///     // ... other methods
/// }
/// ```
public protocol Cache: Sendable {
    // MARK: - Data-based Interface (Primary)

    /// Gets raw data from the cache.
    func get(key: String) async -> Data?

    /// Sets raw data in the cache with optional expiration.
    func set(key: String, value: Data, expiration: Date?) async

    // MARK: - Typed Interface (Convenience)

    /// Gets a typed value from the cache.
    /// 
    /// Default implementation uses data-based interface with JSON encoding.
    func get<T: Sendable & Decodable>(key: String, type: T.Type) async -> T?

    /// Sets a typed value in the cache.
    ///
    /// Default implementation uses data-based interface with JSON encoding.
    func set<T: Sendable & Encodable>(key: String, value: T, expiration: Date?) async

    // MARK: - Management Operations

    /// Removes a value from the cache.
    func remove(key: String) async

    /// Clears all values from the cache.
    func clear() async
}

// MARK: - Default Implementations

public extension Cache {
    /// Default implementation of typed get using JSON decoding.
    func get<T: Sendable & Decodable>(key: String, type: T.Type) async -> T? {
        guard let data = await get(key: key) else { return nil }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Default implementation of typed set using JSON encoding.
    func set<T: Sendable & Encodable>(key: String, value: T, expiration: Date? = nil) async {
        guard let data = try? JSONEncoder().encode(value) else { return }

        await set(key: key, value: data, expiration: expiration)
    }
}
