import Foundation
import PipelineKit

/// Middleware that provides comprehensive audit logging for command execution.
///
/// This middleware creates an immutable audit trail of all commands executed
/// through the pipeline, including who executed them, when, and what the outcomes were.
///
/// ## Overview
///
/// The audit logging middleware:
/// - Records all command executions with timestamps
/// - Captures user identity and context
/// - Logs both successful and failed executions
/// - Provides configurable detail levels
/// - Supports multiple audit destinations
///
/// ## Usage
///
/// ```swift
/// let auditMiddleware = AuditLoggingMiddleware(
///     logger: ConsoleAuditLogger.production
/// )
///
/// let pipeline = StandardPipeline(
///     handler: handler,
///     middleware: [auditMiddleware, ...]
/// )
/// ```
///
/// ## Compliance
///
/// This middleware helps meet compliance requirements for:
/// - SOC 2 Type II
/// - HIPAA
/// - PCI DSS
/// - GDPR Article 30
///
/// - Note: This middleware has `.monitoring` priority to capture events
///   after authentication/authorization but before main processing.
///
/// - SeeAlso: `AuditLogger`, `CommandLifecycleEvent`, `Middleware`
public struct AuditLoggingMiddleware: Middleware {
    /// Priority ensures audit logging happens at the right time.
    public let priority: ExecutionPriority = .monitoring
    
    /// The audit logger implementation.
    private let logger: any AuditLogger
    
    /// Creates a new audit logging middleware.
    ///
    /// - Parameter logger: The audit logger implementation to use
    public init(logger: any AuditLogger) {
        self.logger = logger
    }
    
    /// Executes audit logging around command processing.
    ///
    /// - Parameters:
    ///   - command: The command being executed
    ///   - context: The command context
    ///   - next: The next handler in the chain
    ///
    /// - Returns: The result from the command execution chain
    ///
    /// - Throws: Any error from the downstream chain (audit logging never throws)
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        let commandId = UUID()
        let commandType = String(describing: type(of: command))
        
        // Extract user and session info from context
        let metadata = context.getMetadata()
        let userId = metadata["authUserId"] as? String
        let sessionId = metadata["sessionId"] as? String
        
        // Check if we already have a trace context
        if AuditContext.current != nil {
            // Already in a trace context, just execute
            // Log command start
            let startEvent = CommandLifecycleEvent(
                phase: .started,
                commandType: commandType,
                commandId: commandId,
                userID: userId,
                sessionId: sessionId
            )
            await logger.log(startEvent)
            
            do {
                // Execute command
                let result = try await next(command, context)
                
                // Log successful completion
                let duration = Date().timeIntervalSince(startTime)
                let completeEvent = CommandLifecycleEvent(
                    phase: .completed,
                    commandType: commandType,
                    commandId: commandId,
                    userID: userId,
                    sessionId: sessionId,
                    duration: duration
                )
                await logger.log(completeEvent)
                
                return result
            } catch {
                // Log failure
                let duration = Date().timeIntervalSince(startTime)
                let failedEvent = CommandLifecycleEvent(
                    phase: .failed,
                    commandType: commandType,
                    commandId: commandId,
                    userID: userId,
                    sessionId: sessionId,
                    duration: duration,
                    error: String(describing: error)
                )
                await logger.log(failedEvent)
                
                throw error
            }
        } else {
            // Create a new trace context
            let traceContext = TraceContext(
                traceId: UUID(),
                spanId: commandId,
                userID: userId,
                sessionId: sessionId
            )
            
            // Execute within the new trace context
            return try await AuditContext.withValue(traceContext) {
                // Log command start
                let startEvent = CommandLifecycleEvent(
                    phase: .started,
                    commandType: commandType,
                    commandId: commandId,
                    userID: userId,
                    sessionId: sessionId
                )
                await logger.log(startEvent)
                
                do {
                    // Execute command
                    let result = try await next(command, context)
                    
                    // Log successful completion
                    let duration = Date().timeIntervalSince(startTime)
                    let completeEvent = CommandLifecycleEvent(
                        phase: .completed,
                        commandType: commandType,
                        commandId: commandId,
                        userID: userId,
                        sessionId: sessionId,
                        duration: duration
                    )
                    await logger.log(completeEvent)
                    
                    return result
                } catch {
                    // Log failure
                    let duration = Date().timeIntervalSince(startTime)
                    let failedEvent = CommandLifecycleEvent(
                        phase: .failed,
                        commandType: commandType,
                        commandId: commandId,
                        userID: userId,
                        sessionId: sessionId,
                        duration: duration,
                        error: String(describing: error)
                    )
                    await logger.log(failedEvent)
                    
                    throw error
                }
            }
        }
    }
}
