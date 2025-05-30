import Foundation

/// Performance collector that aggregates measurements and provides statistical analysis.
public actor AggregatingPerformanceCollector: PerformanceCollector {
    private var measurements: [String: [PerformanceMeasurement]] = [:]
    private let maxMeasurementsPerCommand: Int
    
    public init(maxMeasurementsPerCommand: Int = 1000) {
        self.maxMeasurementsPerCommand = maxMeasurementsPerCommand
    }
    
    public func record(_ measurement: PerformanceMeasurement) async {
        let commandName = measurement.commandName
        
        if measurements[commandName] == nil {
            measurements[commandName] = []
        }
        
        measurements[commandName]?.append(measurement)
        
        // Keep only the most recent measurements to prevent memory growth
        if let count = measurements[commandName]?.count, count > maxMeasurementsPerCommand {
            measurements[commandName]?.removeFirst(count - maxMeasurementsPerCommand)
        }
    }
    
    /// Get aggregated statistics for a specific command.
    public func getStatistics(for commandName: String) -> PerformanceStatistics? {
        guard let commandMeasurements = measurements[commandName], !commandMeasurements.isEmpty else {
            return nil
        }
        
        return PerformanceStatistics(measurements: commandMeasurements)
    }
    
    /// Get aggregated statistics for all commands.
    public func getAllStatistics() -> [String: PerformanceStatistics] {
        var stats: [String: PerformanceStatistics] = [:]
        
        for (commandName, commandMeasurements) in measurements {
            if !commandMeasurements.isEmpty {
                stats[commandName] = PerformanceStatistics(measurements: commandMeasurements)
            }
        }
        
        return stats
    }
    
    /// Clear all collected measurements.
    public func clear() {
        measurements.removeAll()
    }
    
    /// Clear measurements for a specific command.
    public func clear(commandName: String) {
        measurements.removeValue(forKey: commandName)
    }
    
    /// Get the total number of measurements collected.
    public func getTotalMeasurementCount() -> Int {
        return measurements.values.reduce(0) { $0 + $1.count }
    }
}

/// Statistical analysis of performance measurements.
public struct PerformanceStatistics: Sendable {
    /// Total number of measurements
    public let count: Int
    
    /// Number of successful executions
    public let successCount: Int
    
    /// Number of failed executions
    public let failureCount: Int
    
    /// Success rate (0.0 to 1.0)
    public let successRate: Double
    
    /// Minimum execution time
    public let minTime: TimeInterval
    
    /// Maximum execution time
    public let maxTime: TimeInterval
    
    /// Average execution time
    public let averageTime: TimeInterval
    
    /// Median execution time
    public let medianTime: TimeInterval
    
    /// 95th percentile execution time
    public let p95Time: TimeInterval
    
    /// 99th percentile execution time
    public let p99Time: TimeInterval
    
    /// Standard deviation of execution times
    public let standardDeviation: TimeInterval
    
    /// Most recent measurement
    public let lastMeasurement: PerformanceMeasurement
    
    /// Time range of measurements
    public let timeRange: (start: Date, end: Date)
    
    init(measurements: [PerformanceMeasurement]) {
        precondition(!measurements.isEmpty, "Measurements array cannot be empty")
        
        self.count = measurements.count
        self.successCount = measurements.filter(\.isSuccess).count
        self.failureCount = count - successCount
        self.successRate = Double(successCount) / Double(count)
        
        let executionTimes = measurements.map(\.executionTime).sorted()
        
        self.minTime = executionTimes.first!
        self.maxTime = executionTimes.last!
        self.averageTime = executionTimes.reduce(0, +) / Double(executionTimes.count)
        
        // Calculate median
        let midIndex = executionTimes.count / 2
        if executionTimes.count % 2 == 0 {
            self.medianTime = (executionTimes[midIndex - 1] + executionTimes[midIndex]) / 2
        } else {
            self.medianTime = executionTimes[midIndex]
        }
        
        // Calculate standard deviation first
        let avgTime = averageTime // capture for closure
        let variance = executionTimes
            .map { pow($0 - avgTime, 2) }
            .reduce(0, +) / Double(executionTimes.count)
        self.standardDeviation = sqrt(variance)
        
        // Calculate percentiles  
        self.p95Time = Self.percentile(of: executionTimes, percentile: 0.95)
        self.p99Time = Self.percentile(of: executionTimes, percentile: 0.99)
        
        self.lastMeasurement = measurements.max(by: { $0.endTime < $1.endTime })!
        
        let sortedByTime = measurements.sorted(by: { $0.startTime < $1.startTime })
        self.timeRange = (
            start: sortedByTime.first!.startTime,
            end: sortedByTime.last!.endTime
        )
    }
    
    private static func percentile(of sortedValues: [TimeInterval], percentile: Double) -> TimeInterval {
        let index = percentile * Double(sortedValues.count - 1)
        let lower = Int(index)
        let upper = lower + 1
        
        if upper >= sortedValues.count {
            return sortedValues.last!
        }
        
        let weight = index - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }
}

extension PerformanceStatistics: CustomStringConvertible {
    public var description: String {
        return """
        Performance Statistics:
        - Count: \(count) (\(successCount) successful, \(failureCount) failed)
        - Success Rate: \(String(format: "%.1f", successRate * 100))%
        - Execution Time: min=\(String(format: "%.3f", minTime))s, max=\(String(format: "%.3f", maxTime))s, avg=\(String(format: "%.3f", averageTime))s
        - Percentiles: median=\(String(format: "%.3f", medianTime))s, p95=\(String(format: "%.3f", p95Time))s, p99=\(String(format: "%.3f", p99Time))s
        - Standard Deviation: \(String(format: "%.3f", standardDeviation))s
        """
    }
}