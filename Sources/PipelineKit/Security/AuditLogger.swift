import Foundation
import os.log

/// A comprehensive audit logging system for tracking command execution.
///
/// Provides:
/// - Command execution tracking with timing
/// - User attribution and metadata capture
/// - Success/failure recording
/// - Structured log output for analysis
/// - Log rotation and persistence options
/// - Privacy-aware logging with data masking
///
/// Example:
/// ```swift
/// let logger = AuditLogger(
///     destination: .file(url: logsURL),
///     privacyLevel: .masked
/// )
/// 
/// let middleware = AuditLoggingMiddleware(logger: logger)
/// ```
public actor AuditLogger {
    private let destination: LogDestination
    private let privacyLevel: PrivacyLevel
    private let encoder = JSONEncoder()
    private let logger = Logger(subsystem: "PipelineKit", category: "Audit")
    private var buffer: [AuditEntry] = []
    private let bufferSize: Int
    private let flushInterval: TimeInterval
    private var lastFlush = Date()
    
    /// Creates an audit logger with specified configuration.
    ///
    /// - Parameters:
    ///   - destination: Where to write audit logs
    ///   - privacyLevel: How to handle sensitive data
    ///   - bufferSize: Number of entries to buffer before writing
    ///   - flushInterval: Time interval for automatic flush
    public init(
        destination: LogDestination,
        privacyLevel: PrivacyLevel = .masked,
        bufferSize: Int = 100,
        flushInterval: TimeInterval = 60.0
    ) {
        self.destination = destination
        self.privacyLevel = privacyLevel
        self.bufferSize = bufferSize
        self.flushInterval = flushInterval
        
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }
    
    // MARK: - Configuration Access
    
    /// The configured log destination.
    nonisolated public var configuredDestination: LogDestination { destination }
    
    /// The configured privacy level for sensitive data handling.
    nonisolated public var configuredPrivacyLevel: PrivacyLevel { privacyLevel }
    
    /// The configured buffer size before automatic flush.
    nonisolated public var configuredBufferSize: Int { bufferSize }
    
    /// The configured time interval for automatic flush.
    nonisolated public var configuredFlushInterval: TimeInterval { flushInterval }
    
    /// Logs a command execution audit entry.
    ///
    /// - Parameter entry: The audit entry to log
    public func log(_ entry: AuditEntry) async {
        let sanitized = sanitizeEntry(entry)
        buffer.append(sanitized)
        
        logger.info("Command executed: \(sanitized.commandType, privacy: .public)")
        
        if buffer.count >= bufferSize || Date().timeIntervalSince(lastFlush) > flushInterval {
            await flush()
        }
    }
    
    /// Forces a flush of buffered entries to the destination.
    public func flush() async {
        guard !buffer.isEmpty else { return }
        
        do {
            switch destination {
            case .console:
                autoreleasepool {
                    for entry in buffer {
                        if let data = try? encoder.encode(entry),
                           let string = String(data: data, encoding: .utf8) {
                            print("AUDIT: \(string)")
                        }
                    }
                }
                
            case let .file(url):
                let entries = buffer
                buffer.removeAll()
                
                try await writeToFile(entries: entries, url: url)
                
            case let .custom(handler):
                let entries = buffer
                buffer.removeAll()
                
                await handler(entries)
            }
            
            lastFlush = Date()
        } catch {
            logger.error("Failed to flush audit logs: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Queries audit logs based on criteria.
    ///
    /// - Parameter criteria: The search criteria
    /// - Returns: Matching audit entries
    public func query(_ criteria: AuditQueryCriteria) async -> [AuditEntry] {
        switch destination {
        case .console:
            return [] // Console logs are not queryable
            
        case let .file(url):
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let entries = try decoder.decode([AuditEntry].self, from: data)
                return autoreleasepool {
                    filterEntries(entries, criteria: criteria)
                }
            } catch {
                logger.error("Failed to query audit logs: \(error.localizedDescription, privacy: .public)")
                return []
            }
            
        case .custom:
            return [] // Custom destinations handle their own querying
        }
    }
    
    // MARK: - Private Methods
    
    private func sanitizeEntry(_ entry: AuditEntry) -> AuditEntry {
        switch privacyLevel {
        case .full:
            return entry
            
        case .masked:
            var sanitized = entry
            sanitized.userId = maskUserId(entry.userId)
            sanitized.metadata = maskMetadata(entry.metadata)
            return sanitized
            
        case .minimal:
            return AuditEntry(
                id: entry.id,
                timestamp: entry.timestamp,
                commandType: entry.commandType,
                userId: "anonymous",
                success: entry.success,
                duration: entry.duration,
                errorType: entry.errorType,
                metadata: [:]
            )
        }
    }
    
    private func maskUserId(_ userId: String) -> String {
        guard userId.count > 4 else { return "***" }
        let prefix = userId.prefix(2)
        let suffix = userId.suffix(2)
        return "\(prefix)***\(suffix)"
    }
    
    private func maskMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.mapValues { value in
            if value.count <= 8 {
                return String(repeating: "*", count: value.count)
            } else {
                let prefix = value.prefix(3)
                let suffix = value.suffix(3)
                return "\(prefix)***\(suffix)"
            }
        }
    }
    
    private func writeToFile(entries: [AuditEntry], url: URL) async throws {
        try autoreleasepool {
            // Read existing entries
            var allEntries: [AuditEntry] = []
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                allEntries = (try? decoder.decode([AuditEntry].self, from: data)) ?? []
            }
            
            // Append new entries
            allEntries.append(contentsOf: entries)
            
            // Write back
            let data = try encoder.encode(allEntries)
            try data.write(to: url, options: .atomic)
            
            // Rotate if needed
            if allEntries.count > 10000 {
                Task {
                    try await rotateLog(at: url, entries: allEntries)
                }
            }
        }
    }
    
    private func rotateLog(at url: URL, entries: [AuditEntry]) async throws {
        try autoreleasepool {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let timestamp = dateFormatter.string(from: Date())
            
            let archiveURL = url.deletingLastPathComponent()
                .appendingPathComponent("audit-\(timestamp).json")
            
            // Move old entries to archive
            let oldEntries = Array(entries.prefix(entries.count - 5000))
            let data = try encoder.encode(oldEntries)
            try data.write(to: archiveURL)
            
            // Keep recent entries
            let recentEntries = Array(entries.suffix(5000))
            let recentData = try encoder.encode(recentEntries)
            try recentData.write(to: url, options: .atomic)
        }
    }
    
    private func filterEntries(_ entries: [AuditEntry], criteria: AuditQueryCriteria) -> [AuditEntry] {
        entries.filter { entry in
            if let startDate = criteria.startDate, entry.timestamp < startDate {
                return false
            }
            if let endDate = criteria.endDate, entry.timestamp > endDate {
                return false
            }
            if let userId = criteria.userId, entry.userId != userId {
                return false
            }
            if let commandType = criteria.commandType, entry.commandType != commandType {
                return false
            }
            if let success = criteria.success, entry.success != success {
                return false
            }
            return true
        }
    }
}

