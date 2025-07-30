import Foundation

/// Configuration for file-based exporters.
public struct FileExportConfiguration: ExportConfiguration, Sendable {
    /// Path to the export file.
    public let path: String
    
    /// Maximum file size before rotation (in bytes).
    public let maxFileSize: Int
    
    /// Maximum number of rotated files to keep.
    public let maxFiles: Int
    
    /// Whether to compress rotated files.
    public let compressRotated: Bool
    
    /// File permissions.
    public let permissions: Int
    
    /// Buffer size for file operations.
    public let bufferSize: Int
    
    /// Flush interval.
    public let flushInterval: TimeInterval
    
    /// Real-time export mode.
    public let realTimeExport: Bool
    
    public init(
        path: String,
        maxFileSize: Int = 100_000_000, // 100MB
        maxFiles: Int = 5,
        compressRotated: Bool = false,
        permissions: Int = 0o644,
        bufferSize: Int = 1000,
        flushInterval: TimeInterval = 10.0,
        realTimeExport: Bool = false
    ) {
        self.path = path
        self.maxFileSize = maxFileSize
        self.maxFiles = maxFiles
        self.compressRotated = compressRotated
        self.permissions = permissions
        self.bufferSize = bufferSize
        self.flushInterval = flushInterval
        self.realTimeExport = realTimeExport
    }
}

/// Configuration for JSON exporter.
public struct JSONExportConfiguration: Sendable {
    /// Base file configuration.
    public let fileConfig: FileExportConfiguration
    
    /// Whether to pretty-print JSON.
    public let prettyPrint: Bool
    
    /// Date format for timestamps.
    public let dateFormat: DateFormat
    
    /// Number of decimal places for floating-point values.
    public let decimalPlaces: Int
    
    /// Whether to include null values.
    public let includeNullValues: Bool
    
    /// Whether to sort keys alphabetically.
    public let sortKeys: Bool
    
    public enum DateFormat: String, Sendable {
        case iso8601 = "iso8601"
        case unix = "unix"
        case unixMillis = "unix_millis"
        case custom = "custom"
    }
    
    public init(
        fileConfig: FileExportConfiguration,
        prettyPrint: Bool = true,
        dateFormat: DateFormat = .iso8601,
        decimalPlaces: Int = 3,
        includeNullValues: Bool = false,
        sortKeys: Bool = false
    ) {
        self.fileConfig = fileConfig
        self.prettyPrint = prettyPrint
        self.dateFormat = dateFormat
        self.decimalPlaces = decimalPlaces
        self.includeNullValues = includeNullValues
        self.sortKeys = sortKeys
    }
}

/// Configuration for CSV exporter.
public struct CSVExportConfiguration: Sendable {
    /// Base file configuration.
    public let fileConfig: FileExportConfiguration
    
    /// Column separator.
    public let separator: String
    
    /// Whether to include headers.
    public let includeHeaders: Bool
    
    /// Header names for columns.
    public let headers: [String]?
    
    /// Quote character for escaping.
    public let quoteCharacter: String
    
    /// Whether to quote all fields.
    public let quoteAll: Bool
    
    /// Line ending style.
    public let lineEnding: LineEnding
    
    public enum LineEnding: String, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }
    
    public init(
        fileConfig: FileExportConfiguration,
        separator: String = ",",
        includeHeaders: Bool = true,
        headers: [String]? = nil,
        quoteCharacter: String = "\"",
        quoteAll: Bool = false,
        lineEnding: LineEnding = .lf
    ) {
        self.fileConfig = fileConfig
        self.separator = separator
        self.includeHeaders = includeHeaders
        self.headers = headers
        self.quoteCharacter = quoteCharacter
        self.quoteAll = quoteAll
        self.lineEnding = lineEnding
    }
}

/// Configuration for Prometheus exporter.
public struct PrometheusExportConfiguration: ExportConfiguration, Sendable {
    /// Port to listen on.
    public let port: Int
    
    /// Path for metrics endpoint.
    public let metricsPath: String
    
    /// Host to bind to.
    public let host: String
    
    /// Additional labels to add to all metrics.
    public let globalLabels: [String: String]
    
    /// Metric name prefix.
    public let prefix: String
    
    /// Whether to include timestamp in output.
    public let includeTimestamp: Bool
    
    /// Buffer size.
    public let bufferSize: Int
    
    /// Flush interval (not used for Prometheus).
    public let flushInterval: TimeInterval
    
    /// Real-time export (always true for Prometheus).
    public let realTimeExport: Bool
    
    public init(
        port: Int = 9090,
        metricsPath: String = "/metrics",
        host: String = "0.0.0.0",
        globalLabels: [String: String] = [:],
        prefix: String = "",
        includeTimestamp: Bool = false
    ) {
        self.port = port
        self.metricsPath = metricsPath
        self.host = host
        self.globalLabels = globalLabels
        self.prefix = prefix
        self.includeTimestamp = includeTimestamp
        self.bufferSize = 0 // Not used
        self.flushInterval = 0 // Not used
        self.realTimeExport = true // Always real-time
    }
}

/// Export retry policy configuration.
public struct ExportRetryPolicy: Sendable {
    /// Maximum number of retry attempts.
    public let maxAttempts: Int
    
    /// Initial retry delay.
    public let initialDelay: TimeInterval
    
    /// Maximum retry delay.
    public let maxDelay: TimeInterval
    
    /// Multiplier for exponential backoff.
    public let multiplier: Double
    
    /// Jitter factor (0.0 to 1.0).
    public let jitterFactor: Double
    
    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        multiplier: Double = 2.0,
        jitterFactor: Double = 0.1
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitterFactor = jitterFactor
    }
    
    /// Calculates the delay for a given attempt.
    public func delay(for attempt: Int) -> TimeInterval {
        let baseDelay = min(initialDelay * pow(multiplier, Double(attempt - 1)), maxDelay)
        let jitter = baseDelay * jitterFactor * Double.random(in: -1...1)
        return max(0, baseDelay + jitter)
    }
}

/// Destination configuration.
public enum DestinationConfig: Sendable {
    case file(String)
    case http(URL)
    case tcp(host: String, port: Int)
    case custom(String)
}

/// Comprehensive export configuration.
public struct ExportSystemConfiguration: Sendable {
    /// Export manager configuration.
    public let managerConfig: ExportManager.Configuration
    
    /// Configurations for each exporter type.
    public let exporterConfigs: [String: any ExportConfiguration]
    
    /// Global retry policy.
    public let retryPolicy: ExportRetryPolicy
    
    /// Whether to start exporters automatically.
    public let autoStart: Bool
    
    public init(
        managerConfig: ExportManager.Configuration = ExportManager.Configuration(),
        exporterConfigs: [String: any ExportConfiguration] = [:],
        retryPolicy: ExportRetryPolicy = ExportRetryPolicy(),
        autoStart: Bool = true
    ) {
        self.managerConfig = managerConfig
        self.exporterConfigs = exporterConfigs
        self.retryPolicy = retryPolicy
        self.autoStart = autoStart
    }
}