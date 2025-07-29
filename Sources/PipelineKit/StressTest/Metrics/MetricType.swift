import Foundation

/// Types of metrics that can be collected during stress tests.
///
/// Each metric type has specific aggregation rules and semantic meaning:
/// - Gauge: Point-in-time measurements (e.g., current memory usage)
/// - Counter: Monotonically increasing values (e.g., total allocations)
/// - Histogram: Distribution of values (e.g., response times)
/// - Timer: Duration measurements with automatic unit conversion
public enum MetricType: String, Sendable, Codable, CaseIterable {
    /// A point-in-time measurement that can go up or down.
    /// Examples: CPU usage, memory usage, thread count
    case gauge
    
    /// A monotonically increasing value.
    /// Examples: Total requests, bytes allocated, errors
    case counter
    
    /// A distribution of values over time.
    /// Examples: Request latencies, queue depths
    case histogram
    
    /// Duration measurements with automatic timing support.
    /// Similar to histogram but specialized for time measurements
    case timer
    
    /// Returns appropriate aggregation methods for this metric type.
    public var supportedAggregations: Set<AggregationType> {
        switch self {
        case .gauge:
            return [.last, .min, .max, .avg, .sum]
        case .counter:
            return [.sum, .rate, .increase]
        case .histogram, .timer:
            return [.min, .max, .avg, .sum, .count, .p50, .p90, .p95, .p99, .p999]
        }
    }
    
    /// Default aggregation for quick summaries.
    public var defaultAggregation: AggregationType {
        switch self {
        case .gauge: return .last
        case .counter: return .rate
        case .histogram, .timer: return .p50
        }
    }
}

/// Aggregation types for metric calculations.
public enum AggregationType: String, Sendable, Codable, CaseIterable {
    // Basic aggregations
    case last      // Last observed value
    case min       // Minimum value
    case max       // Maximum value
    case avg       // Average value
    case sum       // Sum of all values
    case count     // Number of observations
    
    // Counter-specific
    case rate      // Rate per second
    case increase  // Total increase
    
    // Percentiles
    case p50       // 50th percentile (median)
    case p90       // 90th percentile
    case p95       // 95th percentile
    case p99       // 99th percentile
    case p999      // 99.9th percentile
    
    /// Returns the quantile value for percentile types.
    public var quantile: Double? {
        switch self {
        case .p50: return 0.5
        case .p90: return 0.9
        case .p95: return 0.95
        case .p99: return 0.99
        case .p999: return 0.999
        default: return nil
        }
    }
}