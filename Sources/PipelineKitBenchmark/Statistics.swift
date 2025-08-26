import Foundation

/// Statistical analysis of benchmark timings.
public struct Statistics: Sendable {
    /// Number of samples.
    public let count: Int

    /// Mean (average) value.
    public let mean: TimeInterval

    /// Median value.
    public let median: TimeInterval

    /// Standard deviation.
    public let standardDeviation: TimeInterval

    /// Variance.
    public let variance: TimeInterval

    /// 50th percentile (same as median).
    public let p50: TimeInterval

    /// 90th percentile.
    public let p90: TimeInterval

    /// 95th percentile.
    public let p95: TimeInterval

    /// 99th percentile.
    public let p99: TimeInterval

    /// 99.9th percentile.
    public let p999: TimeInterval

    /// Minimum value.
    public let min: TimeInterval

    /// Maximum value.
    public let max: TimeInterval

    /// Range (max - min).
    public let range: TimeInterval

    /// Coefficient of variation (relative standard deviation).
    public let coefficientOfVariation: Double

    /// Outliers detected using IQR method.
    public let outliers: [TimeInterval]

    /// Initialize statistics from timing data.
    public init(timings: [TimeInterval]) {
        guard !timings.isEmpty else {
            // Handle empty case
            self.count = 0
            self.mean = 0
            self.median = 0
            self.standardDeviation = 0
            self.variance = 0
            self.p50 = 0
            self.p90 = 0
            self.p95 = 0
            self.p99 = 0
            self.p999 = 0
            self.min = 0
            self.max = 0
            self.range = 0
            self.coefficientOfVariation = 0
            self.outliers = []
            return
        }

        let sorted = timings.sorted()
        self.count = timings.count

        // Basic statistics
        // We already checked !timings.isEmpty, so first and last must exist
        self.min = sorted.first ?? 0
        self.max = sorted.last ?? 0
        self.range = max - min

        // Mean
        self.mean = timings.reduce(0, +) / Double(count)

        // Median and percentiles
        self.median = Self.percentile(sorted, 0.5)
        self.p50 = median
        self.p90 = Self.percentile(sorted, 0.9)
        self.p95 = Self.percentile(sorted, 0.95)
        self.p99 = Self.percentile(sorted, 0.99)
        self.p999 = Self.percentile(sorted, 0.999)

        // Variance and standard deviation
        let meanValue = self.mean // Capture mean before using in closure
        let squaredDifferences = timings.map { pow($0 - meanValue, 2) }
        self.variance = squaredDifferences.reduce(0, +) / Double(count)
        self.standardDeviation = sqrt(variance)

        // Coefficient of variation
        self.coefficientOfVariation = mean > 0 ? standardDeviation / mean : 0

        // Outlier detection using IQR method
        let q1 = Self.percentile(sorted, 0.25)
        let q3 = Self.percentile(sorted, 0.75)
        let iqr = q3 - q1
        let lowerBound = q1 - (1.5 * iqr)
        let upperBound = q3 + (1.5 * iqr)

        self.outliers = timings.filter { $0 < lowerBound || $0 > upperBound }
    }

    /// Calculate percentile from sorted array.
    private static func percentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }

        let index = Double(sorted.count - 1) * p
        let lower = Int(index)
        let upper = lower + 1
        let weight = index - Double(lower)

        if upper >= sorted.count {
            return sorted[lower]
        }

        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// Generate a summary report.
    public func summary() -> String {
        let formatter = DurationFormatter()

        return """
        Samples: \(count)
        Mean: \(formatter.format(mean))
        Median: \(formatter.format(median))
        Std Dev: \(formatter.format(standardDeviation))
        CV: \(String(format: "%.1f%%", coefficientOfVariation * 100))

        Percentiles:
          P50: \(formatter.format(p50))
          P90: \(formatter.format(p90))
          P95: \(formatter.format(p95))
          P99: \(formatter.format(p99))
          P99.9: \(formatter.format(p999))

        Range: \(formatter.format(min)) - \(formatter.format(max))
        Outliers: \(outliers.count)
        """
    }

    /// Check if results are stable (low variance).
    public var isStable: Bool {
        coefficientOfVariation < 0.1 // Less than 10% variation
    }

    /// Get confidence interval (95%).
    public var confidenceInterval95: (lower: TimeInterval, upper: TimeInterval) {
        let margin = 1.96 * (standardDeviation / sqrt(Double(count)))
        return (mean - margin, mean + margin)
    }
}

// MARK: - Statistical Comparison

public extension Statistics {
    /// Compare two sets of statistics.
    func compare(with other: Statistics) -> Comparison {
        Comparison(baseline: self, current: other)
    }

    /// Statistical comparison result.
    struct Comparison: Sendable {
        public let baseline: Statistics
        public let current: Statistics

        /// Percentage change in mean.
        public var meanChange: Double {
            guard baseline.mean > 0 else { return 0 }
            return ((current.mean - baseline.mean) / baseline.mean) * 100
        }

        /// Percentage change in median.
        public var medianChange: Double {
            guard baseline.median > 0 else { return 0 }
            return ((current.median - baseline.median) / baseline.median) * 100
        }

        /// Whether performance improved.
        public var improved: Bool {
            current.mean < baseline.mean
        }

        /// Calculate statistical significance using Welch's t-test.
        public var isSignificant: Bool {
            // Simplified t-test for unequal variances
            let s1 = baseline.variance / Double(baseline.count)
            let s2 = current.variance / Double(current.count)
            let tStatistic = abs(baseline.mean - current.mean) / sqrt(s1 + s2)

            // Using critical value for 95% confidence
            return tStatistic > 1.96
        }

        /// Generate comparison report.
        public func report() -> String {
            let formatter = DurationFormatter()

            return """
            Performance Comparison:

            Baseline:
              Mean: \(formatter.format(baseline.mean))
              Median: \(formatter.format(baseline.median))
              Std Dev: \(formatter.format(baseline.standardDeviation))

            Current:
              Mean: \(formatter.format(current.mean))
              Median: \(formatter.format(current.median))
              Std Dev: \(formatter.format(current.standardDeviation))

            Change:
              Mean: \(String(format: "%+.1f%%", meanChange))
              Median: \(String(format: "%+.1f%%", medianChange))
              Result: \(improved ? "Improvement" : "Regression")
              Significant: \(isSignificant ? "Yes" : "No")
            """
        }
    }
}
