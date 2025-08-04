import PipelineKitMiddleware
import PipelineKitMiddleware
import Foundation

/// Result of querying aggregated metrics for a specific time window.
///
/// AggregatedMetrics provides a snapshot of statistics for a metric
/// over a given time period. The type of statistics depends on the
/// metric type (gauge, counter, histogram).
public struct AggregatedMetrics: Sendable, Equatable {
    /// The metric name.
    public let name: String
    
    /// The metric type.
    public let type: MetricType
    
    /// Time window for this aggregation.
    public let window: TimeWindow
    
    /// When this aggregation was computed.
    public let timestamp: Date
    
    /// The aggregated statistics.
    public let statistics: MetricStatistics
    
    /// Tags associated with this metric.
    public let tags: [String: String]
    
    public init(
        name: String,
        type: MetricType,
        window: TimeWindow,
        timestamp: Date,
        statistics: MetricStatistics,
        tags: [String: String] = [:]
    ) {
        self.name = name
        self.type = type
        self.window = window
        self.timestamp = timestamp
        self.statistics = statistics
        self.tags = tags
    }
}

/// Time window for aggregation.
public struct TimeWindow: Sendable, Equatable, Hashable {
    /// Window duration.
    public let duration: TimeInterval
    
    /// Window start time.
    public let startTime: Date
    
    /// Window end time.
    public var endTime: Date {
        startTime.addingTimeInterval(duration)
    }
    
    /// Predefined common windows.
    public static let oneMinute = TimeInterval(60)
    public static let fiveMinutes = TimeInterval(300)
    public static let fifteenMinutes = TimeInterval(900)
    public static let oneHour = TimeInterval(3600)
    
    public init(duration: TimeInterval, startTime: Date) {
        self.duration = duration
        self.startTime = startTime
    }
    
    /// Creates a window ending at the given time.
    public static func ending(at endTime: Date, duration: TimeInterval) -> TimeWindow {
        TimeWindow(duration: duration, startTime: endTime.addingTimeInterval(-duration))
    }
    
    /// Checks if a timestamp falls within this window.
    public func contains(_ timestamp: Date) -> Bool {
        timestamp >= startTime && timestamp < endTime
    }
    
    /// Returns the next window after this one.
    public func next() -> TimeWindow {
        TimeWindow(duration: duration, startTime: endTime)
    }
}

/// Union type for different metric statistics.
public enum MetricStatistics: Sendable, Equatable {
    case basic(BasicStatistics)
    case counter(CounterStatistics)
    case histogram(HistogramStatistics)
    
    /// Convenience accessors for common fields.
    public var count: Int {
        switch self {
        case .basic(let stats): return stats.count
        case .counter(let stats): return stats.count
        case .histogram(let stats): return stats.count
        }
    }
    
    public var sum: Double {
        switch self {
        case .basic(let stats): return stats.sum
        case .counter(let stats): return stats.sum
        case .histogram(let stats): return stats.sum
        }
    }
}

// MARK: - Extensions

extension AggregatedMetrics: CustomStringConvertible {
    public var description: String {
        let windowDesc = "\(Int(window.duration))s"
        
        switch statistics {
        case .basic(let stats):
            return "\(name) [\(windowDesc)]: count=\(stats.count), min=\(stats.min), max=\(stats.max), mean=\(String(format: "%.2f", stats.mean))"
            
        case .counter(let stats):
            return "\(name) [\(windowDesc)]: count=\(stats.count), rate=\(String(format: "%.2f", stats.rate))/s, increase=\(stats.increase)"
            
        case .histogram(let stats):
            return "\(name) [\(windowDesc)]: count=\(stats.count), p50=\(stats.p50), p95=\(stats.p95), p99=\(stats.p99)"
        }
    }
}

extension TimeWindow: CustomStringConvertible {
    public var description: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let start = formatter.string(from: startTime)
        let end = formatter.string(from: endTime)
        return "\(Int(duration))s window [\(start)-\(end)]"
    }
}

// MARK: - Query Support

/// Query parameters for retrieving aggregated metrics.
public struct MetricQuery: Sendable {
    /// Metric name pattern (supports wildcards).
    public let namePattern: String
    
    /// Time range for the query.
    public let timeRange: ClosedRange<Date>
    
    /// Desired aggregation windows.
    public let windows: Set<TimeInterval>
    
    /// Tag filters.
    public let tagFilters: [String: String]
    
    public init(
        namePattern: String,
        timeRange: ClosedRange<Date>,
        windows: Set<TimeInterval> = [TimeWindow.oneMinute],
        tagFilters: [String: String] = [:]
    ) {
        self.namePattern = namePattern
        self.timeRange = timeRange
        self.windows = windows
        self.tagFilters = tagFilters
    }
    
    /// Matches a metric name against the pattern.
    public func matches(name: String) -> Bool {
        // Simple wildcard matching
        if namePattern == "*" { return true }
        if namePattern.hasSuffix("*") {
            let prefix = String(namePattern.dropLast())
            return name.hasPrefix(prefix)
        }
        return name == namePattern
    }
}

/// Result of a metric query.
public struct MetricQueryResult: Sendable {
    /// Aggregated metrics matching the query.
    public let metrics: [AggregatedMetrics]
    
    /// Query execution time.
    public let queryTime: TimeInterval
    
    /// Number of data points processed.
    public let pointsProcessed: Int
    
    public init(
        metrics: [AggregatedMetrics],
        queryTime: TimeInterval,
        pointsProcessed: Int
    ) {
        self.metrics = metrics
        self.queryTime = queryTime
        self.pointsProcessed = pointsProcessed
    }
}