/// Destinations for audit logs.
public enum LogDestination: Sendable {
    /// Log to console output
    case console
    
    /// Log to a file
    case file(url: URL)
    
    /// Custom log handler
    case custom(handler: @Sendable ([AuditEntry]) async -> Void)
}

/// Privacy levels for audit logging.
public enum PrivacyLevel: Sendable {
    /// Log full details
    case full
    
    /// Mask sensitive data
    case masked
    
    /// Log minimal information
    case minimal
}

/// An audit log entry.
public struct AuditEntry: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let commandType: String
    public var userId: String
    public let success: Bool
    public let duration: TimeInterval
    public let errorType: String?
    public var metadata: [String: String]
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        commandType: String,
        userId: String,
        success: Bool,
        duration: TimeInterval,
        errorType: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.commandType = commandType
        self.userId = userId
        self.success = success
        self.duration = duration
        self.errorType = errorType
        self.metadata = metadata
    }
}

/// Criteria for querying audit logs.
public struct AuditQueryCriteria: Sendable {
    public let startDate: Date?
    public let endDate: Date?
    public let userId: String?
    public let commandType: String?
    public let success: Bool?
    
    public init(
        startDate: Date? = nil,
        endDate: Date? = nil,
        userId: String? = nil,
        commandType: String? = nil,
        success: Bool? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.userId = userId
        self.commandType = commandType
        self.success = success
    }
}

