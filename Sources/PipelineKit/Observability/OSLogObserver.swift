import Foundation
import OSLog

/// Custom log level enum that can be compared
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case notice = 2
    case error = 3
    case fault = 4
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
    
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default // notice is not available in older versions
        case .error: return .error
        case .fault: return .fault
        }
    }
}

/// An observer that integrates with Apple's unified logging system (OSLog)
/// Provides structured logging with categories and log levels for different pipeline events
///
/// This class is Sendable because all its properties are immutable (`let` declarations)
/// and Logger instances are thread-safe.
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public final class OSLogObserver: BaseObserver, @unchecked Sendable {
    
    // MARK: - Logger Categories
    
    private let pipelineLogger: Logger
    private let middlewareLogger: Logger
    private let handlerLogger: Logger
    private let errorLogger: Logger
    private let performanceLogger: Logger
    
    // MARK: - Configuration
    
    public struct Configuration: Sendable {
        public let subsystem: String
        public let logLevel: LogLevel
        public let includeCommandDetails: Bool
        public let includeMetadata: Bool
        public let performanceThreshold: TimeInterval
        
        public init(
            subsystem: String = "com.pipelinekit.observability",
            logLevel: LogLevel = .info,
            includeCommandDetails: Bool = false,
            includeMetadata: Bool = true,
            performanceThreshold: TimeInterval = 1.0
        ) {
            self.subsystem = subsystem
            self.logLevel = logLevel
            self.includeCommandDetails = includeCommandDetails
            self.includeMetadata = includeMetadata
            self.performanceThreshold = performanceThreshold
        }
    }
    
    private let configuration: Configuration
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        
        // Initialize loggers with different categories for better filtering
        self.pipelineLogger = Logger(subsystem: configuration.subsystem, category: "pipeline")
        self.middlewareLogger = Logger(subsystem: configuration.subsystem, category: "middleware")
        self.handlerLogger = Logger(subsystem: configuration.subsystem, category: "handler")
        self.errorLogger = Logger(subsystem: configuration.subsystem, category: "error")
        self.performanceLogger = Logger(subsystem: configuration.subsystem, category: "performance")
        
        super.init()
    }
    
    // MARK: - Pipeline Events
    
    public override func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        let correlationId = extractCorrelationId(from: metadata)
        let commandType = String(describing: type(of: command))
        
        if configuration.logLevel <= .info {
            pipelineLogger.info("""
                🚀 Pipeline execution started
                📋 Command: \(commandType, privacy: .public)
                🔧 Pipeline: \(pipelineType, privacy: .public)
                🔗 Correlation: \(correlationId, privacy: .public)
                \(self.formatMetadata(metadata), privacy: .public)
                """)
        }
    }
    
    public override func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        let correlationId = extractCorrelationId(from: metadata)
        let commandType = String(describing: type(of: command))
        let resultType = String(describing: type(of: result))
        
        // Log performance if duration exceeds threshold
        if duration > configuration.performanceThreshold {
            performanceLogger.notice("""
                ⚠️ Slow pipeline execution
                📋 Command: \(commandType, privacy: .public)
                🔧 Pipeline: \(pipelineType, privacy: .public)
                ⏱️ Duration: \(String(format: "%.3f", duration), privacy: .public)s
                🔗 Correlation: \(correlationId, privacy: .public)
                """)
        }
        
        if configuration.logLevel <= .info {
            pipelineLogger.info("""
                ✅ Pipeline execution completed
                📋 Command: \(commandType, privacy: .public)
                🔧 Pipeline: \(pipelineType, privacy: .public)
                📤 Result: \(resultType, privacy: .public)
                ⏱️ Duration: \(String(format: "%.3f", duration), privacy: .public)s
                🔗 Correlation: \(correlationId, privacy: .public)
                """)
        }
    }
    
    public override func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        let correlationId = extractCorrelationId(from: metadata)
        let commandType = String(describing: type(of: command))
        let errorType = String(describing: type(of: error))
        
        errorLogger.error("""
            ❌ Pipeline execution failed
            📋 Command: \(commandType, privacy: .public)
            🔧 Pipeline: \(pipelineType, privacy: .public)
            💥 Error: \(errorType, privacy: .public)
            📝 Message: \(error.localizedDescription, privacy: .public)
            ⏱️ Duration: \(String(format: "%.3f", duration), privacy: .public)s
            🔗 Correlation: \(correlationId, privacy: .public)
            """)
    }
    
    // MARK: - Middleware Events
    
    public override func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
        if configuration.logLevel <= .debug {
            middlewareLogger.debug("""
                🔧 Middleware starting
                📦 Name: \(middlewareName, privacy: .public)
                🔢 Order: \(order, privacy: .public)
                🔗 Correlation: \(correlationId, privacy: .public)
                """)
        }
    }
    
    public override func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        if configuration.logLevel <= .debug {
            middlewareLogger.debug("""
                ✅ Middleware completed
                📦 Name: \(middlewareName, privacy: .public)
                🔢 Order: \(order, privacy: .public)
                ⏱️ Duration: \(String(format: "%.3f", duration * 1000), privacy: .public)ms
                🔗 Correlation: \(correlationId, privacy: .public)
                """)
        }
    }
    
    public override func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        let errorType = String(describing: type(of: error))
        
        errorLogger.error("""
            ❌ Middleware failed
            📦 Name: \(middlewareName, privacy: .public)
            🔢 Order: \(order, privacy: .public)
            💥 Error: \(errorType, privacy: .public)
            📝 Message: \(error.localizedDescription, privacy: .public)
            ⏱️ Duration: \(String(format: "%.3f", duration * 1000), privacy: .public)ms
            🔗 Correlation: \(correlationId, privacy: .public)
            """)
    }
    
    // MARK: - Handler Events
    
    public override func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
        let commandType = String(describing: type(of: command))
        
        if configuration.logLevel <= .debug {
            handlerLogger.debug("""
                🎯 Handler starting
                📋 Command: \(commandType, privacy: .public)
                🔧 Handler: \(handlerType, privacy: .public)
                🔗 Correlation: \(correlationId, privacy: .public)
                """)
        }
    }
    
    public override func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
        let commandType = String(describing: type(of: command))
        let resultType = String(describing: type(of: result))
        
        // Log performance if duration exceeds threshold
        if duration > configuration.performanceThreshold {
            performanceLogger.notice("""
                ⚠️ Slow handler execution
                📋 Command: \(commandType, privacy: .public)
                🔧 Handler: \(handlerType, privacy: .public)
                ⏱️ Duration: \(String(format: "%.3f", duration), privacy: .public)s
                🔗 Correlation: \(correlationId, privacy: .public)
                """)
        }
        
        if configuration.logLevel <= .debug {
            handlerLogger.debug("""
                ✅ Handler completed
                📋 Command: \(commandType, privacy: .public)
                🔧 Handler: \(handlerType, privacy: .public)
                📤 Result: \(resultType, privacy: .public)
                ⏱️ Duration: \(String(format: "%.3f", duration), privacy: .public)s
                🔗 Correlation: \(correlationId, privacy: .public)
                """)
        }
    }
    
    public override func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
        let commandType = String(describing: type(of: command))
        let errorType = String(describing: type(of: error))
        
        errorLogger.error("""
            ❌ Handler failed
            📋 Command: \(commandType, privacy: .public)
            🔧 Handler: \(handlerType, privacy: .public)
            💥 Error: \(errorType, privacy: .public)
            📝 Message: \(error.localizedDescription, privacy: .public)
            ⏱️ Duration: \(String(format: "%.3f", duration), privacy: .public)s
            🔗 Correlation: \(correlationId, privacy: .public)
            """)
    }
    
    // MARK: - Custom Events
    
    public override func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        let propertiesString = formatProperties(properties)
        
        pipelineLogger.info("""
            📊 Custom event
            🏷️ Event: \(eventName, privacy: .public)
            📊 Properties: \(propertiesString, privacy: .public)
            🔗 Correlation: \(correlationId, privacy: .public)
            """)
    }
    
    // MARK: - Helper Methods
    
    private func extractCorrelationId(from metadata: CommandMetadata) -> String {
        if let correlationId = metadata.correlationId {
            return correlationId
        }
        return "unknown"
    }
    
    private func formatMetadata(_ metadata: CommandMetadata) -> String {
        guard configuration.includeMetadata else { return "" }
        
        if let defaultMetadata = metadata as? StandardCommandMetadata {
            return """
                👤 User: \(defaultMetadata.userId ?? "anonymous")
                📅 Timestamp: \(ISO8601DateFormatter().string(from: defaultMetadata.timestamp))
                """
        }
        
        return "📋 Metadata: \(String(describing: metadata))"
    }
    
    private func formatProperties(_ properties: [String: Sendable]) -> String {
        properties
            .map { key, value in "\(key): \(value)" }
            .joined(separator: ", ")
    }
}

