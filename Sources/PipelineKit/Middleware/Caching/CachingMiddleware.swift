import Foundation

/// Middleware that caches command results to improve performance.
///
/// This middleware intercepts command execution and checks if a cached result exists.
/// If found, it returns the cached result without executing the command.
/// Otherwise, it executes the command and caches the result for future use.
///
/// ## Example Usage
/// ```swift
/// let cache = InMemoryCache<String, String>(maxSize: 1000)
/// let middleware = CachingMiddleware(
///     cache: cache,
///     keyGenerator: { command in
///         // Generate cache key from command
///         return "\(type(of: command))-\(command.hashValue)"
///     },
///     ttl: 300 // 5 minutes
/// )
/// ```
///
/// ## Design Decision: @unchecked Sendable for Existential Types
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Existential Type Limitation**: The stored property `cache: any CacheProtocol`
///    uses an existential type. Swift currently cannot verify Sendable conformance through
///    existential types, even though the protocol requires Sendable.
///
/// 2. **All Properties Are Safe**:
///    - `cache`: Protocol requires Sendable conformance
///    - `keyGenerator`: @Sendable closure (explicitly thread-safe)
///    - `ttl`: TimeInterval? (Double?, inherently Sendable)
///    - `shouldCache`: @Sendable closure (explicitly thread-safe)
///
/// 3. **Protocol Guarantee**: CacheProtocol explicitly requires Sendable, ensuring any
///    cache implementation is thread-safe. This provides compile-time safety for all
///    concrete cache types.
///
/// 4. **Immutable Design**: All properties are `let` constants, preventing mutation after
///    initialization and eliminating potential race conditions.
///
/// This is a known Swift limitation with existential types. The code is actually thread-safe,
/// but the compiler cannot verify this through the existential type system.
public final class CachingMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .postProcessing // Caching happens after main processing
    
    private let cache: any CacheProtocol
    private let keyGenerator: @Sendable (any Command) -> String
    private let ttl: TimeInterval?
    private let shouldCache: @Sendable (any Command) -> Bool
    
    /// Creates a caching middleware with the specified configuration.
    ///
    /// - Parameters:
    ///   - cache: The cache backend to use
    ///   - keyGenerator: Function to generate cache keys from commands
    ///   - ttl: Time-to-live for cached entries (nil for no expiration)
    ///   - shouldCache: Function to determine if a command should be cached (default: always true)
    public init(
        cache: any CacheProtocol,
        keyGenerator: @escaping @Sendable (any Command) -> String,
        ttl: TimeInterval? = nil,
        shouldCache: @escaping @Sendable (any Command) -> Bool = { _ in true }
    ) {
        self.cache = cache
        self.keyGenerator = keyGenerator
        self.ttl = ttl
        self.shouldCache = shouldCache
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if we should cache this command
        guard shouldCache(command) else {
            return try await next(command, context)
        }
        
        // Generate cache key
        let key = keyGenerator(command)
        
        // Check if cached result exists
        if let cachedData = await cache.get(key: key) {
            // Try to decode the cached result
            if let decodedResult = try? decodeResult(cachedData, type: T.Result.self) {
                // Emit cache hit event
                await context.emitCustomEvent(
                    "cache.hit",
                    properties: [
                        "key": key,
                        "command": String(describing: type(of: command))
                    ]
                )
                return decodedResult
            }
        }
        
        // Cache miss - execute the command
        await context.emitCustomEvent(
            "cache.miss",
            properties: [
                "key": key,
                "command": String(describing: type(of: command))
            ]
        )
        
        let result = try await next(command, context)
        
        // Cache the result
        if let encodedData = try? encodeResult(result) {
            let expiration = ttl.map { Date().addingTimeInterval($0) }
            await cache.set(key: key, value: encodedData, expiration: expiration)
            
            await context.emitCustomEvent(
                "cache.stored",
                properties: [
                    "key": key,
                    "command": String(describing: type(of: command)),
                    "ttl": ttl ?? -1
                ]
            )
        }
        
        return result
    }
    
    private func encodeResult<T>(_ result: T) throws -> Data {
        // For now, use JSON encoding for Codable types
        // In production, you might want to use a more efficient encoding
        if let encodable = result as? Encodable {
            let encoder = JSONEncoder()
            return try encoder.encode(AnyEncodable(encodable))
        }
        
        // For non-Codable types, try to convert to string
        if let stringResult = result as? String {
            return Data(stringResult.utf8)
        }
        
        throw CachingError.notEncodable
    }
    
    private func decodeResult<T>(_ data: Data, type: T.Type) throws -> T {
        // Try JSON decoding for Codable types
        if type is Decodable.Type {
            let decoder = JSONDecoder()
            let anyDecodable = try decoder.decode(AnyDecodable.self, from: data)
            if let result = anyDecodable.value as? T {
                return result
            }
        }
        
        // Try string conversion
        if type == String.self, let stringResult = String(data: data, encoding: .utf8) {
            return stringResult as! T
        }
        
        throw CachingError.notDecodable
    }
}

// MARK: - Cache Protocol

/// Protocol for cache backends used by CachingMiddleware.
public protocol CacheProtocol: Sendable {
    /// Gets a value from the cache.
    func get(key: String) async -> Data?
    
    /// Sets a value in the cache with optional expiration.
    func set(key: String, value: Data, expiration: Date?) async
    
    /// Removes a value from the cache.
    func remove(key: String) async
    
    /// Clears all values from the cache.
    func clear() async
}

// MARK: - In-Memory Cache Implementation

/// Simple in-memory cache implementation.
public actor InMemoryCache: CacheProtocol {
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

// MARK: - Errors

public enum CachingError: LocalizedError {
    case notEncodable
    case notDecodable
    
    public var errorDescription: String? {
        switch self {
        case .notEncodable:
            return "Result type cannot be encoded for caching"
        case .notDecodable:
            return "Cached data cannot be decoded to result type"
        }
    }
}

// MARK: - Helper Types for Encoding/Decoding

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    
    init(_ encodable: Encodable) {
        _encode = encodable.encode
    }
    
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

private struct AnyDecodable: Decodable {
    let value: Any
    
    init(from decoder: Decoder) throws {
        // This is a simplified implementation
        // In production, you'd want more sophisticated type handling
        let container = try decoder.singleValueContainer()
        
        if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let dictValue = try? container.decode([String: AnyDecodable].self) {
            value = dictValue.mapValues { $0.value }
        } else if let arrayValue = try? container.decode([AnyDecodable].self) {
            value = arrayValue.map { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode value"
            )
        }
    }
}

// MARK: - Convenience Initializers

public extension CachingMiddleware {
    /// Creates a caching middleware with simple string-based key generation.
    convenience init(
        cache: any CacheProtocol,
        ttl: TimeInterval? = nil
    ) {
        self.init(
            cache: cache,
            keyGenerator: { command in
                // Simple key generation using command type and hash
                "\(type(of: command))-\(String(describing: command).hashValue)"
            },
            ttl: ttl
        )
    }
    
    /// Creates a caching middleware for specific command types.
    convenience init<C: Command & Hashable>(
        cache: any CacheProtocol,
        commandType: C.Type,
        ttl: TimeInterval? = nil
    ) {
        self.init(
            cache: cache,
            keyGenerator: { command in
                if let hashableCommand = command as? C {
                    return "\(type(of: command))-\(hashableCommand.hashValue)"
                }
                return "\(type(of: command))-\(String(describing: command).hashValue)"
            },
            ttl: ttl,
            shouldCache: { command in
                command is C
            }
        )
    }
}