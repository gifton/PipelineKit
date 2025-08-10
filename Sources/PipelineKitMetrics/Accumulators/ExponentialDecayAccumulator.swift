import Foundation

/// Accumulator using Exponentially Weighted Moving Average (EWMA).
///
/// Implements EWMA for mean and EWMV for variance with numerical stability
/// using Welford's algorithm adapted for exponential weighting.
///
/// ## Algorithm
/// Uses exponential decay where recent values have more weight:
/// - Weight decays by factor α = exp(-λΔt) where λ = ln(2)/halfLife
/// - EWMA: μ(t) = α·μ(t-1) + (1-α)·x(t)
/// - EWMV: σ²(t) = α·σ²(t-1) + (1-α)·(x(t) - μ(t-1))²
///
/// ## Memory Usage
/// Fixed ~120 bytes regardless of sample count.
///
/// ## Numerical Stability
/// - Uses Welford's online algorithm for variance
/// - Prevents underflow with minimum weight threshold
/// - Handles time anomalies gracefully
public struct ExponentialDecayAccumulator: MetricAccumulator {
    public struct Config: Sendable {
        /// Half-life for exponential decay (seconds).
        public let halfLife: TimeInterval

        /// Warm-up period before decay kicks in (seconds).
        public let warmupPeriod: TimeInterval

        /// Minimum weight threshold to prevent underflow.
        public let minWeight: Double

        /// Whether to use bias correction for early samples.
        public let useBiasCorrection: Bool

        public init(
            halfLife: TimeInterval = 60.0,
            warmupPeriod: TimeInterval = 5.0,
            minWeight: Double = 1e-10,
            useBiasCorrection: Bool = true
        ) {
            self.halfLife = halfLife
            self.warmupPeriod = warmupPeriod
            self.minWeight = minWeight
            self.useBiasCorrection = useBiasCorrection
        }

        /// Default configuration with 1-minute half-life.
        public static let `default` = Config()

        /// Fast decay for real-time metrics (5-second half-life).
        public static let fast = Config(halfLife: 5.0, warmupPeriod: 1.0)

        /// Slow decay for long-term trends (5-minute half-life).
        public static let slow = Config(halfLife: 300.0, warmupPeriod: 30.0)
    }

    public struct Snapshot: Sendable, Equatable {
        public let count: Int
        public let ewma: Double
        public let ewmv: Double
        public let min: Double
        public let max: Double
        public let lastValue: Double
        public let lastTimestamp: Date
        public let effectiveWeight: Double

        /// Exponentially weighted standard deviation.
        public var ewmStdDev: Double {
            sqrt(Swift.max(0, ewmv))
        }

        /// Coefficient of variation (relative standard deviation).
        public var cv: Double {
            abs(ewma) > 1e-10 ? ewmStdDev / abs(ewma) : 0
        }

        /// 95% confidence interval bounds.
        public var confidenceInterval: (lower: Double, upper: Double) {
            let margin = 1.96 * ewmStdDev
            return (ewma - margin, ewma + margin)
        }
    }

    // MARK: - Properties

    private let config: Config
    private let lambda: Double  // Decay rate = ln(2) / halfLife

    // Core statistics
    private var _count: Int = 0
    private var ewma: Double = 0  // Exponentially weighted mean
    private var ewmv: Double = 0  // Exponentially weighted variance
    private var min: Double = .infinity
    private var max: Double = -.infinity

    // Tracking
    private var lastValue: Double = 0
    private var lastTimestamp: Date
    private var firstTimestamp: Date?
    private var totalWeight: Double = 0  // Sum of all weights for bias correction

    public var count: Int { _count }

    // MARK: - Initialization

    public init(config: Config = .default) {
        self.config = config
        self.lambda = log(2.0) / config.halfLife
        self.lastTimestamp = Date()
    }

    // MARK: - MetricAccumulator

