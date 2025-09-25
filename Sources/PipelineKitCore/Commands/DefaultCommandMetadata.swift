import Foundation

/// Default implementation of the `CommandMetadata` protocol.
/// 
/// Provides a metadata structure with automatic ID and timestamp generation.
/// 
/// Example:
/// ```swift
/// let metadata = DefaultCommandMetadata(
///     userID: "user123",
///     correlationID: "trace-456"
/// )
/// ```
@frozen
public struct DefaultCommandMetadata: CommandMetadata, Equatable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let userID: String?
    public let correlationID: String?
    
    /// Creates new command metadata.
    /// 
    /// - Parameters:
    ///   - id: Unique identifier. Defaults to a new UUID.
    ///   - timestamp: Creation timestamp. Defaults to current date.
    ///   - userID: Optional user identifier for authorization.
    ///   - correlationID: Optional correlation ID for distributed tracing.
    @inlinable
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        userID: String? = nil,
        correlationID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.userID = userID
        self.correlationID = correlationID
    }
}
