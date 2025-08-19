import Foundation

/// A type-safe metric with compile-time guarantees.
///
/// Uses phantom types to ensure metric-specific operations are only
/// available on the appropriate metric types.
public struct Metric<Kind: MetricKind>: Sendable {
    /// The name of the metric.
    public let name: String
    
    /// The value of the metric.
    public let value: Double
    
    /// When the metric was recorded.
    public let timestamp: Date
    
    /// Dimensional tags for the metric.
    public let tags: [String: String]
    
    /// Optional unit of measurement.
    public let unit: String?
    
    /// Creates a new metric.
    public init(
        name: String,
        value: Double,
        timestamp: Date = Date(),
        tags: [String: String] = [:],
        unit: String? = nil
    ) {
        self.name = name
        self.value = value
        self.timestamp = timestamp
        self.tags = tags
        self.unit = unit
    }
}

// MARK: - Counter Methods

public extension Metric where Kind == Counter {
    /// Creates a counter metric.
    static func counter(
        _ name: String,
        value: Double = 1.0,
        tags: [String: String] = [:]
    ) -> Self {
        Self(name: name, value: value, tags: tags)
    }
}

// MARK: - Gauge Methods

public extension Metric where Kind == Gauge {
    /// Creates a gauge metric.
    static func gauge(
        _ name: String,
        value: Double,
        tags: [String: String] = [:],
        unit: String? = nil
    ) -> Self {
        Self(name: name, value: value, tags: tags, unit: unit)
    }
}

// MARK: - Timer Methods

public extension Metric where Kind == PipelineTimer {
    /// Creates a timer metric from a duration.
    static func timer(
        _ name: String,
        duration: TimeInterval,
        tags: [String: String] = [:]
    ) -> Self {
        Self(
            name: name,
            value: duration, // Already in the expected unit
            tags: tags,
            unit: "ms"
        )
    }
}

// MARK: - Histogram Methods

public extension Metric where Kind == Histogram {
    /// Creates a histogram metric.
    static func histogram(
        _ name: String,
        value: Double,
        tags: [String: String] = [:],
        unit: String? = nil
    ) -> Self {
        Self(name: name, value: value, tags: tags, unit: unit)
    }
}

// MARK: - Conversion

public extension Metric {
    /// Converts this metric to a snapshot.
    func toSnapshot() -> MetricSnapshot {
        MetricSnapshot(
            name: name,
            type: Kind.type.rawValue,
            value: value,
            timestamp: UInt64(timestamp.timeIntervalSince1970 * 1000),
            tags: tags,
            unit: unit
        )
    }
}