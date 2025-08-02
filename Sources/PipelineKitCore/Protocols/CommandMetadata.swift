import Foundation

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