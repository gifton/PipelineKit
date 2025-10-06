//
//  LoggingEmitter.swift
//  PipelineKit
//
//  Event emitter that logs events using the system logger
//

import Foundation
import PipelineKitCore
#if canImport(OSLog)
@preconcurrency import os
#endif

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
        let indicator = visualIndicator(for: event.name)
        let shortID = shortenUUID(event.correlationID)
        let commandType = extractCommandType(event.properties) ?? event.name
        let propertiesString = formatProperties(event.properties)

        // Format: [LEVEL] indicator commandType | shortID | properties
        let message: String
        if propertiesString.isEmpty {
            message = "\(indicator) \(commandType) | \(shortID)"
        } else {
            message = "\(indicator) \(commandType) | \(shortID) | \(propertiesString)"
        }

        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
    #endif

    private func logWithPrint(event: PipelineEvent, level: Level) {
        let levelString = levelString(for: level)
        let indicator = visualIndicator(for: event.name)
        let shortID = shortenUUID(event.correlationID)
        let commandType = extractCommandType(event.properties) ?? event.name
        let propertiesString = formatProperties(event.properties)

        // Format: [LEVEL] indicator commandType | shortID | properties
        if propertiesString.isEmpty {
            print("[\(levelString)] \(indicator) \(commandType) | \(shortID)")
        } else {
            print("[\(levelString)] \(indicator) \(commandType) | \(shortID) | \(propertiesString)")
        }
    }

    private func formatProperties(_ properties: [String: AnySendable]) -> String {
        if properties.isEmpty {
            return ""
        }

        let items = properties.compactMap { key, value -> String? in
            // Skip redundant source field
            guard key != "source" else { return nil }

            let unwrapped = unwrapValue(value)
            return "\(key)=\(unwrapped)"
        }.joined(separator: " ")

        return items
    }

    /// Unwraps AnySendable to get the actual value without nested wrappers
    private func unwrapValue(_ value: AnySendable) -> String {
        // Try different common types in order of likelihood

        // String
        if let string: String = value.get() {
            return string.contains(" ") ? "\"\(string)\"" : string
        }

        // Date - format as time
        if let date: Date = value.get() {
            return formatTime(date)
        }

        // Double - check if it's a duration
        if let duration: Double = value.get() {
            return String(format: "%.3fs", duration)
        }

        // Bool
        if let bool: Bool = value.get() {
            return bool ? "true" : "false"
        }

        // Int variants
        if let int: Int = value.get() {
            return "\(int)"
        }

        if let int64: Int64 = value.get() {
            return "\(int64)"
        }

        if let uint: UInt = value.get() {
            return "\(uint)"
        }

        if let uint64: UInt64 = value.get() {
            return "\(uint64)"
        }

        // Float
        if let float: Float = value.get() {
            return String(format: "%.3f", float)
        }

        // UUID
        if let uuid: UUID = value.get() {
            return shortenUUID(uuid.uuidString)
        }

        // Nested AnySendable (recursive unwrap)
        if let nested: AnySendable = value.get() {
            return unwrapValue(nested)
        }

        // Fallback to description (will show AnySendable(...) if nothing matched)
        return String(describing: value)
            .replacingOccurrences(of: "AnySendable(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    /// Shortens a UUID to first 8 characters
    private func shortenUUID(_ uuid: String) -> String {
        String(uuid.prefix(8))
    }

    /// Formats a time as HH:mm:ss
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Returns a visual indicator based on event name
    private func visualIndicator(for eventName: String) -> String {
        if eventName.contains("started") {
            return "▶"
        } else if eventName.contains("completed") {
            return "✓"
        } else if eventName.contains("failed") || eventName.contains("error") {
            return "✗"
        } else {
            return "•"
        }
    }

    /// Extracts command type from properties
    private func extractCommandType(_ properties: [String: AnySendable]) -> String? {
        guard let commandType = properties["command_type"] else { return nil }

        let value = unwrapValue(commandType)
        // Remove "AnySendable(" wrapper if present
        let cleaned = value
            .replacingOccurrences(of: "AnySendable(", with: "")
            .replacingOccurrences(of: ")", with: "")
        return cleaned
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
