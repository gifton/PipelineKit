import PipelineKitObservability
import Foundation
import PipelineKit

/// Accumulator for counter metrics that tracks rate and total increase.
///
/// CounterAccumulator is designed for monotonically increasing metrics like
/// request counts, bytes processed, or errors. It tracks the first and last
/// values to calculate rate of change.
///
/// ## Memory Usage
/// Fixed ~80 bytes regardless of sample count.
///
/// ## Performance
/// - Add: O(1) time
/// - Statistics: O(1) time with rate calculation
/// - Reset: O(1) time
public struct CounterAccumulator: StatisticsAccumulator {
    public typealias Statistics = CounterStatistics
    
    // MARK: - Properties
    
    private var count: Int = 0
    private var sum: Double = 0
    private var firstValue: Double = 0
    private var firstTimestamp: Date?
    private var lastValue: Double = 0
    private var lastTimestamp: Date?
    private var isFirstValue: Bool = true
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - StatisticsAccumulator
    
    public mutating func add(_ value: Double, at timestamp: Date) {
        count += 1
        sum += value
        
        // Track first value
        if isFirstValue {
            firstValue = value
            firstTimestamp = timestamp
            isFirstValue = false
        }
        
        // Always update last value
        lastValue = value
        lastTimestamp = timestamp
    }
    
    public mutating func reset() {
        count = 0
        sum = 0
        firstValue = 0
        firstTimestamp = nil
        lastValue = 0
        lastTimestamp = nil
        isFirstValue = true
    }
    
    public func statistics() -> CounterStatistics {
        CounterStatistics(
            count: count,
            sum: sum,
            firstValue: firstValue,
            firstTimestamp: firstTimestamp,
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

extension CounterAccumulator: Equatable {}

extension CounterAccumulator: CustomStringConvertible {
    public var description: String {
        let stats = statistics()
        return "CounterAccumulator(count: \(stats.count), increase: \(stats.increase), rate: \(String(format: "%.2f", stats.rate))/s)"
    }
}

// MARK: - Counter Validation

extension CounterAccumulator {
    /// Validates that counter values are monotonically increasing.
    ///
    /// - Parameter value: The value to validate.
    /// - Returns: true if the value is valid (greater than or equal to last value).
    public func isValidValue(_ value: Double) -> Bool {
        if isEmpty {
            return value >= 0  // Counters should start at 0 or positive
        }
        return value >= lastValue
    }
}