    public mutating func record(_ value: Double, at timestamp: Date) {
        // Handle first sample
        if firstTimestamp == nil {
            firstTimestamp = timestamp
            ewma = value
            ewmv = 0
            min = value
            max = value
            lastValue = value
            lastTimestamp = timestamp
            _count = 1
            totalWeight = 1.0
            return
        }

        // Calculate time delta and decay factor
        let deltaTime = timestamp.timeIntervalSince(lastTimestamp)

        // Handle time anomalies
        guard deltaTime >= 0 else {
            // Timestamp went backwards, ignore decay
            updateWithoutDecay(value: value, timestamp: timestamp)
            return
        }

        // Check if we're still in warmup period
        // firstTimestamp is guaranteed to be non-nil here due to check at line 116
        guard let firstTime = firstTimestamp else {
            // This should never happen, but handle gracefully
            updateWithoutDecay(value: value, timestamp: timestamp)
            return
        }
        let timeSinceStart = timestamp.timeIntervalSince(firstTime)
        let isWarmup = timeSinceStart < config.warmupPeriod

        // Calculate decay factor (α)
        let alpha: Double
        if isWarmup || deltaTime == 0 {
            // No decay during warmup or zero time delta
            alpha = 1.0
        } else {
            // α = exp(-λΔt) with clamping to prevent underflow
            // This preserves historical data instead of resetting
            let rawAlpha = exp(-lambda * deltaTime)
            alpha = Swift.max(rawAlpha, config.minWeight)
        }

        // Store previous mean for variance calculation
        let previousMean = ewma

        // Update EWMA: μ(t) = α·μ(t-1) + (1-α)·x(t)
        ewma = alpha * ewma + (1 - alpha) * value

        // Update EWMV using Welford's method adapted for exponential weighting
        // σ²(t) = α·σ²(t-1) + (1-α)·(x(t) - μ(t-1))²
        let delta = value - previousMean
        ewmv = alpha * ewmv + (1 - alpha) * delta * delta

        // Apply bias correction if configured
        if config.useBiasCorrection && !isWarmup {
            // Track total weight for bias correction
            // Cap totalWeight to prevent overflow in bias correction
            totalWeight = Swift.min(alpha * totalWeight + (1 - alpha), 1e6)

            // Correct for bias in early samples
            if totalWeight > 0 && totalWeight < 1e6 {
                let biasCorrection = 1.0 / totalWeight
                ewma *= biasCorrection
                ewmv *= biasCorrection
            }
        }

        // Update min/max with decay consideration
        // Recent values should influence bounds more
        if alpha < 0.5 {
            // Significant decay, allow bounds to adjust
            min = Swift.min(min * alpha + value * (1 - alpha), value)
            max = Swift.max(max * alpha + value * (1 - alpha), value)
        } else {
            // Minimal decay, use traditional min/max
            min = Swift.min(min, value)
            max = Swift.max(max, value)
        }

        // Update tracking
        _count += 1
        lastValue = value
        lastTimestamp = timestamp
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            count: _count,
            ewma: ewma,
            ewmv: ewmv,
            min: _count > 0 ? min : 0,
            max: _count > 0 ? max : 0,
            lastValue: lastValue,
            lastTimestamp: lastTimestamp,
            effectiveWeight: totalWeight
        )
    }

    public mutating func reset() {
        _count = 0
        ewma = 0
        ewmv = 0
        min = .infinity
        max = -.infinity
        lastValue = 0
        lastTimestamp = Date()
        firstTimestamp = nil
        totalWeight = 0
    }

    // MARK: - Private Methods

    private mutating func updateWithoutDecay(value: Double, timestamp: Date) {
        // Simple update without decay for time anomalies
        _count += 1

        // Store old mean for variance calculation
        let n = Double(_count)
        let oldMean = ewma

        // Update mean
        ewma = ((n - 1) * ewma + value) / n

        // Update variance using Welford's two-pass formula
        // This correctly handles the variance calculation
        let delta = value - oldMean
        ewmv = ((n - 1) * ewmv + delta * (value - ewma)) / n

        // Standard min/max
        min = Swift.min(min, value)
        max = Swift.max(max, value)

        lastValue = value
        lastTimestamp = timestamp
    }
}

// MARK: - Extensions

extension ExponentialDecayAccumulator: CustomStringConvertible {
    public var description: String {
        let snap = snapshot()
        return """
            ExponentialDecay(
                count: \(snap.count),
                ewma: \(String(format: "%.2f", snap.ewma)),
                stdDev: \(String(format: "%.2f", snap.ewmStdDev)),
                range: [\(String(format: "%.2f", snap.min))...\(String(format: "%.2f", snap.max))],
                weight: \(String(format: "%.4f", snap.effectiveWeight))
            )
            """
    }
}

// MARK: - Decay Rate Helpers

public extension ExponentialDecayAccumulator.Config {
    /// Create config with specific decay rate.
    ///
    /// - Parameter decayRate: Fraction of weight lost per second (0...1)
    /// - Returns: Configuration with corresponding half-life
    static func withDecayRate(_ decayRate: Double) -> ExponentialDecayAccumulator.Config {
        let halfLife = log(2.0) / Swift.max(0.001, Swift.min(1.0, decayRate))
        return ExponentialDecayAccumulator.Config(halfLife: halfLife)
    }

    /// Create config for specific percentile decay.
    ///
    /// - Parameters:
    ///   - percentile: Target percentile (e.g., 0.95 for 95th percentile)
    ///   - window: Time window for the percentile
    /// - Returns: Configuration with appropriate half-life
    static func forPercentile(_ percentile: Double, window: TimeInterval) -> ExponentialDecayAccumulator.Config {
        let halfLife = -window / log(1.0 - percentile) * log(2.0)
        return ExponentialDecayAccumulator.Config(halfLife: halfLife)
    }
}
