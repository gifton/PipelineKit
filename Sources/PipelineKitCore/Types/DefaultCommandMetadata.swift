import Foundation

/// Default implementation of the `CommandMetadata` protocol.
/// 
/// Provides a metadata structure with automatic ID and timestamp generation.
/// 
/// Example:
/// ```swift
/// let metadata = DefaultCommandMetadata(
///     userId: "user123",
///     correlationId: "trace-456"
/// )
/// ```
public struct DefaultCommandMetadata: CommandMetadata, Equatable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let userId: String?
    public let correlationId: String?
    
    /// Creates new command metadata.
    /// 
    /// - Parameters:
    ///   - id: Unique identifier. Defaults to a new UUID.
    ///   - timestamp: Creation timestamp. Defaults to current date.
    ///   - userId: Optional user identifier for authorization.
    ///   - correlationId: Optional correlation ID for distributed tracing.
    @inlinable
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        userId: String? = nil,
        correlationId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.userId = userId
        self.correlationId = correlationId
    }
}