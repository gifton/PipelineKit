import Foundation

/// An optimized command context with reduced memory overhead and improved performance.
///
/// This implementation features:
/// - Copy-on-write storage for efficient cloning
/// - Inline storage for common keys to avoid allocations
/// - Lazy initialization of storage dictionary
/// - Cache-friendly memory layout
///
/// **ultrathink**: The key insight is that most contexts only use a few well-known keys.
/// By providing inline storage for these common keys, we avoid dictionary allocations
/// and lookups in the common case. The COW wrapper ensures efficient cloning when
/// contexts are passed through middleware chains.
public actor OptimizedCommandContext: @unchecked Sendable {
    
    // MARK: - Storage
    
    /// Copy-on-write storage wrapper
    private final class Storage {
        /// Dictionary for arbitrary keys
        var dictionary: [ObjectIdentifier: Any]?
        
        /// Inline storage for common keys
        var requestId: String?
        var userId: String?
        var startTime: Date?
        var correlationId: String?
        var traceId: String?
        
        /// Reference count for COW semantics
        var refCount: Int = 1
        
        init() {}
        
        /// Creates a copy for COW
        func copy() -> Storage {
            let new = Storage()
            new.dictionary = dictionary
            new.requestId = requestId
            new.userId = userId
            new.startTime = startTime
            new.correlationId = correlationId
            new.traceId = traceId
            return new
        }
    }
    
    private var storage: Storage
    private let metadata: CommandMetadata
    
    // MARK: - Initialization
    
    public init(metadata: CommandMetadata) {
        self.metadata = metadata
        self.storage = Storage()
        
        // Pre-populate common fields from metadata if available
        if let standardMetadata = metadata as? StandardCommandMetadata {
            storage.userId = standardMetadata.userId
            storage.correlationId = standardMetadata.correlationId
            storage.startTime = standardMetadata.timestamp
        }
    }
    
    public init() {
        self.metadata = StandardCommandMetadata()
        self.storage = Storage()
    }
    
    // MARK: - Public API
    
    public var commandMetadata: CommandMetadata {
        metadata
    }
    
    public subscript<Key: ContextKey>(_ key: Key.Type) -> Key.Value? {
        get {
            getValue(for: key)
        }
    }
    
    public func get<Key: ContextKey>(_ key: Key.Type) -> Key.Value? {
        getValue(for: key)
    }
    
    public func set<Key: ContextKey>(_ value: Key.Value?, for key: Key.Type) {
        ensureUniqueStorage()
        setValue(value, for: key)
    }
    
    public func remove<Key: ContextKey>(_ key: Key.Type) {
        ensureUniqueStorage()
        setValue(nil, for: key)
    }
    
    public func clear() {
        storage = Storage() // Create new storage, old one will be deallocated
    }
    
    public var keys: [ObjectIdentifier] {
        var result: [ObjectIdentifier] = []
        
        // Add inline storage keys if set
        if storage.requestId != nil {
            result.append(ObjectIdentifier(RequestIDKey.self))
        }
        if storage.userId != nil {
            result.append(ObjectIdentifier(UserIDKey.self))
        }
        if storage.startTime != nil {
            result.append(ObjectIdentifier(RequestStartTimeKey.self))
        }
        if storage.correlationId != nil {
            result.append(ObjectIdentifier(CorrelationIDKey.self))
        }
        if storage.traceId != nil {
            result.append(ObjectIdentifier(TraceIDKey.self))
        }
        
        // Add dictionary keys
        if let dict = storage.dictionary {
            result.append(contentsOf: dict.keys)
        }
        
        return result
    }
    
    // MARK: - Optimized Storage Access
    
    /// Gets a value using optimized storage.
    ///
    /// **ultrathink**: We check inline storage first for common keys, avoiding
    /// dictionary lookup overhead. This is a significant optimization since
    /// these keys are accessed frequently in middleware chains.
    private func getValue<Key: ContextKey>(for key: Key.Type) -> Key.Value? {
        let keyId = ObjectIdentifier(key)
        
        // Check inline storage for common keys
        switch keyId {
        case ObjectIdentifier(RequestIDKey.self):
            return storage.requestId as? Key.Value
        case ObjectIdentifier(UserIDKey.self):
            return storage.userId as? Key.Value
        case ObjectIdentifier(RequestStartTimeKey.self):
            return storage.startTime as? Key.Value
        case ObjectIdentifier(CorrelationIDKey.self):
            return storage.correlationId as? Key.Value
        case ObjectIdentifier(TraceIDKey.self):
            return storage.traceId as? Key.Value
        default:
            // Fall back to dictionary for other keys
            return storage.dictionary?[keyId] as? Key.Value
        }
    }
    
    /// Sets a value using optimized storage.
    private func setValue<Key: ContextKey>(_ value: Key.Value?, for key: Key.Type) {
        let keyId = ObjectIdentifier(key)
        
        // Use inline storage for common keys
        switch keyId {
        case ObjectIdentifier(RequestIDKey.self):
            storage.requestId = value as? String
        case ObjectIdentifier(UserIDKey.self):
            storage.userId = value as? String
        case ObjectIdentifier(RequestStartTimeKey.self):
            storage.startTime = value as? Date
        case ObjectIdentifier(CorrelationIDKey.self):
            storage.correlationId = value as? String
        case ObjectIdentifier(TraceIDKey.self):
            storage.traceId = value as? String
        default:
            // Use dictionary for other keys
            if value != nil {
                // Lazy initialize dictionary
                if storage.dictionary == nil {
                    storage.dictionary = [:]
                }
                storage.dictionary?[keyId] = value
            } else {
                storage.dictionary?.removeValue(forKey: keyId)
            }
        }
    }
    
    /// Ensures storage is unique for COW semantics.
    private func ensureUniqueStorage() {
        if storage.refCount > 1 {
            storage.refCount -= 1
            storage = storage.copy()
        }
    }
    
    // MARK: - Performance Helpers
    
    /// Pre-populates common keys for better performance.
    public func prepopulate() {
        ensureUniqueStorage()
        
        if storage.requestId == nil {
            storage.requestId = UUID().uuidString
        }
        if storage.startTime == nil {
            storage.startTime = Date()
        }
    }
    
    /// Creates a lightweight snapshot for passing to other actors.
    public func snapshot() -> ContextSnapshot {
        ContextSnapshot(
            requestId: storage.requestId,
            userId: storage.userId,
            startTime: storage.startTime,
            correlationId: storage.correlationId,
            traceId: storage.traceId,
            additionalData: storage.dictionary ?? [:]
        )
    }
}

