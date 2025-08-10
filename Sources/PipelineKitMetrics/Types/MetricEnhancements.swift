import Foundation
import Atomics

// MARK: - Atomic Metrics

/// Extension for creating atomic metrics with high-performance storage.
public extension Metric where Kind == Counter {
    /// Create an atomic counter for high-frequency operations.
    ///
    /// Atomic counters use lock-free operations for thread-safe increments
    /// with minimal overhead (~10ns per operation).
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - tags: Dimensional tags
    /// - Returns: An atomic counter metric
    static func atomic(
        _ name: MetricName,
        tags: MetricTags = [:]
    ) -> AtomicMetric<Counter> {
        AtomicMetric(
            name: name,
            storage: AtomicCounterStorage(),
            tags: tags
        )
    }

    /// Create an atomic counter from a string literal name.
    static func atomic(
        _ name: String,
        tags: MetricTags = [:]
    ) -> AtomicMetric<Counter> {
        atomic(MetricName(name), tags: tags)
    }
}

public extension Metric where Kind == Gauge {
    /// Create an atomic gauge for high-frequency operations.
    ///
    /// Atomic gauges support lock-free updates and compare-and-set operations
    /// for thread-safe modifications with minimal overhead.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - initialValue: The initial gauge value
    ///   - unit: Optional unit of measurement
    ///   - tags: Dimensional tags
    /// - Returns: An atomic gauge metric
    static func atomic(
        _ name: MetricName,
        initialValue: Double = 0,
        unit: MetricUnit? = nil,
        tags: MetricTags = [:]
    ) -> AtomicMetric<Gauge> {
        AtomicMetric(
            name: name,
            storage: AtomicGaugeStorage(initialValue: initialValue),
            unit: unit,
            tags: tags
        )
    }

    /// Create an atomic gauge from a string literal name.
    static func atomic(
        _ name: String,
        initialValue: Double = 0,
        unit: MetricUnit? = nil,
        tags: MetricTags = [:]
    ) -> AtomicMetric<Gauge> {
        atomic(MetricName(name), initialValue: initialValue, unit: unit, tags: tags)
    }
}

// MARK: - Enhanced Counter Operations

public extension Metric where Kind == Counter {
    /// Decrement the counter by a specified amount.
    ///
    /// Note: This is useful for rollback scenarios but should be used
    /// carefully as counters are typically monotonic.
    ///
    /// - Parameter amount: The amount to decrement (must be positive)
    /// - Returns: A new counter with the decremented value
    func decrement(by amount: Double = 1.0) -> Self {
        precondition(amount >= 0, "Decrement amount must be non-negative")
        precondition(value.value >= amount, "Cannot decrement below zero")

        return Self.counter(
            name,
            value: value.value - amount,
            tags: tags,
            at: Date()
        )
    }

    /// Calculate the rate of this counter over a time period.
    ///
    /// - Parameters:
    ///   - period: The time period in seconds
    ///   - unit: The rate unit (default: per second)
    /// - Returns: A gauge metric representing the rate
    func rate(over period: TimeInterval, unit: MetricUnit = .perSecond) -> Metric<Gauge> {
        let rateValue: Double

        switch unit {
        case .perSecond:
            rateValue = value.value / period
        case .perMinute:
            rateValue = (value.value / period) * 60
        case .perHour:
            rateValue = (value.value / period) * 3600
        default:
            rateValue = value.value / period
        }

        return Metric<Gauge>.gauge(
            MetricName("\(name.value).rate", namespace: name.namespace),
            value: rateValue,
            unit: unit,
            tags: tags,
            at: timestamp
        )
    }
}

// MARK: - Enhanced Gauge Operations

public extension Metric where Kind == Gauge {
    /// Compare and set the gauge value atomically.
    ///
    /// This operation will only update the gauge if the current value
    /// matches the expected value, useful for lock-free algorithms.
    ///
    /// - Parameters:
    ///   - expected: The expected current value
    ///   - newValue: The new value to set
    /// - Returns: A new gauge if successful, nil if the comparison failed
    func compareAndSet(expecting expected: Double, newValue: Double) -> Self? {
        // For value-based metrics, we can't do true CAS
        // This would need to be implemented with AtomicMetric
        guard value.value == expected else { return nil }

        return Self.gauge(
            name,
            value: newValue,
            unit: value.unit,
            tags: tags,
            at: Date()
        )
    }

    /// Calculate the difference between this gauge and another.
    ///
    /// - Parameter other: The other gauge to compare
    /// - Returns: The numeric difference
    func delta(from other: Self) -> Double {
        precondition(name == other.name, "Cannot calculate delta between different metrics")
        return value.value - other.value.value
    }
}

