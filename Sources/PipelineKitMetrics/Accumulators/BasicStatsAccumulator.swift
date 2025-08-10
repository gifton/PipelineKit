import Foundation

/// Efficient accumulator for basic statistics.
///
/// Tracks min, max, sum, mean, and last value with O(1) memory
/// regardless of the number of samples.
///
/// ## Memory Usage
/// Fixed ~88 bytes regardless of sample count.
public struct BasicStatsAccumulator: MetricAccumulator {
    public struct Config: Sendable {
        /// Whether to track the first value and timestamp.
        public let trackFirst: Bool

        /// Maximum age of samples before reset (nil = no expiry).
        public let maxAge: TimeInterval?

        public init(
            trackFirst: Bool = false,
            maxAge: TimeInterval? = nil
        ) {
            self.trackFirst = trackFirst
            self.maxAge = maxAge
        }

        /// Default configuration.
        public static let `default` = Config()
    }

    public struct Snapshot: Sendable, Equatable {
        public let count: Int
        public let sum: Double
        public let min: Double
        public let max: Double
        public let lastValue: Double
        public let lastTimestamp: Date
        public let firstValue: Double?
        public let firstTimestamp: Date?

        /// Checks if the snapshot contains any data.
        /// 
        /// We use count == 0 here because count is a stored property (O(1) access).
        /// This is the idiomatic way to implement isEmpty for value types with stored counts.
        public var isEmpty: Bool {
            // swiftlint:disable:next empty_count
            count == 0
        }

        /// Computed mean value.
        public var mean: Double {
            !isEmpty ? sum / Double(count) : 0
        }

        /// Range between min and max.
        public var range: Double {
            !isEmpty ? max - min : 0
        }

        /// Standard deviation (if variance tracking was enabled).
        public var stdDev: Double? {
            nil // Not tracked in basic accumulator
        }
    }

    // MARK: - Properties

    private let config: Config
    private var _count: Int = 0
    private var sum: Double = 0
    private var min: Double = .infinity
    private var max: Double = -.infinity
    private var lastValue: Double = 0
    private var lastTimestamp = Date()
    private var firstValue: Double?
    private var firstTimestamp: Date?

    public var count: Int { _count }

    // MARK: - Initialization

    public init(config: Config = .default) {
        self.config = config
    }

    // MARK: - MetricAccumulator

    public mutating func record(_ value: Double, at timestamp: Date) {
        // Check for expiry
        if let maxAge = config.maxAge {
            if let first = firstTimestamp, timestamp.timeIntervalSince(first) > maxAge {
                reset()
            }
        }

        // Track first value if configured
        if config.trackFirst && firstValue == nil {
            firstValue = value
            firstTimestamp = timestamp
        }

        // Update statistics
        _count += 1
        sum += value
        min = Swift.min(min, value)
        max = Swift.max(max, value)
        lastValue = value
        lastTimestamp = timestamp
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            count: _count,
            sum: sum,
            min: _count > 0 ? min : 0,
            max: _count > 0 ? max : 0,
            lastValue: lastValue,
            lastTimestamp: lastTimestamp,
            firstValue: firstValue,
            firstTimestamp: firstTimestamp
        )
    }

    public mutating func reset() {
        _count = 0
        sum = 0
        min = .infinity
        max = -.infinity
        lastValue = 0
        lastTimestamp = Date()
        firstValue = nil
        firstTimestamp = nil
    }
}

// MARK: - Extensions

extension BasicStatsAccumulator: CustomStringConvertible {
    public var description: String {
        let snap = snapshot()
        return "BasicStats(count: \(snap.count), mean: \(String(format: "%.2f", snap.mean)), range: [\(snap.min)...\(snap.max)])"
    }
}
