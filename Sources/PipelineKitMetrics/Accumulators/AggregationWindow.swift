import Foundation

/// Defines time-based aggregation windows for metrics.
///
/// Windows control how metrics are aggregated over time,
/// enabling different retention and aggregation strategies.
public enum AggregationWindow: Sendable {
    /// Fixed-size tumbling window that resets at intervals.
    case tumbling(duration: TimeInterval)

    /// Sliding window with multiple buckets.
    case sliding(duration: TimeInterval, buckets: Int)

    /// Exponentially weighted moving average.
    case exponentialDecay(halfLife: TimeInterval)

    /// No windowing - accumulate forever.
    case unbounded

    /// Create a windowed accumulator for this window type.
    ///
    /// - Parameters:
    ///   - type: The accumulator type to use
    ///   - config: Configuration for the accumulator
    /// - Returns: A windowed accumulator
    public func createAccumulator<A: MetricAccumulator>(
        type: A.Type,
        config: A.Config
    ) -> WindowedAccumulator<A> {
        WindowedAccumulator(window: self, config: config)
    }
}

/// An accumulator that manages time-based windowing.
///
/// WindowedAccumulator wraps any MetricAccumulator and adds
/// time-based windowing behavior based on the AggregationWindow type.
public actor WindowedAccumulator<A: MetricAccumulator> {
    // MARK: - Properties

    private let window: AggregationWindow
    private var accumulator: A
    private var windowStart: Date

    // For sliding windows
    private var buckets: [A] = []
    private var bucketDuration: TimeInterval = 0
    private var currentBucketIndex: Int = 0

    // For exponential decay
    private var lastUpdate: Date
    private var decayAccumulator: ExponentialDecayAccumulator?

    // MARK: - Initialization

    public init(window: AggregationWindow, config: A.Config) {
        self.window = window
        self.accumulator = A(config: config)
        self.windowStart = Date()
        self.lastUpdate = Date()

        // Initialize sliding window buckets
        if case .sliding(_, let bucketCount) = window {
            buckets = Array(repeating: A(config: config), count: bucketCount)
            if case .sliding(let duration, let count) = window {
                bucketDuration = duration / Double(count)
            }
        }

        // Initialize exponential decay accumulator
        if case .exponentialDecay(let halfLife) = window {
            decayAccumulator = ExponentialDecayAccumulator(
                config: .init(halfLife: halfLife)
            )
        }
    }

    // MARK: - Recording

    /// Record a value with windowing logic.
    public func record(_ value: Double, at timestamp: Date = Date()) {
        switch window {
        case .tumbling(let duration):
            handleTumblingWindow(value: value, timestamp: timestamp, duration: duration)

        case let .sliding(duration, bucketCount):
            handleSlidingWindow(
                value: value,
                timestamp: timestamp,
                duration: duration,
                bucketCount: bucketCount
            )

        case .exponentialDecay:
            handleExponentialDecay(value: value, timestamp: timestamp)

        case .unbounded:
            accumulator.record(value, at: timestamp)
        }
    }

    /// Get a snapshot of the current window.
    public func snapshot() -> A.Snapshot {
        switch window {
        case .sliding:
            // Merge all buckets for sliding window
            return mergeBuckets()

        case .exponentialDecay:
            // Return decayed values
            return createDecayedSnapshot()

        default:
            return accumulator.snapshot()
        }
    }

    /// Reset the window.
    public func reset() {
        accumulator.reset()
        windowStart = Date()

        if case .sliding = window {
            for i in 0..<buckets.count {
                buckets[i].reset()
            }
            currentBucketIndex = 0
        }

        if case .exponentialDecay = window {
            decayAccumulator?.reset()
            lastUpdate = Date()
        }
    }

    // MARK: - Private Methods

    private func handleTumblingWindow(value: Double, timestamp: Date, duration: TimeInterval) {
        if timestamp.timeIntervalSince(windowStart) > duration {
            accumulator.reset()
            windowStart = timestamp
        }
        accumulator.record(value, at: timestamp)
    }

    private func handleSlidingWindow(
        value: Double,
        timestamp: Date,
        duration: TimeInterval,
        bucketCount: Int
    ) {
        // Determine which bucket this timestamp belongs to
        let elapsed = timestamp.timeIntervalSince(windowStart)
        let bucketIndex = Int(elapsed / bucketDuration) % bucketCount

        // Clear old buckets if we've moved forward
        if bucketIndex != currentBucketIndex {
            let bucketsToClear = bucketIndex > currentBucketIndex
                ? bucketIndex - currentBucketIndex
                : (bucketCount - currentBucketIndex) + bucketIndex

            for i in 1...min(bucketsToClear, bucketCount) {
                let idx = (currentBucketIndex + i) % bucketCount
                buckets[idx].reset()
            }

            currentBucketIndex = bucketIndex
        }

        buckets[bucketIndex].record(value, at: timestamp)
    }

    private func handleExponentialDecay(value: Double, timestamp: Date) {
        // Only record to decay accumulator for exponential windows
        decayAccumulator?.record(value, at: timestamp)
        lastUpdate = timestamp
    }

    private func mergeBuckets() -> A.Snapshot {
        // Special handling for BasicStatsAccumulator - properly merge all buckets
        if A.self == BasicStatsAccumulator.self {
            var totalCount = 0
            var totalSum = 0.0
            var globalMin = Double.infinity
            var globalMax = -Double.infinity
            var latestValue = 0.0
            var latestTime = Date.distantPast

            // Aggregate statistics from all non-empty buckets
            for bucket in buckets where !bucket.isEmpty {
                guard let snap = bucket.snapshot() as? BasicStatsAccumulator.Snapshot else {
                    continue
                }
                totalCount += snap.count
                totalSum += snap.sum
                globalMin = Swift.min(globalMin, snap.min)
                globalMax = Swift.max(globalMax, snap.max)

                // Track the most recent value
                if snap.lastTimestamp > latestTime {
                    latestValue = snap.lastValue
                    latestTime = snap.lastTimestamp
                }
            }

            // Create merged snapshot if we have data
            if totalCount > 0 {
                let mergedSnapshot = BasicStatsAccumulator.Snapshot(
                    count: totalCount,
                    sum: totalSum,
                    min: globalMin,
                    max: globalMax,
                    lastValue: latestValue,
                    lastTimestamp: latestTime,
                    firstValue: nil,
                    firstTimestamp: nil
                )
                guard let typedSnapshot = mergedSnapshot as? A.Snapshot else {
                    fatalError("Snapshot type mismatch for BasicStatsAccumulator")
                }
                return typedSnapshot
            }
        }

        // Fallback for other types: return first non-empty bucket
        for bucket in buckets where !bucket.isEmpty {
            return bucket.snapshot()
        }

        return accumulator.snapshot()
    }

    private func createDecayedSnapshot() -> A.Snapshot {
        // Get the decay snapshot if available
        guard let decay = decayAccumulator?.snapshot() else {
            return accumulator.snapshot()
        }

        // Special handling for BasicStatsAccumulator - the most common case
        guard A.self == BasicStatsAccumulator.self else {
            // For non-BasicStats accumulators, fall back to regular accumulator
            // TODO: Implement protocol-based conversion for other types
            return accumulator.snapshot()
        }

        // Convert ExponentialDecayAccumulator.Snapshot to BasicStatsAccumulator.Snapshot
        // Use effectiveWeight for more accurate sum approximation
        let snapshot = BasicStatsAccumulator.Snapshot(
            count: decay.count,
            sum: decay.ewma * decay.effectiveWeight, // Use effective weight, not count
            min: decay.min,
            max: decay.max,
            lastValue: decay.lastValue,
            lastTimestamp: decay.lastTimestamp,
            firstValue: nil,  // Not tracked in decay accumulator
            firstTimestamp: nil  // Not tracked in decay accumulator
        )

        // Safe cast since we've already verified the type
        guard let typedSnapshot = snapshot as? A.Snapshot else {
            fatalError("Snapshot type mismatch for decay accumulator")
        }
        return typedSnapshot
    }
}

// MARK: - Window Duration Helpers

public extension AggregationWindow {
    /// Common window durations.
    static let oneMinute = AggregationWindow.tumbling(duration: 60)
    static let fiveMinutes = AggregationWindow.tumbling(duration: 300)
    static let oneHour = AggregationWindow.tumbling(duration: 3600)

    /// Common sliding windows.
    static let slidingMinute = AggregationWindow.sliding(duration: 60, buckets: 6)
    static let slidingHour = AggregationWindow.sliding(duration: 3600, buckets: 12)
}
