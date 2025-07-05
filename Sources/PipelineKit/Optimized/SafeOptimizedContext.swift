import Foundation
import os

/// Thread-safe context implementation using COW semantics
public final class SafeOptimizedCommandContext: CommandContext {
    /// Copy-on-write storage
    private var storage: Storage
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    
    private final class Storage {
        var dictionary: [ObjectIdentifier: Any] = [:]
        var metadata: CommandMetadata
        
        init(metadata: CommandMetadata) {
            self.metadata = metadata
        }
        
        func copy() -> Storage {
            let newStorage = Storage(metadata: metadata)
            newStorage.dictionary = dictionary
            return newStorage
        }
    }
    
    public init(metadata: CommandMetadata = StandardCommandMetadata()) {
        self.storage = Storage(metadata: metadata)
        lock.initialize(to: os_unfair_lock())
    }
    
    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
    
    public func get<T>(_ key: ContextKey<T>.Type) async -> T? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        return storage.dictionary[ObjectIdentifier(key)] as? T
    }
    
    public func set<T>(_ value: T?, for key: ContextKey<T>.Type) async {
        os_unfair_lock_lock(lock)
        
        // Copy-on-write
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }
        
        if let value = value {
            storage.dictionary[ObjectIdentifier(key)] = value
        } else {
            storage.dictionary.removeValue(forKey: ObjectIdentifier(key))
        }
        
        os_unfair_lock_unlock(lock)
    }
    
    public func values() async -> [String: Any] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        var result: [String: Any] = [:]
        for (key, value) in storage.dictionary {
            result[String(describing: key)] = value
        }
        return result
    }
    
    public func metadata() -> CommandMetadata {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        return storage.metadata
    }
}

/// Inline storage optimization for common keys
public final class InlineOptimizedContext: CommandContext {
    // Common inline storage
    private var userId: String?
    private var traceId: String?
    private var correlationId: String?
    
    // Fallback storage for other keys
    private let fallback: SafeOptimizedCommandContext
    
    // Known common keys
    private enum CommonKey {
        static let userId = ObjectIdentifier(UserIdKey.self)
        static let traceId = ObjectIdentifier(TraceIdKey.self)
        static let correlationId = ObjectIdentifier(CorrelationIdKey.self)
    }
    
    public init(metadata: CommandMetadata = StandardCommandMetadata()) {
        self.fallback = SafeOptimizedCommandContext(metadata: metadata)
    }
    
    public func get<T>(_ key: ContextKey<T>.Type) async -> T? {
        let keyId = ObjectIdentifier(key)
        
        switch keyId {
        case CommonKey.userId:
            return userId as? T
        case CommonKey.traceId:
            return traceId as? T
        case CommonKey.correlationId:
            return correlationId as? T
        default:
            return await fallback.get(key)
        }
    }
    
    public func set<T>(_ value: T?, for key: ContextKey<T>.Type) async {
        let keyId = ObjectIdentifier(key)
        
        switch keyId {
        case CommonKey.userId:
            userId = value as? String
        case CommonKey.traceId:
            traceId = value as? String
        case CommonKey.correlationId:
            correlationId = value as? String
        default:
            await fallback.set(value, for: key)
        }
    }
    
    public func values() async -> [String: Any] {
        var result = await fallback.values()
        
        if let userId = userId {
            result["UserId"] = userId
        }
        if let traceId = traceId {
            result["TraceId"] = traceId
        }
        if let correlationId = correlationId {
            result["CorrelationId"] = correlationId
        }
        
        return result
    }
    
    public func metadata() -> CommandMetadata {
        fallback.metadata()
    }
}

// Common context keys
public struct UserIdKey: ContextKey {
    public typealias Value = String
}

public struct TraceIdKey: ContextKey {
    public typealias Value = String
}

public struct CorrelationIdKey: ContextKey {
    public typealias Value = String
}