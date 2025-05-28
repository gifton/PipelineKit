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
public actor CommandContext {
    private var storage: [ObjectIdentifier: Any] = [:]
    private let metadata: CommandMetadata
    
    /// Creates a new command context with the given metadata.
    /// 
    /// - Parameter metadata: The command metadata for this execution
    public init(metadata: CommandMetadata) {
        self.metadata = metadata
    }
    
    /// Gets the command metadata.
    public var commandMetadata: CommandMetadata {
        metadata
    }
    
    /// Gets a value from the context using a type-safe key.
    /// 
    /// - Parameter key: The context key type
    /// - Returns: The stored value, or nil if not present
    public subscript<Key: ContextKey>(_ key: Key.Type) -> Key.Value? {
        get {
            storage[ObjectIdentifier(key)] as? Key.Value
        }
    }
    
    /// Sets a value in the context using a type-safe key.
    /// 
    /// - Parameters:
    ///   - key: The context key type
    ///   - value: The value to store
    public func set<Key: ContextKey>(_ value: Key.Value?, for key: Key.Type) {
        if let value = value {
            storage[ObjectIdentifier(key)] = value
        } else {
            storage.removeValue(forKey: ObjectIdentifier(key))
        }
    }
    
    /// Removes a value from the context.
    /// 
    /// - Parameter key: The context key type
    public func remove<Key: ContextKey>(_ key: Key.Type) {
        storage.removeValue(forKey: ObjectIdentifier(key))
    }
    
    /// Clears all values from the context.
    public func clear() {
        storage.removeAll()
    }
    
    /// Gets all keys currently stored in the context.
    public var keys: [ObjectIdentifier] {
        Array(storage.keys)
    }
}