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

