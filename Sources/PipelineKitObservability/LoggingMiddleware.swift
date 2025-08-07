import Foundation
import PipelineKitCore
import OSLog

/// Middleware that provides structured logging for command execution
///
/// This middleware logs command execution lifecycle events including:
/// - Command start with metadata
/// - Command completion with results
/// - Command failures with error details
/// - Performance metrics
///
/// ## Example Usage
/// ```swift
/// let middleware = LoggingMiddleware(
///     logLevel: .info,
///     includeCommandDetails: true,
///     includeResult: false
/// )
/// pipeline.use(middleware)
/// ```
public struct LoggingMiddleware: Middleware {
    public let priority: ExecutionPriority = .postProcessing
    
    // MARK: - Configuration
    
    public struct Configuration: Sendable {
        /// Minimum log level for logging events
        public let logLevel: LogLevel
        
        /// Whether to include command details in logs
        public let includeCommandDetails: Bool
        
        /// Whether to include command results in logs
        public let includeResult: Bool
        
        /// Whether to include context metadata in logs
        public let includeMetadata: Bool
        
        /// Whether to log performance metrics
        public let logPerformance: Bool
        
        /// Custom log formatter
        public let formatter: LogFormatter?
        
        public init(
            logLevel: LogLevel = .info,
            includeCommandDetails: Bool = true,
            includeResult: Bool = false,
            includeMetadata: Bool = true,
            logPerformance: Bool = true,
            formatter: LogFormatter? = nil
        ) {
            self.logLevel = logLevel
            self.includeCommandDetails = includeCommandDetails
            self.includeResult = includeResult
            self.includeMetadata = includeMetadata
            self.logPerformance = logPerformance
            self.formatter = formatter
        }
    }
    