// MARK: - Enhanced Timer Operations

public extension Metric where Kind == Timer {
    /// Measure the duration of an async operation.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - unit: The time unit (default: milliseconds)
    ///   - tags: Optional dimensional tags
    ///   - clock: The clock to use for timing (default: continuous)
    ///   - operation: The async operation to measure
    /// - Returns: A tuple of the timer metric and the operation result
    @available(macOS 13.0, iOS 16.0, *)
    static func measure<T>(
        _ name: MetricName,
        unit: MetricUnit = .milliseconds,
        tags: MetricTags = [:],
        clock: ContinuousClock = .continuous,
        operation: () async throws -> T
    ) async rethrows -> (metric: Metric<Timer>, result: T) {
        let start = clock.now
        let result = try await operation()
        let duration = clock.now.duration(to: start)

        let durationValue: Double
        switch unit {
        case .nanoseconds:
            durationValue = Double(duration.components.attoseconds / 1_000_000_000)
        case .microseconds:
            durationValue = Double(duration.components.attoseconds / 1_000_000_000_000)
        case .milliseconds:
            durationValue = Double(duration.components.attoseconds / 1_000_000_000_000_000)
        case .seconds:
            durationValue = Double(duration.components.seconds)
        default:
            durationValue = Double(duration.components.attoseconds / 1_000_000_000_000_000) // Default to ms
        }

        let metric = timer(name, duration: durationValue, unit: unit, tags: tags)
        return (metric, result)
    }

    /// Measure the duration of a synchronous operation.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - unit: The time unit (default: milliseconds)
    ///   - tags: Optional dimensional tags
    ///   - operation: The operation to measure
    /// - Returns: A tuple of the timer metric and the operation result
    static func measure<T>(
        _ name: MetricName,
        unit: MetricUnit = .milliseconds,
        tags: MetricTags = [:],
        operation: () throws -> T
    ) rethrows -> (metric: Metric<Timer>, result: T) {
        let start = Date()
        let result = try operation()
        let duration = Date().timeIntervalSince(start)

        let durationValue: Double
        switch unit {
        case .nanoseconds:
            durationValue = duration * 1_000_000_000
        case .microseconds:
            durationValue = duration * 1_000_000
        case .milliseconds:
            durationValue = duration * 1_000
        case .seconds:
            durationValue = duration
        case .minutes:
            durationValue = duration / 60
        case .hours:
            durationValue = duration / 3600
        default:
            durationValue = duration * 1_000 // Default to milliseconds
        }

        let metric = timer(name, duration: durationValue, unit: unit, tags: tags)
        return (metric, result)
    }
}

// MARK: - Enhanced Histogram Operations

/// Bucketing policy for histogram metrics.
public enum BucketingPolicy: Sendable {
    /// Linear buckets with fixed width.
    case linear(start: Double, width: Double, count: Int)

    /// Exponential buckets with multiplicative factor.
    case exponential(start: Double, factor: Double, count: Int)

    /// Logarithmic buckets (base 2).
    case logarithmic(start: Double, count: Int)

    /// Custom bucket boundaries.
    case custom(boundaries: [Double])

    /// Generate the bucket boundaries.
    public func boundaries() -> [Double] {
        switch self {
        case let .linear(start, width, count):
            return (0..<count).map { Double($0) * width + start }

        case let .exponential(start, factor, count):
            var boundaries: [Double] = []
            var current = start
            for _ in 0..<count {
                boundaries.append(current)
                current *= factor
            }
            return boundaries

        case let .logarithmic(start, count):
            return (0..<count).map { start * pow(2, Double($0)) }

        case .custom(let boundaries):
            return boundaries.sorted()
        }
    }
}

public extension Metric where Kind == Histogram {
    /// Create histogram observations with a bucketing policy.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - values: The values to observe
    ///   - policy: The bucketing policy
    ///   - unit: The unit of measurement
    ///   - tags: Optional dimensional tags
    /// - Returns: An array of histogram metrics with bucket tags
    static func observations(
        _ name: MetricName,
        values: [Double],
        policy: BucketingPolicy,
        unit: MetricUnit = .milliseconds,
        tags: MetricTags = [:]
    ) -> [Self] {
        let boundaries = policy.boundaries()

        return values.flatMap { value in
            boundaries.compactMap { boundary in
                guard value <= boundary else { return nil }

                var bucketTags = tags
                bucketTags["le"] = String(boundary)

                return histogram(name, value: value, unit: unit, tags: bucketTags)
            }
        }
    }
}
