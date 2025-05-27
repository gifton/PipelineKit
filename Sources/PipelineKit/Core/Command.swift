import Foundation

/// A command represents an intent to perform an action in the system.
/// 
/// Commands are the primary unit of work in the Command-Pipeline architecture.
/// They encapsulate data and intent, and are processed by command handlers.
/// 
/// All commands must be `Sendable` to ensure thread safety in concurrent environments.
/// 
/// Example:
/// ```swift
/// struct CreateUserCommand: Command {
///     typealias Result = User
///     let email: String
///     let name: String
/// }
/// ```
public protocol Command: Sendable {
    /// The type of result produced when this command is executed.
    /// Must also be `Sendable` for thread safety.
    associatedtype Result: Sendable
}

/// Metadata associated with command execution.
/// 
/// This protocol defines the standard metadata that should accompany
/// command execution for tracking, auditing, and correlation purposes.
public protocol CommandMetadata: Sendable {
    /// Unique identifier for this command execution
    var id: UUID { get }
    
    /// Timestamp when the command was created
    var timestamp: Date { get }
    
    /// Optional user identifier for authorization and auditing
    var userId: String? { get }
    
    /// Optional correlation ID for distributed tracing
    var correlationId: String? { get }
}

/// Default implementation of `CommandMetadata`.
/// 
/// Provides a standard metadata structure with automatic ID and timestamp generation.
/// 
/// Example:
/// ```swift
/// let metadata = DefaultCommandMetadata(
///     userId: "user123",
///     correlationId: "trace-456"
/// )
/// ```
public struct DefaultCommandMetadata: CommandMetadata {
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