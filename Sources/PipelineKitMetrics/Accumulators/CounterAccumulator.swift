import Foundation

/// Accumulator optimized for counter metrics.
///
/// Tracks monotonically increasing values with rate calculation support.
/// Ideal for request counts, bytes processed, errors, etc.
///
/// ## Memory Usage
/// Fixed ~80 bytes regardless of sample count.
public struct CounterAccumulator: MetricAccumulator {
    public struct Config: Sendable {
        /// Whether to validate monotonic increase.
        public let enforceMonotonic: Bool

        /// Whether to calculate rate metrics.
        public let trackRate: Bool

        public init(
            enforceMonotonic: Bool = true,
            trackRate: Bool = true
        ) {
            self.enforceMonotonic = enforceMonotonic
            self.trackRate = trackRate
        }

        /// Default configuration.
        public static let `default` = Config()
    }

    public struct Snapshot: Sendable, Equatable {
        public let count: Int
        public let sum: Double
        public let firstValue: Double
        public let firstTimestamp: Date
        public let lastValue: Double
        public let lastTimestamp: Date

        /// Total increase from first to last value.
        public var increase: Double {
            lastValue - firstValue
        }

        /// Rate of increase per second.
        public var rate: Double {
            guard firstTimestamp < lastTimestamp else { return 0 }
            let duration = lastTimestamp.timeIntervalSince(firstTimestamp)
            return duration > 0 ? increase / duration : 0
        }

        /// Average increment per operation.
        public var averageIncrement: Double {
            count > 1 ? increase / Double(count - 1) : 0
        }
    }

    // MARK: - Properties

    private let config: Config
    private var _count: Int = 0
    private var sum: Double = 0
    private var firstValue: Double = 0
    private var firstTimestamp = Date()
    private var lastValue: Double = 0
    private var lastTimestamp = Date()
    private var isFirst = true

    public var count: Int { _count }

    // MARK: - Initialization

    public init(config: Config = .default) {
        self.config = config
    }

    // MARK: - MetricAccumulator

    public mutating func record(_ value: Double, at timestamp: Date) {
        // Validate monotonic increase if configured
        if config.enforceMonotonic && !isFirst && value < lastValue {
            // Counter decreased, this might be a reset
            // Record as if starting fresh
            reset()
        }

        if isFirst {
            firstValue = value
            firstTimestamp = timestamp
            isFirst = false
        }

        _count += 1
        sum += value
        lastValue = value
        lastTimestamp = timestamp
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            count: _count,
            sum: sum,
            firstValue: firstValue,
            firstTimestamp: firstTimestamp,
            lastValue: lastValue,
            lastTimestamp: lastTimestamp
        )
    }

    public mutating func reset() {
        _count = 0
        sum = 0
        firstValue = 0
        firstTimestamp = Date()
        lastValue = 0
        lastTimestamp = Date()
        isFirst = true
    }
}

// MARK: - Extensions

extension CounterAccumulator: CustomStringConvertible {
    public var description: String {
        let snap = snapshot()
        return "Counter(count: \(snap.count), increase: \(snap.increase), rate: \(String(format: "%.2f", snap.rate))/s)"
    }
}

// MARK: - Counter Validation

public extension CounterAccumulator {
    /// Check if a value is valid for this counter.
    ///
    /// - Parameter value: The value to validate
    /// - Returns: true if the value maintains monotonic increase
    func isValidValue(_ value: Double) -> Bool {
        if isEmpty {
            return value >= 0 // Counters should start at 0 or positive
        }
        return !config.enforceMonotonic || value >= lastValue
    }
}
