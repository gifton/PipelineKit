import Foundation

/// Protocol for accumulator snapshots that can be created from exponential decay data.
///
/// This protocol enables conversion from ExponentialDecayAccumulator.Snapshot
/// to other accumulator snapshot types, preserving the decay-weighted statistics.
public protocol DecayConvertible {
    /// Create a snapshot from exponential decay data.
    ///
    /// - Parameter decay: The exponential decay snapshot to convert from
    /// - Returns: A new snapshot of the conforming type with decay-weighted values
    static func fromDecay(_ decay: ExponentialDecayAccumulator.Snapshot) -> Self
}

// MARK: - BasicStatsAccumulator.Snapshot

extension BasicStatsAccumulator.Snapshot: DecayConvertible {
    public static func fromDecay(_ decay: ExponentialDecayAccumulator.Snapshot) -> Self {
        // Use effectiveWeight for more accurate sum approximation
        BasicStatsAccumulator.Snapshot(
            count: decay.count,
            sum: decay.ewma * decay.effectiveWeight,
            min: decay.min,
            max: decay.max,
            lastValue: decay.lastValue,
            lastTimestamp: decay.lastTimestamp,
            firstValue: nil,  // Not tracked in decay accumulator
            firstTimestamp: nil  // Not tracked in decay accumulator
        )
    }
}

// MARK: - CounterAccumulator.Snapshot

extension CounterAccumulator.Snapshot: DecayConvertible {
    public static func fromDecay(_ decay: ExponentialDecayAccumulator.Snapshot) -> Self {
        // For counters, use the weighted values
        // Since we don't have the first timestamp, use the last timestamp for both
        let totalSum = decay.ewma * decay.effectiveWeight
        
        return CounterAccumulator.Snapshot(
            count: decay.count,
            sum: totalSum,
            firstValue: decay.min,  // Use min as approximate first value
            firstTimestamp: decay.lastTimestamp,  // We only have last timestamp
            lastValue: decay.lastValue,
            lastTimestamp: decay.lastTimestamp
        )
    }
}

// MARK: - HistogramAccumulator.Snapshot

extension HistogramAccumulator.Snapshot: DecayConvertible {
    public static func fromDecay(_ decay: ExponentialDecayAccumulator.Snapshot) -> Self {
        // For histograms, we can't reconstruct the full distribution
        // but we can provide the key statistics
        
        // Create a simplified histogram with the available statistics
        // This is a best-effort approximation since we don't have the full distribution
        var buckets: [Double: Int] = [:]
        
        // Add min, max, and mean as representative points
        if decay.count > 0 {
            // Distribute the count across key points
            let pointCount = Swift.max(1, decay.count / 3)
            buckets[decay.min] = pointCount
            buckets[decay.ewma] = decay.count - (2 * pointCount)
            buckets[decay.max] = pointCount
        }
        
        return HistogramAccumulator.Snapshot(
            count: decay.count,
            sum: decay.ewma * decay.effectiveWeight,
            min: decay.min,
            max: decay.max,
            mean: decay.ewma,
            percentiles: [:], // Can't accurately reconstruct percentiles
            buckets: buckets
        )
    }
}

// MARK: - Generic Conversion Helper

extension WindowedAccumulator {
    /// Convert exponential decay snapshot to the appropriate accumulator type.
    ///
    /// This method uses the DecayConvertible protocol to convert decay snapshots
    /// to the correct type for any accumulator that supports it.
    func convertDecaySnapshot<T: DecayConvertible>(_ decay: ExponentialDecayAccumulator.Snapshot, to type: T.Type) -> T {
        return T.fromDecay(decay)
    }
}