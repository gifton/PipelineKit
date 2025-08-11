import Foundation
import PipelineKitCore

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
///     logger: FileAuditLogger(directory: "/var/log/audit"),
///     detailLevel: .full,
///     includeResults: true
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
/// - SeeAlso: `AuditLogger`, `AuditEntry`, `Middleware`
public struct AuditLoggingMiddleware: Middleware {
    /// Priority ensures audit logging happens at the right time.
    public let priority: ExecutionPriority = .monitoring
    
    /// The audit logger implementation.
    private let logger: any AuditLogger
    
    /// Level of detail to include in audit logs.
    private let detailLevel: AuditDetailLevel
    
    /// Whether to include command results in audit logs.
    private let includeResults: Bool
    
    /// Whether to include sensitive data in logs.
    private let includeSensitiveData: Bool
    
    /// Fields to redact from audit logs.
    private let redactedFields: Set<String>
    
    /// Creates a new audit logging middleware.
    ///
    /// - Parameters:
    ///   - logger: The audit logger implementation
    ///   - detailLevel: How much detail to include in logs
    ///   - includeResults: Whether to log command results
    ///   - includeSensitiveData: Whether to include potentially sensitive data
    ///   - redactedFields: Field names to redact from logs
    public init(
        logger: any AuditLogger,
        detailLevel: AuditDetailLevel = .standard,
        includeResults: Bool = false,
        includeSensitiveData: Bool = false,
        redactedFields: Set<String> = ["password", "token", "secret", "key", "ssn", "creditCard"]
    ) {
        self.logger = logger
        self.detailLevel = detailLevel
        self.includeResults = includeResults
        self.includeSensitiveData = includeSensitiveData
        self.redactedFields = redactedFields
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
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        let commandId = UUID()
        
        // Create initial audit entry
        let entry = AuditEntry(
            id: commandId,
            timestamp: startTime,
            commandType: String(describing: type(of: command)),
            userId: context.metadata["authUserId"] as? String,
            sessionId: context.metadata["sessionId"] as? String,
            ipAddress: context.metadata["ipAddress"] as? String,
            userAgent: context.metadata["userAgent"] as? String,
            commandData: detailLevel.includesCommandData ? sanitizeCommand(command) : nil,
            contextMetadata: detailLevel.includesContext ? sanitizeContext(context) : nil
        )
        
        // Log command start
        await logger.log(.commandStarted(entry))
        
        do {
            // Execute command
            let result = try await next(command, context)
            
            // Log successful completion
            let duration = Date().timeIntervalSince(startTime)
            var completedEntry = entry
            completedEntry.duration = duration
            completedEntry.status = .success
            
            if includeResults && detailLevel.includesResults {
                completedEntry.result = sanitizeResult(result)
            }
            
            await logger.log(.commandCompleted(completedEntry))
            
            return result
            
        } catch {
            // Log failure
            let duration = Date().timeIntervalSince(startTime)
            var failedEntry = entry
            failedEntry.duration = duration
            failedEntry.status = .failure
            failedEntry.error = sanitizeError(error)
            
            await logger.log(.commandFailed(failedEntry))
            
            throw error
        }
    }
    
    // MARK: - Private Methods
    
    private func sanitizeCommand<T: Command>(_ command: T) -> [String: any Sendable] {
        // Convert command to dictionary representation
        // In production, this would use reflection or Codable
        var data: [String: any Sendable] = [
            "type": String(describing: type(of: command))
        ]
        
        // Add command properties if available
        if let metadata = command as? MetadataProviding {
            for (key, value) in metadata.metadata {
                data[key] = value
            }
        }
        
        return redactSensitiveFields(data)
    }
    
    private func sanitizeContext(_ context: CommandContext) -> [String: any Sendable] {
        var metadata: [String: any Sendable] = [:]
        
        // Convert from [String: any Sendable] to [String: Any]
        for (key, value) in context.metadata {
            metadata[key] = value
        }
        
        // Remove sensitive context data if configured
        if !includeSensitiveData {
            for field in redactedFields {
                metadata[field] = "[REDACTED]"
            }
        }
        
        return metadata
    }
    
    private func sanitizeResult<T>(_ result: T) -> [String: any Sendable] {
        // Convert result to safe representation
        var data: [String: any Sendable] = [
            "type": String(describing: type(of: result))
        ]
        
        // Add result properties if available
        if let metadata = result as? MetadataProviding {
            for (key, value) in metadata.metadata {
                data[key] = value
            }
        }
        
        return redactSensitiveFields(data)
    }
    
    private func sanitizeError(_ error: Error) -> [String: any Sendable] {
        return [
            "type": String(describing: type(of: error)),
            "description": error.localizedDescription,
            "domain": (error as NSError).domain,
            "code": (error as NSError).code
        ]
    }
    
    private func redactSensitiveFields(_ data: [String: any Sendable]) -> [String: any Sendable] {
        var sanitized = data
        
        for field in redactedFields {
            if sanitized[field] != nil {
                sanitized[field] = "[REDACTED]"
            }
        }
        
        return sanitized
    }
}

// MARK: - Supporting Types

/// Level of detail for audit logging.
public enum AuditDetailLevel: Sendable {
    /// Minimal logging (command type and outcome only)
    case minimal
    
    /// Standard logging (includes user and basic metadata)
    case standard
    
    /// Full logging (includes command data and context)
    case full
    
