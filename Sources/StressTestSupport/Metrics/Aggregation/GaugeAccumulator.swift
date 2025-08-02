import PipelineKitObservability
import Foundation
import PipelineKit

/// Accumulator for gauge metrics that tracks min, max, sum, and last value.
///
/// GaugeAccumulator is designed for metrics that represent point-in-time
/// measurements like CPU usage, memory usage, or temperature. It maintains
/// running statistics without storing individual samples.
///
/// ## Memory Usage
/// Fixed ~88 bytes regardless of sample count.
///
/// ## Performance
/// - Add: O(1) time, ~20ns on modern hardware
/// - Statistics: O(1) time
/// - Reset: O(1) time
public struct GaugeAccumulator: StatisticsAccumulator {
    public typealias Statistics = BasicStatistics
    
    // MARK: - Properties
    
    private var count: Int = 0
    private var min: Double = .infinity
    private var max: Double = -.infinity
    private var sum: Double = 0
    private var lastValue: Double = 0
    private var lastTimestamp: Date?
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - StatisticsAccumulator
    
    public mutating func add(_ value: Double, at timestamp: Date) {
        // Update count
        count += 1
        
        // Update min/max
        if value < min {
            min = value
        }
        if value > max {
            max = value
        }
        
        // Update sum
        sum += value
        
        // Update last value
        lastValue = value
        lastTimestamp = timestamp
    }
    
    public mutating func reset() {
        count = 0
        min = .infinity
        max = -.infinity
        sum = 0
        lastValue = 0
        lastTimestamp = nil
    }
    
    public func statistics() -> BasicStatistics {
        BasicStatistics(
            count: count,
            min: count > 0 ? min : 0,
            max: count > 0 ? max : 0,
            sum: sum,
            lastValue: lastValue,
            lastTimestamp: lastTimestamp
        )
    }
    
    public var sampleCount: Int {
        count
    }
    
    public var isEmpty: Bool {
        count == 0
    }
}

// MARK: - Extensions

extension GaugeAccumulator: Equatable {}

extension GaugeAccumulator: CustomStringConvertible {
    public var description: String {
        let stats = statistics()
        return "GaugeAccumulator(count: \(stats.count), min: \(stats.min), max: \(stats.max), mean: \(String(format: "%.2f", stats.mean)), last: \(stats.lastValue))"
    }
}
