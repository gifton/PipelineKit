import Foundation

/// A context that carries data throughout command execution.
/// 
/// The command context provides a type-safe way to share data between
/// middleware components and handlers during command execution. It's
/// particularly useful for:
/// 
/// - Authentication/authorization results
/// - Request timing and performance metrics
/// - Feature flags and configuration
/// - Temporary computation results
/// - Cross-cutting concerns
/// 
/// The context is request-scoped and isolated to a single command execution.
/// 
/// ## Thread Safety
/// This implementation uses NSLock for thread-safe access to the storage,
/// providing significantly better performance than the previous actor-based
/// implementation while maintaining safety in concurrent environments.
public final class CommandContext: @unchecked Sendable {
    /// Pre-sized storage using integer keys for optimal performance.
    /// Most contexts use 8-16 keys.
    internal var storage: [Int: Any]
    internal private(set) var metadata: CommandMetadata
    internal let lock = NSLock()
    
    /// Creates a new command context with the given metadata.
    /// 
    /// - Parameter metadata: The command metadata for this execution
    public init(metadata: CommandMetadata) {
        self.metadata = metadata
        // Pre-size dictionary to avoid rehashing during typical usage
        self.storage = Dictionary(minimumCapacity: 16)
    }
    
    /// Creates a new command context with standard metadata.
    public convenience init() {
        self.init(metadata: StandardCommandMetadata())
    }
    
    /// Gets the command metadata.
    /// - Note: Metadata is immutable and doesn't require locking
    public var commandMetadata: CommandMetadata {
        metadata
    }
    
    /// Gets a value from the context using a type-safe key.
    /// 
    /// - Parameter key: The context key type
    /// - Returns: The stored value, or nil if not present
    public subscript<Key: ContextKey>(_ key: Key.Type) -> Key.Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage[Key.keyID] as? Key.Value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let value = newValue {
                storage[Key.keyID] = value
            } else {
                storage.removeValue(forKey: Key.keyID)
            }
        }
    }
    
    /// Gets a value from the context using a type-safe key.
    /// 
    /// - Parameter key: The context key type
    /// - Returns: The stored value, or nil if not present
    public func get<Key: ContextKey>(_ key: Key.Type) -> Key.Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[Key.keyID] as? Key.Value
    }
    
    /// Sets a value in the context using a type-safe key.
    /// 
    /// - Parameters:
    ///   - value: The value to store
    ///   - key: The context key type
    public func set<Key: ContextKey>(_ value: Key.Value?, for key: Key.Type) {
        lock.lock()
        defer { lock.unlock() }
        if let value = value {
            storage[Key.keyID] = value
        } else {
            storage.removeValue(forKey: Key.keyID)
        }
    }
    
    /// Removes a value from the context.
    /// 
    /// - Parameter key: The context key type
    public func remove<Key: ContextKey>(_ key: Key.Type) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: Key.keyID)
    }
    
    /// Clears all values from the context.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        // Keep capacity to avoid reallocation on reuse
        storage.removeAll(keepingCapacity: true)
    }
    
    /// Gets all key IDs currently stored in the context.
    public var keyIDs: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.keys)
    }
    
    /// Creates a snapshot of the current context values.
    /// Useful for debugging and testing.
    public func snapshot() -> [Int: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    
}