    /// Custom configuration
    case custom(includesCommandData: Bool, includesContext: Bool, includesResults: Bool)
    
    var includesCommandData: Bool {
        switch self {
        case .minimal: return false
        case .standard: return false
        case .full: return true
        case .custom(let includes, _, _): return includes
        }
    }
    
    var includesContext: Bool {
        switch self {
        case .minimal: return false
        case .standard: return true
        case .full: return true
        case .custom(_, let includes, _): return includes
        }
    }
    
    var includesResults: Bool {
        switch self {
        case .minimal: return false
        case .standard: return false
        case .full: return true
        case .custom(_, _, let includes): return includes
        }
    }
}

/// An audit log entry.
public struct AuditEntry: Sendable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let commandType: String
    public let userId: String?
    public let sessionId: String?
    public let ipAddress: String?
    public let userAgent: String?
    public var duration: TimeInterval?
    public var status: ExecutionStatus?
    public var commandData: [String: any Sendable]?
    public var contextMetadata: [String: any Sendable]?
    public var result: [String: any Sendable]?
    public var error: [String: any Sendable]?
    
    public enum ExecutionStatus: String, Codable, Sendable {
        case started
        case success
        case failure
    }
    
    // Custom Codable implementation to handle Any types
    enum CodingKeys: String, CodingKey {
        case id, timestamp, commandType, userId, sessionId
        case ipAddress, userAgent, duration, status
    }
    
    public init(
        id: UUID,
        timestamp: Date,
        commandType: String,
        userId: String? = nil,
        sessionId: String? = nil,
        ipAddress: String? = nil,
        userAgent: String? = nil,
        duration: TimeInterval? = nil,
        status: ExecutionStatus? = nil,
        commandData: [String: any Sendable]? = nil,
        contextMetadata: [String: any Sendable]? = nil,
        result: [String: any Sendable]? = nil,
        error: [String: any Sendable]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.commandType = commandType
        self.userId = userId
        self.sessionId = sessionId
        self.ipAddress = ipAddress
        self.userAgent = userAgent
        self.duration = duration
        self.status = status
        self.commandData = commandData
        self.contextMetadata = contextMetadata
        self.result = result
        self.error = error
    }
}

// SecurityAuditEvent is defined in AuditLogger.swift

/// Audit event types.
public enum AuditEvent: Sendable {
    case commandStarted(AuditEntry)
    case commandCompleted(AuditEntry)
    case commandFailed(AuditEntry)
    case securityEvent(SecurityAuditEvent)
}

/// Extended audit logger protocol.
public extension AuditLogger {
    func log(_ event: AuditEvent) async {
        switch event {
        case .commandStarted(let entry):
            await logCommandStarted(entry)
        case .commandCompleted(let entry):
            await logCommandCompleted(entry)
        case .commandFailed(let entry):
            await logCommandFailed(entry)
        case .securityEvent(let event):
            await log(event)
        }
    }
    
    func logCommandStarted(_ entry: AuditEntry) async {
        // Default implementation
    }
    
    func logCommandCompleted(_ entry: AuditEntry) async {
        // Default implementation
    }
    
    func logCommandFailed(_ entry: AuditEntry) async {
        // Default implementation
    }
}


// MARK: - File-based Audit Logger

/// Simple file-based audit logger implementation.
public actor FileAuditLogger: AuditLogger {
    private let directory: URL
    private let dateFormatter: ISO8601DateFormatter
    
    public init(directory: String) {
        self.directory = URL(fileURLWithPath: directory)
        self.dateFormatter = ISO8601DateFormatter()
        
        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }
    
    public func log(_ event: SecurityAuditEvent) async {
        let entry = createSecurityEntry(event)
        await writeEntry(entry)
    }
    
    public func logCommandStarted(_ entry: AuditEntry) async {
        await writeEntry(entry)
    }
    
    public func logCommandCompleted(_ entry: AuditEntry) async {
        await writeEntry(entry)
    }
    
    public func logCommandFailed(_ entry: AuditEntry) async {
        await writeEntry(entry)
    }
    
    private func writeEntry(_ entry: AuditEntry) async {
        let filename = "\(dateFormatter.string(from: Date())).audit.ndjson"
        let fileURL = directory.appendingPathComponent(filename)
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // For ND-JSON, we want compact single-line JSON
            encoder.outputFormatting = [.sortedKeys]
            
            var data = try encoder.encode(entry)
            // Add newline for ND-JSON format
            data.append("\n".data(using: .utf8)!)
            
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Append to existing file with proper error handling
                let fileHandle = try FileHandle(forWritingTo: fileURL)
                defer { 
                    // Ensure file handle is always closed
                    do {
                        try fileHandle.close()
                    } catch {
                        // Log close error but don't propagate
                        FileHandle.standardError.write("Failed to close audit log file: \(error)\n".data(using: .utf8)!)
                    }
                }
                try fileHandle.seekToEnd()
                fileHandle.write(data)
            } else {
                // Create new file
                try data.write(to: fileURL)
            }
        } catch {
            // Log to stderr as fallback
            FileHandle.standardError.write("Audit logging failed: \(error)\n".data(using: .utf8)!)
        }
    }
    
    private func createSecurityEntry(_ event: SecurityAuditEvent) -> AuditEntry {
        AuditEntry(
            id: UUID(),
            timestamp: Date(),
            commandType: "SecurityEvent",
            commandData: ["event": String(describing: event)]
        )
    }
}

// FileHandle extensions moved to avoid global state issues