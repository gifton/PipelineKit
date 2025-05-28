import Foundation

/// A type-safe key for storing values in a command context.
/// 
/// Context keys provide type safety when storing and retrieving values
/// from the command execution context.
/// 
/// Example:
/// ```swift
/// struct UserContextKey: ContextKey {
///     typealias Value = User
/// }
/// 
/// // Store in context
/// context[UserContextKey.self] = authenticatedUser
/// 
/// // Retrieve from context
/// let user = context[UserContextKey.self]
/// ```
public protocol ContextKey {
    /// The type of value associated with this key
    associatedtype Value: Sendable
}