    private let configuration: Configuration
    private let logger: Logger?
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        
        if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
            self.logger = Logger(
                subsystem: "com.pipelinekit.middleware",
                category: "LoggingMiddleware"
            )
        } else {
            self.logger = nil
        }
    }
    
    public init(
        logLevel: LogLevel = .info,
        includeCommandDetails: Bool = true,
        includeResult: Bool = false
    ) {
        self.init(
            configuration: Configuration(
                logLevel: logLevel,
                includeCommandDetails: includeCommandDetails,
                includeResult: includeResult
            )
        )
    }
    
    // MARK: - Middleware Implementation
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        let commandType = String(describing: type(of: command))
        let requestId = context.metadata["request_id"] as? String ?? UUID().uuidString
        
        // Ensure request ID is set
        if context.metadata["request_id"] == nil {
            context.metadata["request_id"] = requestId
        }
        
        // Log command start
        logCommandStart(
            commandType: commandType,
            requestId: requestId,
            command: command,
            context: context
        )
        
        do {
            // Execute command
            let result = try await next(command, context)
            
            // Log success
            let duration = Date().timeIntervalSince(startTime)
            logCommandSuccess(
                commandType: commandType,
                requestId: requestId,
                result: result,
                duration: duration,
                context: context
            )
            
            return result
        } catch {
            // Log failure
            let duration = Date().timeIntervalSince(startTime)
            logCommandFailure(
                commandType: commandType,
                requestId: requestId,
                error: error,
                duration: duration,
                context: context
            )
            
            throw error
        }
    }
    
    // MARK: - Private Logging Methods
    
    private func logCommandStart<T: Command>(
        commandType: String,
        requestId: String,
        command: T,
        context: CommandContext
    ) {
        guard configuration.logLevel <= .info else { return }
        
        if let formatter = configuration.formatter {
            let message = formatter.formatCommandStart(
                commandType: commandType,
                requestId: requestId,
                command: command,
                context: context
            )
            log(level: .info, message: message)
        } else {
            var details = "type=\(commandType) request_id=\(requestId)"
            
            if configuration.includeCommandDetails {
                details += " command=\(command)"
            }
            
            if configuration.includeMetadata {
                let metadata = context.metadata.compactMapValues { $0 }
                if !metadata.isEmpty {
                    details += " metadata=\(metadata)"
                }
            }
            
            log(level: .info, message: "Command started: \(details)")
        }
    }
    
    private func logCommandSuccess<R>(
        commandType: String,
        requestId: String,
        result: R,
        duration: TimeInterval,
        context: CommandContext
    ) {
        guard configuration.logLevel <= .info else { return }
        
        if let formatter = configuration.formatter {
            let message = formatter.formatCommandSuccess(
                commandType: commandType,
                requestId: requestId,
                result: result,
                duration: duration,
                context: context
            )
            log(level: .info, message: message)
        } else {
            var details = "type=\(commandType) request_id=\(requestId)"
            
            if configuration.logPerformance {
                details += String(format: " duration=%.3fms", duration * 1000)
            }
            
            if configuration.includeResult {
                details += " result=\(result)"
            }
            
            if configuration.includeMetadata {
                let metrics = context.metrics
                if !metrics.isEmpty {
                    details += " metrics=\(metrics)"
                }
            }
            
            log(level: .info, message: "Command completed: \(details)")
        }
    }
    
    private func logCommandFailure(
        commandType: String,
        requestId: String,
        error: Error,
        duration: TimeInterval,
        context: CommandContext
    ) {
        let level: LogLevel = error is PipelineError ? .error : .error
        guard configuration.logLevel <= level else { return }
        
        if let formatter = configuration.formatter {
            let message = formatter.formatCommandFailure(
                commandType: commandType,
                requestId: requestId,
                error: error,
                duration: duration,
                context: context
            )
            log(level: level, message: message)
        } else {
            var details = "type=\(commandType) request_id=\(requestId)"
            
            if configuration.logPerformance {
                details += String(format: " duration=%.3fms", duration * 1000)
            }
            
            details += " error=\(error)"
            
            if configuration.includeMetadata {
                let metadata = context.metadata.compactMapValues { $0 }
                if !metadata.isEmpty {
                    details += " metadata=\(metadata)"
                }
            }
            
            log(level: level, message: "Command failed: \(details)")
        }
    }
    
    private func log(level: LogLevel, message: String) {
        if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
            guard let logger = logger else { return }
            
            switch level {
            case .debug:
                logger.debug("\(message)")
            case .info:
                logger.info("\(message)")
            case .notice:
                logger.notice("\(message)")
            case .error:
                logger.error("\(message)")
            case .fault:
                logger.fault("\(message)")
            }
        } else {
            // Fallback for older OS versions
            print("[\(level)] \(message)")
        }
    }
}

// MARK: - Log Formatter Protocol

/// Protocol for custom log formatting
public protocol LogFormatter: Sendable {
    func formatCommandStart<T: Command>(
        commandType: String,
        requestId: String,
        command: T,
        context: CommandContext
    ) -> String
    
    func formatCommandSuccess<R>(
        commandType: String,
        requestId: String,
        result: R,
        duration: TimeInterval,
        context: CommandContext
    ) -> String
    
    func formatCommandFailure(
        commandType: String,
        requestId: String,
        error: Error,
        duration: TimeInterval,
        context: CommandContext
    ) -> String
}

// MARK: - JSON Log Formatter

/// Codable log entry types for type-safe JSON encoding
private struct CommandStartLogEntry: Codable {
    let event: String
    let commandType: String
    let requestId: String
    let timestamp: Date
    let metadata: [String: String]
    
    enum CodingKeys: String, CodingKey {
        case event
        case commandType = "command_type"
        case requestId = "request_id"
        case timestamp
        case metadata
    }
}

private struct CommandSuccessLogEntry: Codable {
    let event: String
    let commandType: String
    let requestId: String
    let durationMs: Double
    let timestamp: Date
    let metrics: [String: Double]
    
    enum CodingKeys: String, CodingKey {
        case event
        case commandType = "command_type"
        case requestId = "request_id"
        case durationMs = "duration_ms"
        case timestamp
        case metrics
    }
}

