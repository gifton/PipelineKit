import Foundation
import PipelineKitCore

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
                // Cache hit - return cached result
                return decodedResult
            }
        }
        
        // Cache miss - execute the command
        
        let result = try await next(command, context)
        
        // Cache the result
        if let encodedData = try? encodeResult(result) {
            let expiration = ttl.map { Date().addingTimeInterval($0) }
            await cache.set(key: key, value: encodedData, expiration: expiration)
        }
        
        return result
    }
    
    private func encodeResult<T>(_ result: T) throws -> Data {
        // Create a wrapper to store type information
        let wrapper = CacheWrapper(result: result)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(wrapper)
    }
    
    private func decodeResult<T>(_ data: Data, type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        do {
            // Try to decode as a CacheWrapper first
            let wrapper = try decoder.decode(CacheWrapper<T>.self, from: data)
            return wrapper.result
        } catch {
            // Fallback for plain string data
            if type == String.self, let stringResult = String(data: data, encoding: .utf8) {
                return stringResult as! T
            }
            throw PipelineError.cache(reason: .deserializationFailed("Cached data cannot be decoded to result type: \(error.localizedDescription)"))
        }
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
actor InMemoryCache: CacheProtocol {
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
    
    init(maxSize: Int = 1000) {
        self.maxSize = maxSize
    }
    
    func get(key: String) -> Data? {
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
    
    func set(key: String, value: Data, expiration: Date?) {
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
    
    func remove(key: String) {
        storage.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }
    
    func clear() {
        storage.removeAll()
        accessOrder.removeAll()
    }
}


// MARK: - Helper Types for Encoding/Decoding

/// Wrapper to store cached values with type information
private struct CacheWrapper<T>: Codable {
    let result: T
    let typeInfo: String
    
    init(result: T) {
        self.result = result
        self.typeInfo = String(describing: T.self)
    }
    
    enum CodingKeys: String, CodingKey {
        case result
        case typeInfo
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.typeInfo = try container.decode(String.self, forKey: .typeInfo)
        
        // Handle different types based on T
        if T.self == String.self {
            self.result = try container.decode(String.self, forKey: .result) as! T
        } else if T.self == Int.self {
            self.result = try container.decode(Int.self, forKey: .result) as! T
        } else if T.self == Double.self {
            self.result = try container.decode(Double.self, forKey: .result) as! T
        } else if T.self == Bool.self {
            self.result = try container.decode(Bool.self, forKey: .result) as! T
        } else if T.self == Data.self {
            self.result = try container.decode(Data.self, forKey: .result) as! T
        } else if T.self == Date.self {
            self.result = try container.decode(Date.self, forKey: .result) as! T
        } else if T.self == [String].self {
            self.result = try container.decode([String].self, forKey: .result) as! T
        } else if T.self == [Int].self {
            self.result = try container.decode([Int].self, forKey: .result) as! T
        } else if T.self == [String: String].self {
            self.result = try container.decode([String: String].self, forKey: .result) as! T
        } else if T.self == [String: Int].self {
            self.result = try container.decode([String: Int].self, forKey: .result) as! T
        } else {
            // For other Decodable types, try generic decoding
            if let decodableType = T.self as? Decodable.Type {
                let value = try decodableType.init(from: try container.superDecoder(forKey: .result))
                self.result = value as! T
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .result,
                    in: container,
                    debugDescription: "Type \(T.self) is not supported for caching"
                )
            }
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeInfo, forKey: .typeInfo)
        
        // Handle different types
        if let value = result as? String {
            try container.encode(value, forKey: .result)
        } else if let value = result as? Int {
            try container.encode(value, forKey: .result)
        } else if let value = result as? Double {
            try container.encode(value, forKey: .result)
        } else if let value = result as? Bool {
            try container.encode(value, forKey: .result)
        } else if let value = result as? Data {
            try container.encode(value, forKey: .result)
        } else if let value = result as? Date {
            try container.encode(value, forKey: .result)
        } else if let value = result as? [String] {
            try container.encode(value, forKey: .result)
        } else if let value = result as? [Int] {
            try container.encode(value, forKey: .result)
        } else if let value = result as? [String: String] {
            try container.encode(value, forKey: .result)
        } else if let value = result as? [String: Int] {
            try container.encode(value, forKey: .result)
        } else if let encodable = result as? Encodable {
            // For other Encodable types
            try encodable.encode(to: container.superEncoder(forKey: .result))
        } else {
            throw EncodingError.invalidValue(
                result,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Type \(T.self) is not supported for caching"
                )
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