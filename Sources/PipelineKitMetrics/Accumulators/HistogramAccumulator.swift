import Foundation

/// Accumulator for histogram metrics with percentile support.
///
/// Uses a simple sorted array approach for v0.1.0.
/// Will be replaced with T-Digest or HDRHistogram in future versions.
///
/// ## Memory Usage
/// O(n) where n is maxSamples (default: 1000)
public struct HistogramAccumulator: MetricAccumulator {
    public struct Config: Sendable {
        /// Maximum samples to keep for percentile calculation.
        public let maxSamples: Int

        /// Percentiles to calculate.
        public let percentiles: [Double]

        /// Histogram buckets for distribution.
        public let buckets: [Double]

        public init(
            maxSamples: Int = 1000,
            percentiles: [Double] = [0.5, 0.9, 0.95, 0.99, 0.999],
            buckets: [Double] = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
        ) {
            self.maxSamples = maxSamples
            self.percentiles = percentiles.sorted()
            self.buckets = buckets.sorted()
        }

        /// Default configuration.
        public static let `default` = Config()
    }

    public struct Snapshot: Sendable, Equatable {
        public let count: Int
        public let sum: Double
        public let min: Double
        public let max: Double
        public let mean: Double
        public let percentiles: [Double: Double]
        public let buckets: [Double: Int]

        /// Get a specific percentile value.
        public func percentile(_ p: Double) -> Double? {
            percentiles[p]
        }

        /// Common percentile accessors.
        public var p50: Double? { percentiles[0.5] }
        public var p90: Double? { percentiles[0.9] }
        public var p95: Double? { percentiles[0.95] }
        public var p99: Double? { percentiles[0.99] }
        public var p999: Double? { percentiles[0.999] }
    }

    // MARK: - Properties

    private let config: Config
    private var samples: [Double] = []
    private var _count: Int = 0
    private var sum: Double = 0
    private var min: Double = .infinity
    private var max: Double = -.infinity
    private var needsSort = false

    public var count: Int { _count }

    // MARK: - Initialization

    public init(config: Config = .default) {
        self.config = config
        samples.reserveCapacity(config.maxSamples)
    }

    // MARK: - MetricAccumulator

    public mutating func record(_ value: Double, at timestamp: Date) {
        _count += 1
        sum += value
        min = Swift.min(min, value)
        max = Swift.max(max, value)

        // Add to samples for percentile calculation
        if samples.count < config.maxSamples {
            samples.append(value)
            needsSort = true
        } else {
            // Reservoir sampling for even distribution
            let index = Int.random(in: 0..<_count)
            if index < config.maxSamples {
                samples[index] = value
                needsSort = true
            }
        }
    }

    public func snapshot() -> Snapshot {
        guard !isEmpty else {
            return Snapshot(
                count: 0,
                sum: 0,
                min: 0,
                max: 0,
                mean: 0,
                percentiles: [:],
                buckets: [:]
            )
        }

        // Sort samples if needed
        var sortedSamples = samples
        if needsSort {
            sortedSamples.sort()
        }

        // Calculate percentiles
        var percentileValues: [Double: Double] = [:]
        for p in config.percentiles {
            if let value = calculatePercentile(sortedSamples, percentile: p) {
                percentileValues[p] = value
            }
        }

        // Calculate bucket counts
        var bucketCounts: [Double: Int] = [:]
        for bucket in config.buckets {
            bucketCounts[bucket] = sortedSamples.filter { $0 <= bucket }.count
        }

        return Snapshot(
            count: _count,
            sum: sum,
            min: min,
            max: max,
            mean: sum / Double(_count),
            percentiles: percentileValues,
            buckets: bucketCounts
        )
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        _count = 0
        sum = 0
        min = .infinity
        max = -.infinity
        needsSort = false
    }

    // MARK: - Private Methods

    private func calculatePercentile(_ sorted: [Double], percentile: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }

        let index = percentile * Double(sorted.count - 1)
        let lower = Int(index)
        let upper = lower + 1
        let weight = index - Double(lower)

        if upper >= sorted.count {
            return sorted[lower]
        }

        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}

// MARK: - Extensions

extension HistogramAccumulator: CustomStringConvertible {
    public var description: String {
        let snap = snapshot()
        return "Histogram(count: \(snap.count), mean: \(String(format: "%.2f", snap.mean)), p50: \(snap.p50 ?? 0), p99: \(snap.p99 ?? 0))"
    }
}
