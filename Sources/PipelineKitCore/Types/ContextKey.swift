import Foundation

/// A type-safe key for storing values in a command context.
/// 
/// Context keys provide type safety when storing and retrieving values
/// from the command execution context. Each key type is automatically
/// assigned a unique integer ID for high-performance lookups.
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
    
    /// A unique integer identifier for this key type.
    /// The default implementation automatically assigns a unique ID.
    static var keyID: Int { get }
}

// MARK: - Key ID Generation

/// A type that provides a unique integer ID based on its memory address.
/// This is more efficient than using ObjectIdentifier for lookups.
private struct TypeID {
    static func id<T>(for type: T.Type) -> Int {
        // Use the type's metadata pointer as a unique identifier
        // This is stable for the lifetime of the program
        return unsafeBitCast(type, to: Int.self)
    }
}

// MARK: - Default Implementation

extension ContextKey {
    /// Returns a unique integer ID for this key type.
    /// Uses the type's metadata pointer for zero-cost identification.
    public static var keyID: Int {
        TypeID.id(for: Self.self)
    }
}