private struct CommandFailureLogEntry: Codable {
    let event: String
    let commandType: String
    let requestId: String
    let durationMs: Double
    let error: String
    let errorType: String
    let timestamp: Date
    let metadata: [String: String]
    
    enum CodingKeys: String, CodingKey {
        case event
        case commandType = "command_type"
        case requestId = "request_id"
        case durationMs = "duration_ms"
        case error
        case errorType = "error_type"
        case timestamp
        case metadata
    }
}

/// A log formatter that outputs structured JSON logs
public struct JSONLogFormatter: LogFormatter {
    private let encoder: JSONEncoder
    
    public init() {
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }
    
    public func formatCommandStart<T: Command>(
        commandType: String,
        requestId: String,
        command: T,
        context: CommandContext
    ) -> String {
        let logEntry = CommandStartLogEntry(
            event: "command_start",
            commandType: commandType,
            requestId: requestId,
            timestamp: Date(),
            metadata: convertMetadataToStrings(context.metadata)
        )
        
        do {
            let data = try encoder.encode(logEntry)
            return String(data: data, encoding: .utf8)!
        } catch {
            // Log to stderr to avoid recursion
            FileHandle.standardError.write(
                Data("JSONLogFormatter.formatCommandStart encoding error: \(error)\n".utf8)
            )
            return #"{"error":"encoding_failed","event":"command_start","type":"\#(String(describing: type(of: error)))"}"#
        }
    }
    
    public func formatCommandSuccess<R>(
        commandType: String,
        requestId: String,
        result: R,
        duration: TimeInterval,
        context: CommandContext
    ) -> String {
        let logEntry = CommandSuccessLogEntry(
            event: "command_success",
            commandType: commandType,
            requestId: requestId,
            durationMs: duration * 1000,
            timestamp: Date(),
            metrics: convertMetricsToDoubles(context.metrics)
        )
        
        do {
            let data = try encoder.encode(logEntry)
            return String(data: data, encoding: .utf8)!
        } catch {
            // Log to stderr to avoid recursion
            FileHandle.standardError.write(
                Data("JSONLogFormatter.formatCommandSuccess encoding error: \(error)\n".utf8)
            )
            return #"{"error":"encoding_failed","event":"command_success","type":"\#(String(describing: type(of: error)))"}"#
        }
    }
    
    public func formatCommandFailure(
        commandType: String,
        requestId: String,
        error: Error,
        duration: TimeInterval,
        context: CommandContext
    ) -> String {
        let logEntry = CommandFailureLogEntry(
            event: "command_failure",
            commandType: commandType,
            requestId: requestId,
            durationMs: duration * 1000,
            error: String(describing: error),
            errorType: String(describing: type(of: error)),
            timestamp: Date(),
            metadata: convertMetadataToStrings(context.metadata)
        )
        
        do {
            let data = try encoder.encode(logEntry)
            return String(data: data, encoding: .utf8)!
        } catch {
            // Log to stderr to avoid recursion
            FileHandle.standardError.write(
                Data("JSONLogFormatter.formatCommandFailure encoding error: \(error)\n".utf8)
            )
            return #"{"error":"encoding_failed","event":"command_failure","type":"\#(String(describing: type(of: error)))"}"#
        }
    }
    
    // Helper functions to convert Sendable values to Codable types
    private func convertMetadataToStrings(_ metadata: [String: any Sendable]) -> [String: String] {
        metadata.compactMapValues { value in
            switch value {
            case let string as String:
                return string
            case let bool as Bool:
                return String(bool)
            case let int as Int:
                return String(int)
            case let double as Double:
                return String(double)
            case let date as Date:
                return ISO8601DateFormatter().string(from: date)
            default:
                return String(describing: value)
            }
        }
    }
    
    private func convertMetricsToDoubles(_ metrics: [String: any Sendable]) -> [String: Double] {
        metrics.compactMapValues { value in
            switch value {
            case let double as Double:
                return double
            case let int as Int:
                return Double(int)
            case let float as Float:
                return Double(float)
            default:
                return nil
            }
        }
    }
}