/// Middleware for audit logging of command execution.
///
/// Example:
/// ```swift
/// let logger = AuditLogger(destination: .console)
/// let middleware = AuditLoggingMiddleware(logger: logger)
/// 
/// pipeline.use(middleware)
/// ```
public struct AuditLoggingMiddleware: Middleware, PrioritizedMiddleware {
    private let auditLogger: AuditLogger
    private let metadataExtractor: @Sendable (any Command, CommandMetadata) -> [String: String]
    
    nonisolated(unsafe) public static var recommendedOrder: ExecutionPriority { .auditLogging }
    
    /// Creates audit logging middleware.
    ///
    /// - Parameters:
    ///   - logger: The audit logger to use
    ///   - metadataExtractor: Function to extract additional metadata
    public init(
        logger: AuditLogger,
        metadataExtractor: @escaping @Sendable (any Command, CommandMetadata) -> [String: String] = { _, _ in [:] }
    ) {
        self.auditLogger = logger
        self.metadataExtractor = metadataExtractor
    }
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        let commandType = String(describing: T.self)
        let userId = (metadata as? StandardCommandMetadata)?.userId ?? "anonymous"
        let extraMetadata = metadataExtractor(command, metadata)
        
        do {
            let result = try await next(command, metadata)
            
            let entry = AuditEntry(
                commandType: commandType,
                userId: userId,
                success: true,
                duration: Date().timeIntervalSince(startTime),
                metadata: extraMetadata
            )
            
            await auditLogger.log(entry)
            
            return result
        } catch {
            let entry = AuditEntry(
                commandType: commandType,
                userId: userId,
                success: false,
                duration: Date().timeIntervalSince(startTime),
                errorType: String(describing: type(of: error)),
                metadata: extraMetadata
            )
            
            await auditLogger.log(entry)
            
            throw error
        }
    }
}

/// Statistics from audit logs.
public struct AuditStatistics: Sendable {
    public let totalCommands: Int
    public let successCount: Int
    public let failureCount: Int
    public let averageDuration: TimeInterval
    public let commandCounts: [String: Int]
    public let errorCounts: [String: Int]
    public let userActivity: [String: Int]
    
    public var successRate: Double {
        guard totalCommands > 0 else { return 0 }
        return Double(successCount) / Double(totalCommands)
    }
    
    /// Calculates statistics from audit entries.
    public static func calculate(from entries: [AuditEntry]) -> AuditStatistics {
        return autoreleasepool {
            let totalCommands = entries.count
            let successCount = entries.filter { $0.success }.count
            let failureCount = totalCommands - successCount
            
            let totalDuration = entries.reduce(0.0) { $0 + $1.duration }
            let averageDuration = totalCommands > 0 ? totalDuration / Double(totalCommands) : 0
            
            var commandCounts: [String: Int] = [:]
            var errorCounts: [String: Int] = [:]
            var userActivity: [String: Int] = [:]
            
            for entry in entries {
                commandCounts[entry.commandType, default: 0] += 1
                userActivity[entry.userId, default: 0] += 1
                
                if let errorType = entry.errorType {
                    errorCounts[errorType, default: 0] += 1
                }
            }
            
            return AuditStatistics(
                totalCommands: totalCommands,
                successCount: successCount,
                failureCount: failureCount,
                averageDuration: averageDuration,
                commandCounts: commandCounts,
                errorCounts: errorCounts,
                userActivity: userActivity
            )
        }
    }
}