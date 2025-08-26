import Foundation

/// Protocol marking a type as a metric kind for phantom type safety.
///
/// This protocol enables compile-time type safety for metrics, ensuring
/// that operations specific to certain metric types (like incrementing counters)
/// are only available on the appropriate metric types.
public protocol MetricKind: Sendable {
    /// The runtime type identifier for this metric kind.
    static var type: MetricType { get }
}

/// The runtime type of metric being recorded.
public enum MetricType: String, Sendable, Codable, CaseIterable {
    case counter
    case gauge
    case histogram
    case timer
}

/// Phantom type for counter metrics.
///
/// Counters are monotonically increasing values that only go up,
/// typically used for counting events, requests, errors, etc.
public enum Counter: MetricKind {
    public static let type = MetricType.counter
}

/// Phantom type for gauge metrics.
///
/// Gauges are point-in-time measurements that can go up or down,
/// typically used for memory usage, queue depth, temperature, etc.
public enum Gauge: MetricKind {
    public static let type = MetricType.gauge
}

/// Phantom type for histogram metrics.
///
/// Histograms track distributions of values over time,
/// typically used for request latencies, response sizes, etc.
public enum Histogram: MetricKind {
    public static let type = MetricType.histogram
}

/// Phantom type for timer metrics.
///
/// Timers are specialized histograms for tracking durations,
/// typically used for operation timing, request duration, etc.
public enum PipelineTimer: MetricKind {
    public static let type = MetricType.timer
}
