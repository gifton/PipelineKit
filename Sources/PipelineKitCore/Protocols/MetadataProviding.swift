import Foundation

/// Protocol for objects that can provide metadata for audit logging and processing.
///
/// This protocol enables middleware to extract metadata from commands and results
/// for purposes such as audit logging, metrics collection, and debugging.
///
/// ## Overview
///
/// Types conforming to this protocol expose a dictionary of metadata that can be
/// safely accessed and logged without exposing sensitive information.
///
/// ## Usage
///
/// ```swift
/// struct CreateUserCommand: Command, MetadataProviding {
///     let email: String
///     let name: String
///     
///     var metadata: [String: any Sendable] {
///         return [
///             "commandType": "CreateUser",
///             "hasEmail": !email.isEmpty,
///             // Don't include sensitive data directly
///             "nameLength": name.count
///         ]
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// The metadata dictionary should be immutable once created. If your type needs
/// to provide dynamic metadata, ensure thread-safe access.
///
/// - SeeAlso: `AuditLoggingMiddleware`, `Command`
public protocol MetadataProviding {
    /// A dictionary of metadata associated with this object.
    ///
    /// - Important: Do not include sensitive information (passwords, tokens, PII)
    ///   directly in metadata. Instead, include flags or sanitized representations.
    var metadata: [String: any Sendable] { get }
}

// MARK: - Safe Accessor Extensions

public extension MetadataProviding {
    /// Safely retrieves a metadata value with type checking.
    ///
    /// - Parameters:
    ///   - key: The metadata key to retrieve
    ///   - type: The expected type of the value
    /// - Returns: The value if it exists and matches the type, nil otherwise
    ///
    /// Example:
    /// ```swift
    /// if let userId = command.metadataValue(for: "userId", as: String.self) {
    ///     // Use userId safely
    /// }
    /// ```
    func metadataValue<T>(for key: String, as type: T.Type) -> T? {
        metadata[key] as? T
    }
    
    /// Safely retrieves a metadata value with a default.
    ///
    /// - Parameters:
    ///   - key: The metadata key to retrieve
    ///   - defaultValue: The value to return if key doesn't exist or type doesn't match
    /// - Returns: The value if it exists and matches the type, defaultValue otherwise
    func metadataValue<T>(for key: String, default defaultValue: T) -> T {
        (metadata[key] as? T) ?? defaultValue
    }
    
    /// Checks if a metadata key exists.
    ///
    /// - Parameter key: The metadata key to check
    /// - Returns: true if the key exists, false otherwise
    func hasMetadata(for key: String) -> Bool {
        metadata[key] != nil
    }
    
    /// Returns metadata filtered to only include specified keys.
    ///
    /// - Parameter keys: The keys to include
    /// - Returns: A dictionary containing only the specified keys that exist
    func metadata(including keys: Set<String>) -> [String: Any] {
        metadata.filter { keys.contains($0.key) }
    }
    
    /// Returns metadata with specified keys excluded.
    ///
    /// - Parameter keys: The keys to exclude
    /// - Returns: A dictionary with the specified keys removed
    func metadata(excluding keys: Set<String>) -> [String: Any] {
        metadata.filter { !keys.contains($0.key) }
    }
}

// MARK: - CommandContext Extension

extension CommandContext: MetadataProviding {
    // CommandContext already has a metadata property with the correct type [String: any Sendable],
    // so it automatically conforms to the protocol.
}