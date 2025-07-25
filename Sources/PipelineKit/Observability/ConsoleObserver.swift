import Foundation

/// A simple observer that logs pipeline events to the console with configurable formatting
/// Useful for development and debugging purposes
///
/// ## Design Decision: @unchecked Sendable with Thread-Local DateFormatter
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **DateFormatter Thread Safety**: DateFormatter is not thread-safe, but we solve this
///    by using thread-local storage. Each thread gets its own DateFormatter instance,
///    eliminating any possibility of concurrent access.
///
/// 2. **All Other Properties Are Safe**:
///    - `style`: Enum (inherently Sendable)
///    - `level`: Enum with raw value (inherently Sendable)
///    - `includeTimestamps`: Bool (inherently Sendable)
///
/// 3. **Thread-Local Storage Pattern**: The dateFormatter computed property uses
///    Thread.current.threadDictionary to maintain one formatter per thread. This is a
///    well-established pattern for making non-thread-safe objects safe in concurrent contexts.
///
/// 4. **Performance Optimization**: Creating DateFormatter instances is expensive. Thread-local
///    storage provides the best balance between thread safety and performance.
///
/// The @unchecked annotation is required because Swift cannot analyze the thread-local
/// storage pattern, but the implementation is genuinely thread-safe.
public final class ConsoleObserver: BaseObserver, @unchecked Sendable {
    
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
    
    /// Thread-local storage key for date formatters
    private static let dateFormatterKey = "ConsoleObserver.dateFormatter"
    
    /// Thread-safe access to DateFormatter using thread-local storage
    /// This avoids the performance penalty of creating formatters while maintaining thread safety
    private var dateFormatter: DateFormatter {
        if let formatter = Thread.current.threadDictionary[Self.dateFormatterKey] as? DateFormatter {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        Thread.current.threadDictionary[Self.dateFormatterKey] = formatter
        return formatter
    }
    
    public init(
        style: Style = .pretty,
        level: Level = .info,
        includeTimestamps: Bool = true
    ) {
        self.style = style
        self.level = level
        self.includeTimestamps = includeTimestamps
        super.init()
    }
    
    // MARK: - Pipeline Events
    
    public override func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
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
    
    public override func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
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
    
    public override func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
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
    
    public override func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
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
    
    public override func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        guard level <= .verbose else { return }
        
        switch style {
        case .simple, .detailed:
            break // Skip success logs in simple/detailed mode for less noise
        case .pretty:
            if duration > 0.1 { // Only log slow middleware
                print("  \(timestamp)⚡ \(middlewareName) completed in \(formatDuration(duration))")
            }
        }
    }
    
    public override func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
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
    
    public override func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
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