import Foundation
import PipelineKitCore

/// A simple observer that logs pipeline events to the console with configurable formatting
/// Useful for development and debugging purposes
public final class ConsoleObserver: PipelineObserver {
    /// Formatting style for console output
    public enum Style: Sendable {
        case simple      // Minimal output
        case detailed    // Includes all details
        case pretty      // Formatted with emojis and structure
    }
    
    /// Log level filter
    public enum Level: Int, Comparable, Sendable {
        case verbose = 0
        case info = 1
        case warning = 2
        case error = 3
        
        public static func < (lhs: Level, rhs: Level) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }
    
    private let style: Style
    private let level: Level
    private let includeTimestamps: Bool
    
    /// Thread-safe date formatter
    private let dateFormatter = SendableDateFormatter.timestamp()
    
    public init(
        style: Style = .pretty,
        level: Level = .info,
        includeTimestamps: Bool = true
    ) {
        self.style = style
        self.level = level
        self.includeTimestamps = includeTimestamps
    }
    
    // MARK: - Pipeline Events
    
    public func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        guard level <= .info else { return }
        
        switch style {
        case .simple:
            print("[\(timestamp)]Pipeline starting: \(type(of: command))")
        case .detailed:
            print("[\(timestamp)]Pipeline will execute: command=\(type(of: command)), pipeline=\(pipelineType), correlationId=\(metadata.correlationId ?? "none")")
        case .pretty:
            print("""
            \(timestamp)🚀 Pipeline Started
            ├─ Command: \(type(of: command))
            ├─ Pipeline: \(pipelineType)
            └─ ID: \(metadata.correlationId ?? "none")
            """)
        }
    }
    
    public func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        guard level <= .info else { return }
        
        switch style {
        case .simple:
            print("[\(timestamp)]Pipeline completed: \(type(of: command)) in \(formatDuration(duration))")
        case .detailed:
            print("[\(timestamp)]Pipeline did execute: command=\(type(of: command)), pipeline=\(pipelineType), duration=\(formatDuration(duration)), correlationId=\(metadata.correlationId ?? "none")")
        case .pretty:
            print("""
            \(timestamp)✅ Pipeline Completed
            ├─ Command: \(type(of: command))
            ├─ Duration: \(formatDuration(duration))
            └─ ID: \(metadata.correlationId ?? "none")
            """)
        }
    }
    
    public func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        guard level <= .error else { return }
        
        switch style {
        case .simple:
            print("[\(timestamp)]Pipeline failed: \(type(of: command)) - \(error.localizedDescription)")
        case .detailed:
            print("[\(timestamp)]Pipeline did fail: command=\(type(of: command)), error=\(error), duration=\(formatDuration(duration)), correlationId=\(metadata.correlationId ?? "none")")
        case .pretty:
            print("""
            \(timestamp)❌ Pipeline Failed
            ├─ Command: \(type(of: command))
            ├─ Error: \(error.localizedDescription)
            ├─ Duration: \(formatDuration(duration))
            └─ ID: \(metadata.correlationId ?? "none")
            """)
        }
    }
    
    // MARK: - Middleware Events
    
    public func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
        guard level <= .verbose else { return }
        
        switch style {
        case .simple:
            print("[\(timestamp)]Middleware starting: \(middlewareName)")
        case .detailed:
            print("[\(timestamp)]Middleware will execute: name=\(middlewareName), order=\(order), correlationId=\(correlationId)")
        case .pretty:
            print("  \(timestamp)🔧 \(middlewareName) [#\(order)]")
        }
    }
    
    public func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        guard level <= .verbose else { return }
        
        switch style {
        case .simple, .detailed:
            break // Skip success logs in simple/detailed mode for less noise
        case .pretty:
            if duration > PerformanceConfiguration.thresholds.slowMiddlewareThreshold {
                print("  \(timestamp)⚡ \(middlewareName) completed in \(formatDuration(duration))")
            }
        }
    }
    
    public func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        guard level <= .error else { return }
        
        switch style {
        case .simple:
            print("[\(timestamp)]Middleware failed: \(middlewareName) - \(error.localizedDescription)")
        case .detailed:
            print("[\(timestamp)]Middleware did fail: name=\(middlewareName), order=\(order), error=\(error), correlationId=\(correlationId)")
        case .pretty:
            print("  \(timestamp)💥 \(middlewareName) failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Custom Events
    
    public func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        guard level <= .info else { return }
        
        switch style {
        case .simple:
            print("[\(timestamp)]Event: \(eventName)")
        case .detailed:
            let props = properties.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            print("[\(timestamp)]Custom event: name=\(eventName), properties={\(props)}, correlationId=\(correlationId)")
        case .pretty:
            print("""
            \(timestamp)📊 \(eventName)
            └─ \(formatProperties(properties))
            """)
        }
    }
    
    // MARK: - Helpers
    
    private var timestamp: String {
        includeTimestamps ? "[\(dateFormatter.string(from: Date()))] " : ""
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return String(format: "%.0fμs", duration * 1_000_000)
        } else if duration < 1.0 {
            return String(format: "%.0fms", duration * 1000)
        } else {
            return String(format: "%.2fs", duration)
        }
    }
    
    private func formatProperties(_ properties: [String: Sendable]) -> String {
        guard !properties.isEmpty else { return "No properties" }
        return properties
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
    }
}

// MARK: - Convenience Factory Methods

public extension ConsoleObserver {
    /// Creates a verbose console observer for development
    static func development() -> ConsoleObserver {
        ConsoleObserver(style: .pretty, level: .verbose)
    }
    
    /// Creates a simple console observer for production
    static func production() -> ConsoleObserver {
        ConsoleObserver(style: .simple, level: .warning)
    }
    
    /// Creates a detailed console observer for debugging
    static func debugging() -> ConsoleObserver {
        ConsoleObserver(style: .detailed, level: .verbose)
    }
}
