import Foundation

/// A unified protocol for collecting metrics across PipelineKit.
///
/// This protocol provides a comprehensive interface for recording various metric types
/// including counters, gauges, histograms, and timers.
///
/// ## Design Principles
/// - Thread-safe: All implementations must be Sendable
/// - Extensible: Supports custom tags for metric dimensions
/// - Efficient: Implementations should handle high-volume metrics
/// - Export-ready: Data format suitable for various metric backends
public protocol MetricsCollector: Sendable {
    // MARK: - Core Metric Recording
    
    /// Records a counter metric (cumulative value that only increases).
    func recordCounter(_ name: String, value: Double, tags: [String: String]) async
    
    /// Records a gauge metric (point-in-time value that can go up or down).
    func recordGauge(_ name: String, value: Double, tags: [String: String]) async
    
    /// Records a histogram metric (distribution of values).
    func recordHistogram(_ name: String, value: Double, tags: [String: String]) async
    
    /// Records a timer metric (duration of operations).
    func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async
    
    // MARK: - Batch Recording
    
    /// Records multiple metrics in a single batch operation.
    func recordBatch(_ metrics: [(name: String, type: MetricType, value: Double, tags: [String: String])]) async
    
    // MARK: - Lifecycle Management
    
    /// Flushes any pending metrics to their destinations.
    func flush() async
    
    /// Resets all collected metrics.
    func reset() async
}

/// The type of metric being recorded.
public enum MetricType: String, Sendable, Codable {
    case counter
    case gauge
    case histogram
    case timer
}