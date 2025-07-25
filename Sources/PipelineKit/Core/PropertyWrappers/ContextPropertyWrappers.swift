import Foundation

// MARK: - Context Access Helpers

// Note: Property wrappers for async context access have limitations in Swift
// Using helper functions and structs instead for better ergonomics

/// Context accessor that provides type-safe access to context values.
public struct ContextAccessor<Key: ContextKey> {
    private let context: CommandContext
    private let key: Key.Type
    
    public init(_ keyType: Key.Type, context: CommandContext) {
        self.key = keyType
        self.context = context
    }
    
    /// Get value from context
    public func get() -> Key.Value? {
        context[key]
    }
    
    /// Set a new value in the context
    public func set(_ value: Key.Value?) {
        context.set(value, for: key)
    }
    
    /// Projected value provides additional context operations
    public var projectedValue: ContextProjection<Key> {
        ContextProjection(context: context, key: key)
    }
}

/// Required context accessor that throws if value is missing.
public struct RequiredContextAccessor<Key: ContextKey> {
    private let context: CommandContext
    private let key: Key.Type
    
    public init(_ keyType: Key.Type, context: CommandContext) {
        self.key = keyType
        self.context = context
    }
    
    public func get() throws -> Key.Value {
        guard let value = context[key] else {
            throw ContextError.missingRequiredValue(String(describing: key))
        }
        return value
    }
    
    public func set(_ value: Key.Value) {
        context.set(value, for: key)
    }
}

/// Context accessor with default fallback value.
public struct DefaultContextAccessor<Key: ContextKey> {
    private let context: CommandContext
    private let key: Key.Type
    private let defaultValue: Key.Value
    
    public init(_ keyType: Key.Type, default defaultValue: Key.Value, context: CommandContext) {
        self.key = keyType
        self.defaultValue = defaultValue
        self.context = context
    }
    
    public func get() -> Key.Value {
        context[key] ?? defaultValue
    }
    
    public func set(_ value: Key.Value) {
        context.set(value, for: key)
    }
}

// MARK: - Supporting Types

/// Projected value for additional context operations.
public struct ContextProjection<Key: ContextKey> {
    private let context: CommandContext
    private let key: Key.Type
    
    init(context: CommandContext, key: Key.Type) {
        self.context = context
        self.key = key
    }
    
    /// Check if the value exists in context.
    public func exists() -> Bool {
        context[key] != nil
    }
    
    /// Remove the value from context.
    public func remove() {
        context.remove(key)
    }
    
    /// Update the value if it exists.
    public func update(_ transform: @Sendable (Key.Value) -> Key.Value) {
        if let currentValue = context[key] {
            let newValue = transform(currentValue)
            context.set(newValue, for: key)
        }
    }
    
    /// Set value with expiration.
    /// Note: Expiration is not implemented in this version.
    /// For time-based expiration, consider using a caching middleware.
    public func set(_ value: Key.Value, expiringIn ttl: TimeInterval) {
        context.set(value, for: key)
    }
}

// MARK: - Context Errors

public enum ContextError: Error, LocalizedError {
    case missingRequiredValue(String)
    case typeMismatch(expected: Any.Type, actual: Any.Type)
    case accessDenied(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingRequiredValue(let key):
            return "Required context value missing for key: \(key)"
        case .typeMismatch(let expected, let actual):
            return "Type mismatch - expected: \(expected), actual: \(actual)"
        case .accessDenied(let reason):
            return "Context access denied: \(reason)"
        }
    }
}

// MARK: - Context Extensions

public extension CommandContext {
    /// Create a context accessor.
    func accessor<Key: ContextKey>(for keyType: Key.Type) -> ContextAccessor<Key> {
        ContextAccessor(keyType, context: self)
    }
    
    /// Create a required context accessor.
    func required<Key: ContextKey>(for keyType: Key.Type) -> RequiredContextAccessor<Key> {
        RequiredContextAccessor(keyType, context: self)
    }
    
    /// Create a context accessor with default fallback.
    func accessor<Key: ContextKey>(for keyType: Key.Type, default defaultValue: Key.Value) -> DefaultContextAccessor<Key> {
        DefaultContextAccessor(keyType, default: defaultValue, context: self)
    }
}
