import Foundation

// MARK: - Core Protocol

/// A logger for audit events in the pipeline system.
///
/// This protocol defines a minimal interface for audit logging with a single
/// method, making it easy to mock, test, and extend. Implementations can
/// choose their own concurrency model (actor, struct, class) as needed.
///
/// Example:
/// ```swift
/// let logger = ConsoleAuditLogger()
/// await logger.log(CommandLifecycleEvent(
///     phase: .started,
///     commandType: "CreateUser",
///     commandId: UUID()
/// ))
/// ```
public protocol AuditLogger: Sendable {
    /// Logs an audit event asynchronously.
    ///
    /// This method should never throw - audit logging failures should not
    /// interrupt business logic. Implementations should handle errors
    /// internally and optionally report them via the health stream.
    ///
    /// - Parameter event: The audit event to log
    func log(_ event: any AuditEvent) async
    
    /// A stream of health events for monitoring logger status.
    ///
    /// Implementations can use this to report issues like dropped events,
    /// backpressure, or sink failures. The default implementation returns
    /// a finished stream, indicating no health monitoring.
    var health: AsyncStream<LoggerHealthEvent> { get }
}

// MARK: - Default Implementations

public extension AuditLogger {
    /// Default health stream that immediately finishes.
    var health: AsyncStream<LoggerHealthEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

// MARK: - Event Protocol

/// Represents an auditable event in the system.
///
/// Events carry metadata about what happened, when it happened, and
/// any additional context needed for audit trails.
public protocol AuditEvent: Sendable {
    /// The type of event (e.g., "command.started", "security.encryption")
    var eventType: String { get }
    
    /// When the event occurred
    var timestamp: Date { get }
    
    /// Event-specific metadata (without trace context)
    var eventMetadata: [String: any Sendable] { get }
}

// MARK: - Event Protocol Extensions

public extension AuditEvent {
    /// Complete metadata including automatic trace context enrichment.
    ///
    /// This computed property combines event-specific metadata with
    /// the current trace context (if available), providing a single
    /// source of truth for all audit event metadata.
    var metadata: [String: any Sendable] {
        var enrichedMetadata = eventMetadata
        
        // Automatically include trace context if available
        if let traceContext = AuditContext.current {
            enrichedMetadata["traceId"] = traceContext.traceId.uuidString
            enrichedMetadata["spanId"] = traceContext.spanId.uuidString
            
            // Add user and session if available and not already present
            if let userID = traceContext.userID, enrichedMetadata["userID"] == nil {
                enrichedMetadata["userID"] = userID
            }
            if let sessionId = traceContext.sessionId, enrichedMetadata["sessionId"] == nil {
                enrichedMetadata["sessionId"] = sessionId
            }
        }
        
        return enrichedMetadata
    }
}

// MARK: - Health Monitoring

/// Events that indicate the health status of an audit logger.
public enum LoggerHealthEvent: Sendable {
    /// Events were dropped due to capacity or other constraints
    case dropped(count: Int, reason: String)
    
    /// Logger is experiencing backpressure
    case backpressure(queueDepth: Int)
    
    /// A sink (file, network, etc.) failed
    case sinkFailure(any Error)
    
    /// Logger recovered from a previous issue
    case recovered
}

// MARK: - Trace Context

/// Contextual information for distributed tracing.
///
/// This struct carries trace and span IDs along with user information
/// to correlate events across distributed systems.
public struct TraceContext: Sendable, Equatable {
    /// Unique identifier for the trace
    public let traceId: UUID
    
    /// Unique identifier for the span within the trace
    public let spanId: UUID
    
    /// Optional user identifier
    public let userID: String?
    
    /// Optional session identifier
    public let sessionId: String?
    
    /// Creates a new trace context.
    public init(
        traceId: UUID = UUID(),
        spanId: UUID = UUID(),
        userID: String? = nil,
        sessionId: String? = nil
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.userID = userID
        self.sessionId = sessionId
    }
}

// MARK: - Task-Local Context

/// Task-local storage for audit context.
///
/// This allows trace context to flow implicitly through async call chains
/// without manual propagation at every call site.
public enum AuditContext {
    /// The current trace context for this task
    @TaskLocal public static var current: TraceContext?
}

// MARK: - Context Helpers

public extension AuditContext {
    /// Executes an async operation with the specified trace context.
    ///
    /// - Parameters:
    ///   - context: The trace context to use
    ///   - operation: The async operation to execute
    /// - Returns: The result of the operation
    static func withValue<T>(
        _ context: TraceContext,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await AuditContext.$current.withValue(context, operation: operation)
    }
}
