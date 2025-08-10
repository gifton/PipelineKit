import Foundation
import PipelineKitCore

/// A type-safe metric with compile-time guarantees.
///
/// The Metric type uses phantom types to ensure that metric-specific
/// operations are only available on the appropriate metric types,
/// preventing entire classes of bugs at compile time.
///
/// ## Usage
/// ```swift
/// let counter = Metric<Counter>.counter("requests")
/// let histogram = Metric<Histogram>.histogram("latency", value: 125.5, unit: .milliseconds)
/// let gauge = Metric<Gauge>.gauge("memory.usage", value: 0.75, unit: .percentage)
/// ```
public struct Metric<Kind: MetricKind>: Sendable {
    /// The name of the metric.
    public let name: MetricName

    /// The value of the metric.
    public let value: MetricValue

    /// When the metric was recorded.
    public let timestamp: Date

    /// Dimensional tags for the metric.
    public let tags: MetricTags

    /// Internal initializer for use within the module.
    // swiftlint:disable:next unneeded_synthesized_initializer
    internal init(
        name: MetricName,
        value: MetricValue,
        timestamp: Date,
        tags: MetricTags
    ) {
        self.name = name
        self.value = value
        self.timestamp = timestamp
        self.tags = tags
    }
}

// MARK: - Counter Factory Methods

public extension Metric where Kind == Counter {
    /// Create a counter metric.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - value: The counter value (default: 1)
    ///   - tags: Dimensional tags
    ///   - timestamp: When the metric was recorded
    /// - Returns: A counter metric
    static func counter(
        _ name: MetricName,
        value: Double = 1.0,
        tags: MetricTags = [:],
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            name: name,
            value: MetricValue(value, unit: .count),
            timestamp: timestamp,
            tags: tags
        )
    }

    /// Increment this counter by a specified amount.
    ///
    /// - Parameter amount: The amount to increment (default: 1)
    /// - Returns: A new counter with the incremented value
    func increment(by amount: Double = 1.0) -> Self {
        Self(
            name: name,
            value: MetricValue(value.value + amount, unit: .count),
            timestamp: Date(),
            tags: tags
        )
    }

    /// Reset this counter to zero.
    ///
    /// - Returns: A new counter with value 0
    func reset() -> Self {
        Self(
            name: name,
            value: MetricValue(0, unit: .count),
            timestamp: Date(),
            tags: tags
        )
    }
}

// MARK: - Gauge Factory Methods

public extension Metric where Kind == Gauge {
    /// Create a gauge metric.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - value: The gauge value
    ///   - unit: Optional unit of measurement
    ///   - tags: Dimensional tags
    ///   - timestamp: When the metric was recorded
    /// - Returns: A gauge metric
    static func gauge(
        _ name: MetricName,
        value: Double,
        unit: MetricUnit? = nil,
        tags: MetricTags = [:],
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            name: name,
            value: MetricValue(value, unit: unit),
            timestamp: timestamp,
            tags: tags
        )
    }

    /// Update this gauge to a new value.
    ///
    /// - Parameter newValue: The new gauge value
    /// - Returns: A new gauge with the updated value
    func update(to newValue: Double) -> Self {
        Self(
            name: name,
            value: MetricValue(newValue, unit: value.unit),
            timestamp: Date(),
            tags: tags
        )
    }

    /// Adjust this gauge by a delta.
    ///
    /// - Parameter delta: The amount to adjust (can be negative)
    /// - Returns: A new gauge with the adjusted value
    func adjust(by delta: Double) -> Self {
        Self(
            name: name,
            value: MetricValue(value.value + delta, unit: value.unit),
            timestamp: Date(),
            tags: tags
        )
    }
}

// MARK: - Histogram Factory Methods

public extension Metric where Kind == Histogram {
    /// Create a histogram metric.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - value: The sample value
    ///   - unit: Unit of measurement (default: milliseconds)
    ///   - tags: Dimensional tags
    ///   - timestamp: When the metric was recorded
    /// - Returns: A histogram metric
    static func histogram(
        _ name: MetricName,
        value: Double,
        unit: MetricUnit = .milliseconds,
        tags: MetricTags = [:],
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            name: name,
            value: MetricValue(value, unit: unit),
            timestamp: timestamp,
            tags: tags
        )
    }

    /// Record a new sample in this histogram.
    ///
    /// - Parameter sample: The sample value to record
    /// - Returns: A new histogram metric with the sample
    func record(_ sample: Double) -> Self {
        Self(
            name: name,
            value: MetricValue(sample, unit: value.unit),
            timestamp: Date(),
            tags: tags
        )
    }
}

// MARK: - Timer Factory Methods

public extension Metric where Kind == Timer {
    /// Create a timer metric.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - duration: The duration to record
    ///   - unit: Unit of measurement (default: milliseconds)
    ///   - tags: Dimensional tags
    ///   - timestamp: When the metric was recorded
    /// - Returns: A timer metric
    static func timer(
        _ name: MetricName,
        duration: TimeInterval,
        unit: MetricUnit = .milliseconds,
        tags: MetricTags = [:],
        at timestamp: Date = Date()
    ) -> Self {
        let value: Double
        switch unit {
        case .nanoseconds:
            value = duration * 1_000_000_000
        case .microseconds:
            value = duration * 1_000_000
        case .milliseconds:
            value = duration * 1_000
        case .seconds:
            value = duration
        default:
            value = duration * 1_000 // Default to milliseconds
        }

        return Self(
            name: name,
            value: MetricValue(value, unit: unit),
            timestamp: timestamp,
            tags: tags
        )
    }

    /// Start timing an operation.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - tags: Dimensional tags
    /// - Returns: A timing context that records duration when completed
    static func startTimer(
        _ name: MetricName,
        tags: MetricTags = [:]
    ) -> TimingContext<Kind> {
        TimingContext(name: name, tags: tags, startTime: Date())
    }
}

// MARK: - Timing Context

/// A context for timing operations.
public struct TimingContext<Kind: MetricKind>: Sendable {
    let name: MetricName
    let tags: MetricTags
    let startTime: Date

    /// Complete the timing and create a metric.
    ///
    /// - Parameter unit: The unit for the duration (default: milliseconds)
    /// - Returns: A timer metric with the recorded duration
    public func complete(unit: MetricUnit = .milliseconds) -> Metric<Timer> where Kind == Timer {
        let duration = Date().timeIntervalSince(startTime)
        return Metric<Timer>.timer(name, duration: duration, unit: unit, tags: tags)
    }
}

// MARK: - Type Erasure

// MetricSnapshot is now defined in PipelineKitCore to avoid circular dependencies
// We extend it here with convenience methods for converting from typed metrics

public extension MetricSnapshot {
    /// Create a snapshot from a typed metric.
    init<K: MetricKind>(from metric: Metric<K>) {
        self.init(
            name: metric.name.fullName,
            type: K.type.rawValue,
            value: metric.value.value,
            timestamp: metric.timestamp,
            tags: metric.tags,
            unit: metric.value.unit?.rawValue
        )
    }
}

// Extension to create from Metric
public extension Metric {
    /// Convert this metric to a snapshot.
    func snapshot() -> MetricSnapshot {
        MetricSnapshot(from: self)
    }
}