// MARK: - Convenience Extensions

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public extension OSLogObserver {
    /// Creates an observer optimized for development/debugging
    static func development() -> OSLogObserver {
        OSLogObserver(configuration: Configuration(
            subsystem: "com.pipelinekit.dev",
            logLevel: .debug,
            includeCommandDetails: true,
            includeMetadata: true,
            performanceThreshold: PerformanceThresholds.development.slowMiddlewareThreshold
        ))
    }
    
    /// Creates an observer optimized for production
    static func production() -> OSLogObserver {
        OSLogObserver(configuration: Configuration(
            subsystem: "com.pipelinekit.prod",
            logLevel: .info,
            includeCommandDetails: false,
            includeMetadata: false,
            performanceThreshold: PerformanceThresholds.default.slowMiddlewareThreshold
        ))
    }
    
    /// Creates an observer for performance monitoring
    static func performance() -> OSLogObserver {
        OSLogObserver(configuration: Configuration(
            subsystem: "com.pipelinekit.perf",
            logLevel: .info,
            includeCommandDetails: false,
            includeMetadata: false,
            performanceThreshold: PerformanceThresholds.strict.slowMiddlewareThreshold
        ))
    }
}

// MARK: - OSLog Extensions for Structured Logging

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public extension Logger {
    /// Logs pipeline metrics in a structured format
    func logPipelineMetrics(
        commandType: String,
        pipelineType: String,
        duration: TimeInterval,
        success: Bool,
        correlationId: String
    ) {
        let status = success ? "success" : "failure"
        self.info("""
            [METRICS] Pipeline execution
            command=\(commandType, privacy: .public)
            pipeline=\(pipelineType, privacy: .public)
            duration=\(String(format: "%.3f", duration), privacy: .public)
            status=\(status, privacy: .public)
            correlation=\(correlationId, privacy: .public)
            """)
    }
    
    /// Logs middleware performance in a structured format
    func logMiddlewareMetrics(
        middlewareName: String,
        order: Int,
        duration: TimeInterval,
        success: Bool,
        correlationId: String
    ) {
        let status = success ? "success" : "failure"
        self.debug("""
            [METRICS] Middleware execution
            middleware=\(middlewareName, privacy: .public)
            order=\(order, privacy: .public)
            duration=\(String(format: "%.3f", duration * 1000), privacy: .public)
            status=\(status, privacy: .public)
            correlation=\(correlationId, privacy: .public)
            """)
    }
}