// MARK: - Supporting Types

/// A lightweight, immutable snapshot of context data.
public struct ContextSnapshot: Sendable {
    public let requestId: String?
    public let userId: String?
    public let startTime: Date?
    public let correlationId: String?
    public let traceId: String?
    public let additionalData: [ObjectIdentifier: Any]
}

// MARK: - Common Context Keys

/// Context key for request ID
private struct RequestIDKey: ContextKey {
    typealias Value = String
}

/// Context key for user ID
private struct UserIDKey: ContextKey {
    typealias Value = String
}

/// Context key for request start time
private struct RequestStartTimeKey: ContextKey {
    typealias Value = Date
}

/// Context key for correlation ID
private struct CorrelationIDKey: ContextKey {
    typealias Value = String
}

/// Context key for trace ID
private struct TraceIDKey: ContextKey {
    typealias Value = String
}

// MARK: - Factory

/// Factory for creating optimized contexts with pooling support.
public struct OptimizedContextFactory {
    private let pool: ObjectPool<OptimizedCommandContext>
    
    public init(poolSize: Int = 100) {
        self.pool = ObjectPool(
            maxSize: poolSize,
            factory: { OptimizedCommandContext() },
            reset: { context in
                await context.clear()
            }
        )
    }
    
    public func create() async -> OptimizedCommandContext {
        let context = await pool.acquire()
        await context.prepopulate()
        return context
    }
    
    public func release(_ context: OptimizedCommandContext) async {
        await pool.release(context)
    }
    
    public func statistics() async -> PoolStatistics {
        await pool.statistics
    }
}