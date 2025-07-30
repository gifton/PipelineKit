import Foundation

/// Shared protocol for components that emit metrics during stress testing.
///
/// This protocol provides a consistent interface for metric recording across
/// all simulators through optional MetricCollector support.
///
/// ## Usage
///
/// Conform your simulator to this protocol and define a namespace enum:
///
/// ```swift
/// enum CPUMetric: String {
///     case patternStart = "pattern.start"
///     case loadLevel = "load.level"
/// }
///
/// class CPULoadSimulator: MetricRecordable {
///     typealias Namespace = CPUMetric
///     let metricCollector: MetricCollector?
///     let namespace = "cpu"
/// }
/// ```
public protocol MetricRecordable {
    /// Simulator-specific metric namespace type.
    associatedtype Namespace: RawRepresentable where Namespace.RawValue == String
    
    /// Optional metric collector for recording metrics.
    var metricCollector: MetricCollector? { get }
    
    /// The top-level namespace for this simulator (e.g., "memory", "cpu").
    var namespace: String { get }
}

// MARK: - Default Implementations

public extension MetricRecordable {
    
    // MARK: Core Recording
    
    /// Records a metric data point with the simulator's namespace.
    ///
    /// - Parameters:
    ///   - name: The metric name from the namespace enum.
    ///   - value: The metric value (defaults to 1.0).
    ///   - type: The metric type (defaults to gauge).
    ///   - tags: Additional tags for the metric.
    ///   - timestamp: The timestamp (defaults to now).
    @inlinable
    func record(
        _ name: Namespace,
        value: Double = 1.0,
        type: MetricType = .gauge,
        tags: [String: String] = [:],
        timestamp: Date = Date()
    ) async {
        guard let collector = metricCollector else { return }
        
        let qualifiedName = "\(namespace).\(name.rawValue)"
        await collector.record(
            MetricDataPoint(
                timestamp: timestamp,
                name: qualifiedName,
                value: value,
                type: type,
                tags: tags
            )
        )
    }
    
    // MARK: Metric Type Helpers
    
    /// Records a gauge metric.
    @inlinable
    func recordGauge(
        _ name: Namespace,
        value: Double,
        tags: [String: String] = [:]
    ) async {
        await record(name, value: value, type: .gauge, tags: tags)
    }
    
    /// Records a counter metric.
    @inlinable
    func recordCounter(
        _ name: Namespace,
        value: Double = 1.0,
        tags: [String: String] = [:]
    ) async {
        await record(name, value: value, type: .counter, tags: tags)
    }
    
    /// Records a histogram metric (typically for latencies).
    @inlinable
    func recordHistogram(
        _ name: Namespace,
        value: Double,
        tags: [String: String] = [:]
    ) async {
        await record(name, value: value, type: .histogram, tags: tags)
    }
    
    // MARK: Pattern Lifecycle
    
    /// Records the start of a pattern or operation.
    @inlinable
    func recordPatternStart(
        _ pattern: Namespace,
        tags: [String: String] = [:]
    ) async {
        var enrichedTags = tags
        enrichedTags["phase"] = "start"
        await record(pattern, value: 1.0, type: .counter, tags: enrichedTags)
    }
    
    /// Records the successful completion of a pattern.
    @inlinable
    func recordPatternCompletion(
        _ pattern: Namespace,
        duration: TimeInterval? = nil,
        tags: [String: String] = [:]
    ) async {
        var enrichedTags = tags
        enrichedTags["phase"] = "complete"
        
        if let duration = duration {
            await record(pattern, value: duration, type: .histogram, tags: enrichedTags)
        } else {
            await record(pattern, value: 1.0, type: .counter, tags: enrichedTags)
        }
    }
    
    /// Records a pattern failure.
    @inlinable
    func recordPatternFailure(
        _ pattern: Namespace,
        error: Error,
        tags: [String: String] = [:]
    ) async {
        var enrichedTags = tags
        enrichedTags["phase"] = "fail"
        enrichedTags["error"] = String(describing: type(of: error))
        enrichedTags["reason"] = error.localizedDescription
        
        await record(pattern, value: 1.0, type: .counter, tags: enrichedTags)
    }
    
    // MARK: Resource Metrics
    
    /// Records a resource usage level (0.0 to 1.0).
    @inlinable
    func recordUsageLevel(
        _ metric: Namespace,
        percentage: Double,
        tags: [String: String] = [:]
    ) async {
        var enrichedTags = tags
        enrichedTags["percentage"] = String(Int(percentage * 100))
        await recordGauge(metric, value: percentage * 100, tags: enrichedTags)
    }
    
    /// Records a throttling event.
    @inlinable
    func recordThrottle(
        _ metric: Namespace,
        reason: String,
        tags: [String: String] = [:]
    ) async {
        var enrichedTags = tags
        enrichedTags["reason"] = reason
        enrichedTags["event"] = "throttle"
        await recordCounter(metric, tags: enrichedTags)
    }
    
    /// Records a safety rejection.
    @inlinable
    func recordSafetyRejection(
        _ metric: Namespace,
        reason: String,
        requested: String? = nil,
        tags: [String: String] = [:]
    ) async {
        var enrichedTags = tags
        enrichedTags["reason"] = reason
        enrichedTags["event"] = "rejection"
        if let requested = requested {
            enrichedTags["requested"] = requested
        }
        await recordCounter(metric, tags: enrichedTags)
    }
    
    // MARK: Performance Metrics
    
    /// Records operation latency in milliseconds.
    @inlinable
    func recordLatency(
        _ metric: Namespace,
        seconds: TimeInterval,
        tags: [String: String] = [:]
    ) async {
        await recordHistogram(metric, value: seconds * 1000, tags: tags)
    }
    
    /// Records operations per second.
    @inlinable
    func recordThroughput(
        _ metric: Namespace,
        operationsPerSecond: Double,
        tags: [String: String] = [:]
    ) async {
        await recordGauge(metric, value: operationsPerSecond, tags: tags)
    }
    
    // MARK: Batch Recording
    
    /// Records multiple metrics in a batch (for performance).
    func recordBatch(_ recordings: [(Namespace, Double, [String: String])]) async {
        guard metricCollector != nil else { return }
        
        for (name, value, tags) in recordings {
            await record(name, value: value, tags: tags)
        }
    }
}


// MARK: - Standard Metric Categories

/// Common metric categories that can be used as a reference for naming.
public enum StandardMetricCategory {
    /// Pattern lifecycle metrics
    public static let pattern = "pattern"
    
    /// Resource usage metrics
    public static let usage = "usage"
    
    /// Performance metrics
    public static let performance = "performance"
    
    /// Safety and throttling metrics
    public static let safety = "safety"
    
    /// System-level metrics
    public static let system = "system"
    
    /// Operation-specific metrics
    public static let operation = "operation"
}