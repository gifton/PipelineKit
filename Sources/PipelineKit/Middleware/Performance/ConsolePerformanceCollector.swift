import Foundation

/// Performance collector that outputs measurements to the console.
public struct ConsolePerformanceCollector: PerformanceCollector {
    private let formatter: PerformanceFormatter
    private let logLevel: LogLevel
    
    public enum LogLevel: String, CaseIterable, Sendable {
        case verbose = "VERBOSE"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }
    
    public init(
        formatter: PerformanceFormatter = DefaultPerformanceFormatter(),
        logLevel: LogLevel = .info
    ) {
        self.formatter = formatter
        self.logLevel = logLevel
    }
    
    public func record(_ measurement: PerformanceMeasurement) async {
        let formattedMessage = formatter.format(measurement)
        
        switch logLevel {
        case .verbose:
            print("[\(logLevel.rawValue)] \(formattedMessage)")
        case .info:
            if measurement.isSuccess {
                print("[\(logLevel.rawValue)] \(formattedMessage)")
            }
        case .warning:
            if measurement.executionTime > 1.0 { // Warn for slow commands
                print("[\(logLevel.rawValue)] \(formattedMessage)")
            }
        case .error:
            if !measurement.isSuccess {
                print("[\(logLevel.rawValue)] \(formattedMessage)")
            }
        }
    }
}

/// Protocol for formatting performance measurements.
public protocol PerformanceFormatter: Sendable {
    func format(_ measurement: PerformanceMeasurement) -> String
}

/// Default performance formatter.
public struct DefaultPerformanceFormatter: PerformanceFormatter {
    private let includeTimestamp: Bool
    private let includeMetrics: Bool
    
    public init(includeTimestamp: Bool = true, includeMetrics: Bool = false) {
        self.includeTimestamp = includeTimestamp
        self.includeMetrics = includeMetrics
    }
    
    public func format(_ measurement: PerformanceMeasurement) -> String {
        var components: [String] = []
        
        if includeTimestamp {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            components.append(formatter.string(from: measurement.startTime))
        }
        
        components.append("Command: \(measurement.commandName)")
        components.append("Duration: \(String(format: "%.3f", measurement.executionTime))s")
        components.append("Status: \(measurement.isSuccess ? "✅" : "❌")")
        
        if !measurement.isSuccess, let error = measurement.errorMessage {
            components.append("Error: \(error)")
        }
        
        if includeMetrics && !measurement.metrics.isEmpty {
            let metricsString = measurement.metrics
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            components.append("Metrics: [\(metricsString)]")
        }
        
        return components.joined(separator: " | ")
    }
}

/// JSON performance formatter for structured logging.
public struct JSONPerformanceFormatter: PerformanceFormatter {
    public init() {}
    
    public func format(_ measurement: PerformanceMeasurement) -> String {
        let data: [String: Any] = [
            "commandName": measurement.commandName,
            "executionTime": measurement.executionTime,
            "startTime": ISO8601DateFormatter().string(from: measurement.startTime),
            "endTime": ISO8601DateFormatter().string(from: measurement.endTime),
            "isSuccess": measurement.isSuccess,
            "errorMessage": measurement.errorMessage ?? NSNull(),
            "metrics": measurement.metrics
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"Failed to serialize performance measurement\"}"
        }
    }
}