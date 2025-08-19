import Foundation

/// Protocol for values that can be deep-copied in a CommandContext.
///
/// Adopt this protocol for reference types that should be deep-copied
/// when stored in a CommandContext. Value types don't need this protocol
/// as they already have copy semantics.
///
/// ## Example Implementation
/// ```swift
/// final class UserSession: ContextCopyable {
///     let id: String
///     var permissions: Set<String>
///     
///     init(id: String, permissions: Set<String>) {
///         self.id = id
///         self.permissions = permissions
///     }
///     
///     func contextCopy() -> UserSession {
///         return UserSession(id: id, permissions: permissions)
///     }
/// }
/// ```
///
/// ## Usage with CommandContext
/// ```swift
/// let forked = context.fork()
/// 
/// // Manually deep-copy specific values
/// if let session = context[.session] as? ContextCopyable {
///     forked[.session] = session.contextCopy()
/// }
/// ```
public protocol ContextCopyable: Sendable {
    /// Creates a deep copy of this value for use in a new context.
    ///
    /// Implementations should recursively copy any mutable reference types
    /// to ensure complete isolation between contexts.
    ///
    /// - Returns: A deep copy of this value
    func contextCopy() -> Self
}

// MARK: - Convenience Extensions

public extension CommandContext {
    /// Creates a new context with deep copies of values that conform to ContextCopyable.
    ///
    /// This method:
    /// 1. Creates a shallow fork of the context
    /// 2. Identifies values that conform to ContextCopyable
    /// 3. Replaces those values with deep copies
    ///
    /// Values that don't conform to ContextCopyable are shallow-copied as normal.
    ///
    /// - Note: This requires values to be accessed through known keys, as
    ///   the snapshot() method returns type-erased values.
    ///
    /// - Parameter copyableKeys: The context keys to check for ContextCopyable conformance
    /// - Returns: A new context with deep-copied values where applicable
    func deepFork<T: Sendable>(copying keys: [ContextKey<T>]) -> CommandContext {
        let newContext = self.fork()
        
        for key in keys {
            if let value = self[key] as? ContextCopyable,
               let copied = value.contextCopy() as? T {
                newContext[key] = copied
            }
        }
        
        return newContext
    }
}