//
//  LoggingEmitter.swift
//  PipelineKit
//
//  Event emitter that logs events using the system logger
//

import Foundation
import PipelineKitCore
@preconcurrency import os

/// An event emitter that logs events to the system logger.
///
/// This emitter uses os.Logger for structured logging on Apple platforms
/// and falls back to print statements on Linux.
///
/// ## Design Decisions
///
/// 1. **Log levels based on event names**: Automatic level selection
/// 2. **Structured logging**: Uses os.Logger privacy features
/// 3. **Non-blocking**: Logging happens synchronously but quickly
/// 4. **Configurable filtering**: Can filter by event name patterns
public struct LoggingEmitter: EventEmitter {
    /// The log level to use for events
    public enum Level: Sendable {
        case debug
        case info
        case notice
        case warning
        case error

        /// Determines level from event name
        static func from(eventName: String) -> Level {
            if eventName.contains("failed") || eventName.contains("error") {
                return .error
            } else if eventName.contains("warning") || eventName.contains("timeout") {
                return .warning
            } else if eventName.contains("started") || eventName.contains("completed") {
                return .info
            } else {
                return .debug
            }
        }
    }

    /// Filter for determining which events to log
    public let filter: (@Sendable (PipelineEvent) -> Bool)?

    /// Minimum level to log
    public let minimumLevel: Level

    #if canImport(OSLog)
    /// The logger instance
    private let logger: Logger
    #endif

    /// Creates a new logging emitter.
    ///
    /// - Parameters:
    ///   - category: Logger category (default: "events")
    ///   - minimumLevel: Minimum level to log (default: .debug)
    ///   - filter: Optional filter for events
    public init(
        category: String = "events",
        minimumLevel: Level = .debug,
        filter: (@Sendable (PipelineEvent) -> Bool)? = nil
    ) {
        self.minimumLevel = minimumLevel
        self.filter = filter

        #if canImport(OSLog)
        self.logger = Logger(subsystem: "com.pipelinekit", category: category)
        #endif
    }

    public func emit(_ event: PipelineEvent) {
        // Apply filter if configured
        if let filter = filter, !filter(event) {
            return
        }

        let level = Level.from(eventName: event.name)

        // Check minimum level
        if !shouldLog(level: level) {
            return
        }

        #if canImport(OSLog)
        logWithOSLog(event: event, level: level)
        #else
        logWithPrint(event: event, level: level)
        #endif
    }

    #if canImport(OSLog)
    private func logWithOSLog(event: PipelineEvent, level: Level) {
        let propertiesString = formatProperties(event.properties)

        switch level {
        case .debug:
            logger.debug("""
                Event: \(event.name, privacy: .public)
                CorrelationID: \(event.correlationID, privacy: .public)
                Properties: \(propertiesString, privacy: .private)
                """)
        case .info:
            logger.info("""
                Event: \(event.name, privacy: .public)
                CorrelationID: \(event.correlationID, privacy: .public)
                Properties: \(propertiesString, privacy: .private)
                """)
        case .notice:
            logger.notice("""
                Event: \(event.name, privacy: .public)
                CorrelationID: \(event.correlationID, privacy: .public)
                Properties: \(propertiesString, privacy: .private)
                """)
        case .warning:
            logger.warning("""
                Event: \(event.name, privacy: .public)
                CorrelationID: \(event.correlationID, privacy: .public)
                Properties: \(propertiesString, privacy: .private)
                """)
        case .error:
            logger.error("""
                Event: \(event.name, privacy: .public)
                CorrelationID: \(event.correlationID, privacy: .public)
                Properties: \(propertiesString, privacy: .private)
                """)
        }
    }
    #endif

    private func logWithPrint(event: PipelineEvent, level: Level) {
        let levelString = levelString(for: level)
        let propertiesString = formatProperties(event.properties)

        print("""
            [\(levelString)] Event: \(event.name)
            CorrelationID: \(event.correlationID)
            SequenceID: \(event.sequenceID)
            Properties: \(propertiesString)
            """)
    }

    private func formatProperties(_ properties: [String: AnySendable]) -> String {
        if properties.isEmpty {
            return "{}"
        }

        let items = properties.map { key, value in
            "\(key): \(value)"
        }.joined(separator: ", ")

        return "{ \(items) }"
    }

    private func shouldLog(level: Level) -> Bool {
        switch (minimumLevel, level) {
        case (.debug, _):
            return true
        case (.info, .info), (.info, .notice), (.info, .warning), (.info, .error):
            return true
        case (.notice, .notice), (.notice, .warning), (.notice, .error):
            return true
        case (.warning, .warning), (.warning, .error):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }

    private func levelString(for level: Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        }
    }
}

// MARK: - Convenience Initializers

public extension LoggingEmitter {
    /// Creates a logging emitter for command events.
    static func commands(minimumLevel: Level = .info) -> LoggingEmitter {
        LoggingEmitter(
            category: "commands",
            minimumLevel: minimumLevel,
            filter: { $0.name.hasPrefix("command.") }
        )
    }

    /// Creates a logging emitter for middleware events.
    static func middleware(minimumLevel: Level = .debug) -> LoggingEmitter {
        LoggingEmitter(
            category: "middleware",
            minimumLevel: minimumLevel,
            filter: { $0.name.hasPrefix("middleware.") }
        )
    }

    /// Creates a logging emitter for error events only.
    static func errors() -> LoggingEmitter {
        LoggingEmitter(
            category: "errors",
            minimumLevel: .error,
            filter: { $0.name.contains("failed") || $0.name.contains("error") }
        )
    }
}
