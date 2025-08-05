import Foundation
import XCTest

// NOTE: This file requires PipelineKitStressTest types which have been
// moved to a separate package. It should be moved to that package's test suite.
/*
/// Logging interface for test infrastructure.
///
/// TestLogger provides a configurable logging system for the test framework,
/// allowing different log levels, output destinations, and formatting options.
///
/// ## Example
/// ```swift
/// let logger = TestLogger(level: .debug)
/// logger.debug("Starting test execution")
/// logger.info("Test scenario: \(scenario.name)")
/// logger.error("Test failed", error: error)
/// ```
public protocol TestLoggerProtocol: Sendable {
    /// The minimum log level for messages to be recorded
    var level: LogLevel { get set }
    
    /// Log a debug message
    func debug(_ message: @autoclosure () -> String, file: String, function: String, line: Int)
    
    /// Log an info message
    func info(_ message: @autoclosure () -> String, file: String, function: String, line: Int)
    
    /// Log a warning message
    func warning(_ message: @autoclosure () -> String, file: String, function: String, line: Int)
    
    /// Log an error message
    func error(_ message: @autoclosure () -> String, error: Error?, file: String, function: String, line: Int)
    
    /// Log a message with a specific level
    func log(level: LogLevel, _ message: @autoclosure () -> String, file: String, function: String, line: Int)
}

/// Log levels for test infrastructure
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case none = 4
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var symbol: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .none: return ""
        }
    }
    
    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .none: return ""
        }
    }
}

/// Default test logger implementation
public actor TestLogger: TestLoggerProtocol {
    
    // MARK: - Properties
    
    public var level: LogLevel
    private let formatter: LogFormatter
    private let output: LogOutput
    private var buffer: [LogEntry] = []
    private let maxBufferSize: Int
    
    // MARK: - Initialization
    
    public init(
        level: LogLevel = .info,
        formatter: LogFormatter? = nil,
        output: LogOutput? = nil,
        maxBufferSize: Int = 1000
    ) {
        self.level = level
        self.formatter = formatter ?? DefaultLogFormatter()
        self.output = output ?? ConsoleLogOutput()
        self.maxBufferSize = maxBufferSize
    }
    
    // MARK: - Logging Methods
    
    public func debug(
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .debug, message(), file: file, function: function, line: line)
    }
    
    public func info(
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .info, message(), file: file, function: function, line: line)
    }
    
    public func warning(
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .warning, message(), file: file, function: function, line: line)
    }
    
    public func error(
        _ message: @autoclosure () -> String,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var fullMessage = message()
        if let error = error {
            fullMessage += " - Error: \(error.localizedDescription)"
        }
        log(level: .error, fullMessage, file: file, function: function, line: line)
    }
    
    public func log(
        level: LogLevel,
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        guard level >= self.level else { return }
        
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            message: message(),
            file: URL(fileURLWithPath: file).lastPathComponent,
            function: function,
            line: line,
            threadId: Thread.current.description
        )
        
        // Add to buffer
        buffer.append(entry)
        if buffer.count > maxBufferSize {
            buffer.removeFirst(buffer.count - maxBufferSize)
        }
        
        // Format and output
        let formatted = formatter.format(entry)
        output.write(formatted)
    }
    
    // MARK: - Buffer Management
    
    /// Get all log entries in the buffer
    public func getBuffer() -> [LogEntry] {
        buffer
    }
    
    /// Clear the log buffer
    public func clearBuffer() {
        buffer.removeAll()
    }
    
    /// Export logs to a file
    public func exportLogs(to url: URL) throws {
        let logs = buffer.map { formatter.format($0) }.joined(separator: "\n")
        try logs.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Log Entry

/// A single log entry
public struct LogEntry: Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let message: String
    public let file: String
    public let function: String
    public let line: Int
    public let threadId: String
}

// MARK: - Log Formatting

/// Protocol for log formatters
public protocol LogFormatter: Sendable {
    func format(_ entry: LogEntry) -> String
}

/// Default log formatter
public struct DefaultLogFormatter: LogFormatter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    private let includeLocation: Bool
    private let includeThread: Bool
    
    public init(includeLocation: Bool = true, includeThread: Bool = false) {
        self.includeLocation = includeLocation
        self.includeThread = includeThread
    }
    
    public func format(_ entry: LogEntry) -> String {
        var components: [String] = []
        
        // Timestamp
        components.append(Self.dateFormatter.string(from: entry.timestamp))
        
        // Level
        components.append("[\(entry.level.label)]")
        
        // Thread (optional)
        if includeThread {
            components.append("[\(entry.threadId)]")
        }
        
        // Message
        components.append(entry.message)
        
        // Location (optional)
        if includeLocation {
            components.append("(\(entry.file):\(entry.line))")
        }
        
        return components.joined(separator: " ")
    }
}

/// Compact formatter for less verbose output
public struct CompactLogFormatter: LogFormatter {
    public init() {}
    
    public func format(_ entry: LogEntry) -> String {
        "\(entry.level.symbol) \(entry.message)"
    }
}

/// JSON formatter for structured logging
public struct JSONLogFormatter: LogFormatter {
    private let encoder = JSONEncoder()
    
    public init() {
        encoder.dateEncodingStrategy = .iso8601
    }
    
    public func format(_ entry: LogEntry) -> String {
        let jsonEntry = JSONLogEntry(
            timestamp: entry.timestamp,
            level: entry.level.label,
            message: entry.message,
            file: entry.file,
            function: entry.function,
            line: entry.line,
            thread: entry.threadId
        )
        
        guard let data = try? encoder.encode(jsonEntry),
              let string = String(data: data, encoding: .utf8) else {
            return entry.message
        }
        
        return string
    }
    
    private struct JSONLogEntry: Codable {
        let timestamp: Date
        let level: String
        let message: String
        let file: String
        let function: String
        let line: Int
        let thread: String
    }
}

// MARK: - Log Output

/// Protocol for log output destinations
public protocol LogOutput: Sendable {
    func write(_ message: String)
}

/// Console output (print to stdout)
public struct ConsoleLogOutput: LogOutput {
    public init() {}
    
    public func write(_ message: String) {
        print(message)
    }
}

/// File output
public actor FileLogOutput: LogOutput {
    private let fileURL: URL
    private let fileHandle: FileHandle?
    
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
    }
    
    deinit {
        fileHandle?.closeFile()
    }
    
    public func write(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        fileHandle?.write(data)
    }
}

/// XCTest output (integrates with XCTest logging)
public struct XCTestLogOutput: LogOutput {
    public init() {}
    
    public func write(_ message: String) {
        // XCTest captures stdout, so we can just print
        // In a real implementation, we might use XCTActivity or other XCTest APIs
        print("[TEST] \(message)")
    }
}

/// Combined output (writes to multiple destinations)
public struct CombinedLogOutput: LogOutput {
    private let outputs: [LogOutput]
    
    public init(outputs: [LogOutput]) {
        self.outputs = outputs
    }
    
    public func write(_ message: String) {
        for output in outputs {
            output.write(message)
        }
    }
}

// MARK: - Global Logger

/// Global test logger instance
public let testLogger = TestLogger(
    level: ProcessInfo.processInfo.environment["TEST_LOG_LEVEL"]
        .flatMap { LogLevel(rawValue: Int($0) ?? 1) } ?? .info
)

// MARK: - Convenience Extensions

public extension TestLoggerProtocol {
    /// Log a debug message
    func debug(
        _ message: @autoclosure () -> String
    ) {
        debug(message(), file: #file, function: #function, line: #line)
    }
    
    /// Log an info message
    func info(
        _ message: @autoclosure () -> String
    ) {
        info(message(), file: #file, function: #function, line: #line)
    }
    
    /// Log a warning message
    func warning(
        _ message: @autoclosure () -> String
    ) {
        warning(message(), file: #file, function: #function, line: #line)
    }
    
    /// Log an error message
    func error(
        _ message: @autoclosure () -> String,
        error: Error? = nil
    ) {
        self.error(message(), error: error, file: #file, function: #function, line: #line)
    }
}
*/

// Placeholder to prevent compilation errors
public protocol TestLoggerProtocol {}
public enum LogLevel: Int { case debug = 0 }
public struct TestLogger: TestLoggerProtocol {}
