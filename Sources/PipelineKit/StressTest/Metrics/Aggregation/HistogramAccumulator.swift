import Foundation

/// Accumulator for histogram metrics with percentile calculation.
///
/// HistogramAccumulator uses reservoir sampling to maintain a fixed-size
/// sample of values for percentile calculation. This provides accurate
/// percentiles with bounded memory usage.
///
/// ## Algorithm
/// - Uses Reservoir Sampling (Algorithm R) for uniform sampling
/// - Maintains exact min/max/sum for all values
/// - Calculates percentiles from reservoir samples
///
/// ## Memory Usage
/// ~8KB for default reservoir size of 1000 samples
///
/// ## Performance
/// - Add: O(1) amortized time
/// - Percentile calculation: O(n log n) where n = reservoir size
/// - Reset: O(n) time
public struct HistogramAccumulator: StatisticsAccumulator {
    public typealias Statistics = HistogramStatistics
    
    // MARK: - Configuration
    
    /// Default reservoir size for percentile calculation.
    public static let defaultReservoirSize = 1000
    
    // MARK: - Properties
    
    private let reservoirSize: Int
    private var reservoir: [Double]
    private var count: Int = 0
    private var min: Double = .infinity
    private var max: Double = -.infinity
    private var sum: Double = 0
    
    // MARK: - Initialization
    
    public init(reservoirSize: Int = defaultReservoirSize) {
        self.reservoirSize = reservoirSize
        self.reservoir = []
        self.reservoir.reserveCapacity(reservoirSize)
    }
    
    // MARK: - StatisticsAccumulator
    
    public mutating func add(_ value: Double, at timestamp: Date) {
        count += 1
        
        // Update basic statistics
        if value < self.min {
            self.min = value
        }
        if value > self.max {
            self.max = value
        }
        sum += value
        
        // Reservoir sampling
        if reservoir.count < reservoirSize {
            // Reservoir not full, just append
            reservoir.append(value)
        } else {
            // Reservoir full, use random replacement
            let randomIndex = Int.random(in: 0..<count)
            if randomIndex < reservoirSize {
                reservoir[randomIndex] = value
            }
        }
    }
    
    public mutating func reset() {
        reservoir.removeAll(keepingCapacity: true)
        count = 0
        min = .infinity
        max = -.infinity
        sum = 0
    }
    
    public func statistics() -> HistogramStatistics {
        guard count > 0 else {
            return HistogramStatistics()
        }
        
        // Calculate percentiles from reservoir
        let sortedReservoir = reservoir.sorted()
        let percentiles = calculatePercentiles(sortedReservoir)
        
        return HistogramStatistics(
            count: count,
            min: min,
            max: max,
            sum: sum,
            mean: sum / Double(count),
            p50: percentiles.p50,
            p90: percentiles.p90,
            p95: percentiles.p95,
            p99: percentiles.p99,
            p999: percentiles.p999
        )
    }
    
    public var sampleCount: Int {
        count
    }
    
    public var isEmpty: Bool {
        count == 0
    }
    
    // MARK: - Private Methods
    
    private func calculatePercentiles(_ sortedValues: [Double]) -> (p50: Double, p90: Double, p95: Double, p99: Double, p999: Double) {
        guard !sortedValues.isEmpty else {
            return (0, 0, 0, 0, 0)
        }
        
        // Handle single value case
        if sortedValues.count == 1 {
            let value = sortedValues[0]
            return (value, value, value, value, value)
        }
        
        return (
            p50: percentile(sortedValues, 0.50),
            p90: percentile(sortedValues, 0.90),
            p95: percentile(sortedValues, 0.95),
            p99: percentile(sortedValues, 0.99),
            p999: percentile(sortedValues, 0.999)
        )
    }
    
    /// Calculates a specific percentile using linear interpolation.
    private func percentile(_ sortedValues: [Double], _ p: Double) -> Double {
        let n = Double(sortedValues.count)
        let rank = p * (n - 1)
        let lowerIndex = Int(rank)
        let upperIndex = Swift.min(lowerIndex + 1, sortedValues.count - 1)
        let weight = rank - Double(lowerIndex)
        
        return sortedValues[lowerIndex] * (1 - weight) + sortedValues[upperIndex] * weight
    }
}

// MARK: - Extensions

extension HistogramAccumulator: Equatable {}

extension HistogramAccumulator: CustomStringConvertible {
    public var description: String {
        let stats = statistics()
        return """
        HistogramAccumulator(
          count: \(stats.count)
          min: \(stats.min), max: \(stats.max), mean: \(String(format: "%.2f", stats.mean))
          p50: \(stats.p50), p90: \(stats.p90), p95: \(stats.p95), p99: \(stats.p99)
        )
        """
    }
}

// MARK: - Advanced Histogram Features

extension HistogramAccumulator {
    /// Creates histogram buckets for visualization.
    public func buckets(count: Int = 10) -> [HistogramBucket] {
        guard !reservoir.isEmpty && count > 0 else { return [] }
        
        let sortedReservoir = reservoir.sorted()
        let minValue = sortedReservoir.first!
        let maxValue = sortedReservoir.last!
        
        guard minValue < maxValue else {
            // All values are the same
            return [HistogramBucket(
                lowerBound: minValue,
                upperBound: maxValue,
                count: reservoir.count,
                percentage: 100.0
            )]
        }
        
        let bucketWidth = (maxValue - minValue) / Double(count)
        var buckets: [HistogramBucket] = []
        
        for i in 0..<count {
            let lowerBound = minValue + Double(i) * bucketWidth
            let upperBound = (i == count - 1) ? maxValue : lowerBound + bucketWidth
            
            let bucketCount = sortedReservoir.filter { value in
                if i == count - 1 {
                    return value >= lowerBound && value <= upperBound
                } else {
                    return value >= lowerBound && value < upperBound
                }
            }.count
            
            let percentage = Double(bucketCount) / Double(reservoir.count) * 100
            
            buckets.append(HistogramBucket(
                lowerBound: lowerBound,
                upperBound: upperBound,
                count: bucketCount,
                percentage: percentage
            ))
        }
        
        return buckets
    }
}

/// A single histogram bucket.
public struct HistogramBucket: Sendable, Equatable {
    public let lowerBound: Double
    public let upperBound: Double
    public let count: Int
    public let percentage: Double
    
    public var range: String {
        String(format: "[%.2f, %.2f)", lowerBound, upperBound)
    }
}