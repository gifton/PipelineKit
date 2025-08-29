import Foundation

/// Protocol for collecting pipeline execution metrics.
/// 
/// MetricsCollector provides a standardized interface for recording various types
/// of metrics during command pipeline execution. Implementations can forward metrics
/// to various backends like StatsD, Prometheus, or custom monitoring solutions.
/// 
/// ## Metric Types
/// 
/// - **Counter**: Incremental values (e.g., number of commands executed)
/// - **Gauge**: Point-in-time measurements (e.g., current memory usage)
/// - **Timer**: Duration measurements (e.g., command execution time)
/// - **Histogram**: Distribution of values (e.g., response sizes)
/// 
/// ## Usage Example
/// 
/// ```swift
/// class PrometheusCollector: MetricsCollector {
///     func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
///         // Send to Prometheus
///         await prometheus.increment(name, by: value, labels: tags)
///     }
///     
///     func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
///         // Record duration in milliseconds
///         await prometheus.observe(name, value: duration * 1000, labels: tags)
///     }
/// }
/// 
/// // Use with pipeline
/// let collector = PrometheusCollector()
/// await collector.recordTimer("command.execution", duration: 0.125, 
///                             tags: ["command": "CreateUser", "status": "success"])
/// ```
/// 
/// ## Implementation Notes
/// 
/// - All methods are async to support network-based metric backends
/// - Tags provide dimensional data for metric aggregation and filtering
/// - Implementations should handle failures gracefully without affecting pipeline execution
/// 
/// - SeeAlso: `DefaultMetricsCollector`, `PipelineKitObservability.MetricsFacade`
public protocol MetricsCollector: Sendable {
    /// Records a counter metric.
    /// 
    /// Counters represent cumulative values that only increase over time.
    /// Use for counting events, errors, or completed operations.
    /// 
    /// - Parameters:
    ///   - name: The metric name (e.g., "commands.executed")
    ///   - value: The amount to increment (typically 1.0)
    ///   - tags: Dimensional metadata for the metric
    func recordCounter(_ name: String, value: Double, tags: [String: String]) async
    
    /// Records a gauge metric.
    /// 
    /// Gauges represent instantaneous measurements that can increase or decrease.
    /// Use for current values like queue depth, memory usage, or active connections.
    /// 
    /// - Parameters:
    ///   - name: The metric name (e.g., "queue.depth")
    ///   - value: The current measurement
    ///   - tags: Dimensional metadata for the metric
    func recordGauge(_ name: String, value: Double, tags: [String: String]) async
    
    /// Records a timer metric.
    /// 
    /// Timers measure durations, typically for operation latencies.
    /// Values are in seconds but may be converted to milliseconds by backends.
    /// 
    /// - Parameters:
    ///   - name: The metric name (e.g., "command.duration")
    ///   - duration: The time interval in seconds
    ///   - tags: Dimensional metadata for the metric
    func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async
    
    /// Records a histogram metric.
    /// 
    /// Histograms track the distribution of values over time.
    /// Use for measuring value distributions like request sizes or score ranges.
    /// 
    /// - Parameters:
    ///   - name: The metric name (e.g., "response.size")
    ///   - value: The sample value to record
    ///   - tags: Dimensional metadata for the metric
    func recordHistogram(_ name: String, value: Double, tags: [String: String]) async
}

/// Default implementation that delegates to the global Metrics facade.
public struct DefaultMetricsCollector: MetricsCollector {
    public init() {}
    
    public func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
        // This will be integrated with PipelineKitObservability.Metrics
        // For now, no-op to avoid circular dependency
    }
    
    public func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        // This will be integrated with PipelineKitObservability.Metrics
    }
    
    public func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        // This will be integrated with PipelineKitObservability.Metrics
    }
    
    public func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        // This will be integrated with PipelineKitObservability.Metrics
    }
}
