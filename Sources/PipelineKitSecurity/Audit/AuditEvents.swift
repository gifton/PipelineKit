import Foundation

// MARK: - Command Lifecycle Event

/// An audit event representing a command's lifecycle phase.
///
/// This event tracks when commands start, complete, or fail within the pipeline,
/// providing essential metadata for audit trails and debugging.
public struct CommandLifecycleEvent: AuditEvent {
    /// The phase of the command lifecycle.
    public enum Phase: String, Sendable {
        case started
        case completed
        case failed
    }
    
    /// The current phase of the command
    public let phase: Phase
    
    /// The type of command being executed
    public let commandType: String
    
    /// Unique identifier for this command execution
    public let commandId: UUID
    
    /// Optional user who initiated the command
    public let userId: String?
    
    /// Optional session identifier
    public let sessionId: String?
    
    /// Duration of execution (only for completed/failed phases)
    public let duration: TimeInterval?
    
    /// Error description (only for failed phase)
    public let error: String?
    
    /// When the event occurred
    public let timestamp: Date
    
    /// Creates a new command lifecycle event.
    public init(
        phase: Phase,
        commandType: String,
        commandId: UUID = UUID(),
        userId: String? = nil,
        sessionId: String? = nil,
        duration: TimeInterval? = nil,
        error: String? = nil,
        timestamp: Date = Date()
    ) {
        self.phase = phase
        self.commandType = commandType
        self.commandId = commandId
        self.userId = userId
        self.sessionId = sessionId
        self.duration = duration
        self.error = error
        self.timestamp = timestamp
    }
    
    // MARK: - AuditEvent Conformance
    
    public var eventType: String {
        "command.\(phase.rawValue)"
    }
    
    public var eventMetadata: [String: any Sendable] {
        var meta: [String: any Sendable] = [
            "commandType": commandType,
            "commandId": commandId.uuidString
        ]
        
        if let userId {
            meta["userId"] = userId
        }
        
        if let sessionId {
            meta["sessionId"] = sessionId
        }
        
        if let duration {
            meta["duration"] = duration
        }
        
        if let error {
            meta["error"] = error
        }
        
        return meta
    }
}

// MARK: - Security Audit Event

/// An audit event for security-related actions.
///
/// This event tracks security operations like encryption, decryption,
/// access control decisions, and key management.
public struct SecurityAuditEvent: AuditEvent {
    /// The type of security action performed.
    public enum Action: String, Sendable {
        case encryption
        case decryption
        case accessDenied
        case accessGranted
        case keyRotation
        case authenticationSuccess
        case authenticationFailure
    }
    
    /// The security action that occurred
    public let action: Action
    
    /// The resource or entity involved
    public let resource: String?
    
    /// The principal (user/service) involved
    public let principal: String?
    
    /// Additional details about the security event
    public let details: [String: any Sendable]
    
    /// When the event occurred
    public let timestamp: Date
    
    /// Creates a new security audit event.
    public init(
        action: Action,
        resource: String? = nil,
        principal: String? = nil,
        details: [String: any Sendable] = [:],
        timestamp: Date = Date()
    ) {
        self.action = action
        self.resource = resource
        self.principal = principal
        self.details = details
        self.timestamp = timestamp
    }
    
    // MARK: - AuditEvent Conformance
    
    public var eventType: String {
        "security.\(action.rawValue)"
    }
    
    public var eventMetadata: [String: any Sendable] {
        var meta = details
        
        if let resource {
            meta["resource"] = resource
        }
        
        if let principal {
            meta["principal"] = principal
        }
        
        return meta
    }
}

// MARK: - Generic Audit Event

/// A generic audit event for custom use cases.
///
/// Use this when the predefined event types don't match your needs.
public struct GenericAuditEvent: AuditEvent {
    public let eventType: String
    public let timestamp: Date
    private let metadata: [String: any Sendable]
    
    /// Creates a generic audit event.
    public init(
        eventType: String,
        metadata: [String: any Sendable] = [:],
        timestamp: Date = Date()
    ) {
        self.eventType = eventType
        self.timestamp = timestamp
        self.metadata = metadata
    }
    
    public var eventMetadata: [String: any Sendable] {
        metadata
    }
}
