import Foundation

/// Protocol for accumulating statistics over a series of metric values.
///
/// StatisticsAccumulator provides a common interface for different types of
/// metric aggregation strategies. Implementations must be thread-safe when
/// used within an actor context.
///
/// ## Design Considerations
/// - Value semantics for easy copying and window rotation
/// - Minimal memory footprint (<1KB per accumulator)
/// - O(1) add operations for performance
/// - Immutable statistics() for safe concurrent reads
public protocol StatisticsAccumulator: Sendable {
    /// The type of statistics this accumulator produces.
    associatedtype Statistics: Sendable
    
    /// Adds a new value to the accumulator.
    ///
    /// - Parameters:
    ///   - value: The metric value to accumulate.
    ///   - timestamp: When the value was recorded.
    mutating func add(_ value: Double, at timestamp: Date)
    
    /// Resets the accumulator to its initial state.
    mutating func reset()
    
    /// Returns the current accumulated statistics.
    ///
    /// This method should be safe to call concurrently and should
    /// return an immutable snapshot of the current statistics.
    func statistics() -> Statistics
    
    /// The number of samples accumulated.
    var sampleCount: Int { get }
    
    /// Returns whether the accumulator is empty.
    var isEmpty: Bool { get }
}

// MARK: - Common Statistics Types

/// Basic statistics common to many metric types.
public struct BasicStatistics: Sendable, Equatable {
    public let count: Int
    public let min: Double
    public let max: Double
    public let sum: Double
    public let lastValue: Double
    public let lastTimestamp: Date?
    
    /// Whether this statistics object represents empty data.
    public var isEmpty: Bool {
        count == 0
    }
    
    /// The arithmetic mean of all values.
    public var mean: Double {
        !isEmpty ? sum / Double(count) : 0
    }
    
    /// The range between min and max.
    public var range: Double {
        max - min
    }
    
    public init(
        count: Int = 0,
        min: Double = .infinity,
        max: Double = -.infinity,
        sum: Double = 0,
        lastValue: Double = 0,
        lastTimestamp: Date? = nil
    ) {
        self.count = count
        self.min = min
        self.max = max
        self.sum = sum
        self.lastValue = lastValue
        self.lastTimestamp = lastTimestamp
    }
}

/// Statistics specific to counter metrics.
public struct CounterStatistics: Sendable, Equatable {
    public let count: Int
    public let sum: Double
    public let firstValue: Double
    public let firstTimestamp: Date?
    public let lastValue: Double
    public let lastTimestamp: Date?
    
    /// The total increase from first to last value.
    public var increase: Double {
        lastValue - firstValue
    }
    
    /// The rate of increase per second.
    public var rate: Double {
        guard let first = firstTimestamp,
              let last = lastTimestamp,
              first < last else { return 0 }
        
        let duration = last.timeIntervalSince(first)
        return duration > 0 ? increase / duration : 0
    }
    
    public init(
        count: Int = 0,
        sum: Double = 0,
        firstValue: Double = 0,
        firstTimestamp: Date? = nil,
        lastValue: Double = 0,
        lastTimestamp: Date? = nil
    ) {
        self.count = count
        self.sum = sum
        self.firstValue = firstValue
        self.firstTimestamp = firstTimestamp
        self.lastValue = lastValue
        self.lastTimestamp = lastTimestamp
    }
}

/// Statistics including percentile information.
public struct HistogramStatistics: Sendable, Equatable {
    public let count: Int
    public let min: Double
    public let max: Double
    public let sum: Double
    public let mean: Double
    public let p50: Double
    public let p90: Double
    public let p95: Double
    public let p99: Double
    public let p999: Double
    
    public init(
        count: Int = 0,
        min: Double = .infinity,
        max: Double = -.infinity,
        sum: Double = 0,
        mean: Double = 0,
        p50: Double = 0,
        p90: Double = 0,
        p95: Double = 0,
        p99: Double = 0,
        p999: Double = 0
    ) {
        self.count = count
        self.min = min
        self.max = max
        self.sum = sum
        self.mean = mean
        self.p50 = p50
        self.p90 = p90
        self.p95 = p95
        self.p99 = p99
        self.p999 = p999
    }
}
