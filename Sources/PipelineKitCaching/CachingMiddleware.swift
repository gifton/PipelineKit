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
/// 1. **Existential Type Limitation**: The stored property `cache: any Cache`
///    uses an existential type. Swift currently cannot verify Sendable conformance through
///    existential types, even though the protocol requires Sendable.
///
/// 2. **All Properties Are Safe**:
///    - `cache`: Protocol requires Sendable conformance
///    - `keyGenerator`: @Sendable closure (explicitly thread-safe)
///    - `ttl`: TimeInterval? (Double?, inherently Sendable)
///    - `shouldCache`: @Sendable closure (explicitly thread-safe)
///
/// 3. **Protocol Guarantee**: Cache protocol explicitly requires Sendable, ensuring any
///    cache implementation is thread-safe. This provides compile-time safety for all
///    concrete cache types.
///
/// 4. **Immutable Design**: All properties are `let` constants, preventing mutation after
///    initialization and eliminating potential race conditions.
///
/// This is a known Swift limitation with existential types. The code is actually thread-safe,
/// but the compiler cannot verify this through the existential type system.
///
/// Thread Safety: This type is thread-safe because all properties are immutable (let constants).
/// The cache protocol requires Sendable conformance, and all closures are marked @Sendable.
/// Invariant: All properties must be initialized with thread-safe values. The Cache protocol
/// enforces Sendable conformance for any concrete implementation.
public final class CachingMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .postProcessing // Caching happens after main processing
    
    private let cache: any Cache
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
        cache: any Cache,
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
            if type == String.self,
               let stringResult = String(data: data, encoding: .utf8),
               let typedResult = stringResult as? T {
                return typedResult
            }
            throw PipelineError.cache(reason: .deserializationFailed("Cached data cannot be decoded to result type: \(error.localizedDescription)"))
        }
    }
}

// MARK: - Cache Re-export

// Cache protocol is in PipelineKitCore, implementations are local to this module
public typealias Cache = PipelineKitCore.Cache


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
            guard let value = try container.decode(String.self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for String"))
            }
            self.result = value
        } else if T.self == Int.self {
            guard let value = try container.decode(Int.self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for Int"))
            }
            self.result = value
        } else if T.self == Double.self {
            guard let value = try container.decode(Double.self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for Double"))
            }
            self.result = value
        } else if T.self == Bool.self {
            guard let value = try container.decode(Bool.self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for Bool"))
            }
            self.result = value
        } else if T.self == Data.self {
            guard let value = try container.decode(Data.self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for Data"))
            }
            self.result = value
        } else if T.self == Date.self {
            guard let value = try container.decode(Date.self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for Date"))
            }
            self.result = value
        } else if T.self == [String].self {
            guard let value = try container.decode([String].self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for [String]"))
            }
            self.result = value
        } else if T.self == [Int].self {
            guard let value = try container.decode([Int].self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for [Int]"))
            }
            self.result = value
        } else if T.self == [String: String].self {
            guard let value = try container.decode([String: String].self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for [String: String]"))
            }
            self.result = value
        } else if T.self == [String: Int].self {
            guard let value = try container.decode([String: Int].self, forKey: .result) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for [String: Int]"))
            }
            self.result = value
        } else {
            // For other Decodable types, try generic decoding
            if let decodableType = T.self as? Decodable.Type {
                let value = try decodableType.init(from: try container.superDecoder(forKey: .result))
                guard let typedValue = value as? T else {
                    throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [CodingKeys.result], debugDescription: "Type mismatch for Decodable type"))
                }
                self.result = typedValue
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
        cache: any Cache,
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
        cache: any Cache,
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
