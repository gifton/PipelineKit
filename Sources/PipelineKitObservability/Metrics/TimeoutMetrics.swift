import PipelineKitCore
import Foundation

/// Specialized metrics for timeout behavior tracking
public protocol TimeoutMetricsCollector: Sendable {
    /// Record a timeout event with detailed context
    func recordTimeout(
        commandType: String,
        timeoutDuration: TimeInterval,
        actualDuration: TimeInterval,
        gracePeriodUsed: Bool,
        tags: [String: String]
    ) async
    
    /// Record near-timeout warning
    func recordNearTimeout(
        commandType: String,
        duration: TimeInterval,
        threshold: TimeInterval,
        percentage: Double,
        tags: [String: String]
    ) async
    
    /// Record timeout recovery (command completed during grace period)
    func recordTimeoutRecovery(
        commandType: String,
        timeoutDuration: TimeInterval,
        recoveryDuration: TimeInterval,
        tags: [String: String]
    ) async
}

/// Extension to make any MetricsCollector support timeout metrics
public extension MetricsCollector {
    func asTimeoutMetricsCollector() -> TimeoutMetricsAdapter {
        return TimeoutMetricsAdapter(collector: self)
    }
}

/// Adapter that implements TimeoutMetricsCollector using a standard MetricsCollector
public actor TimeoutMetricsAdapter: TimeoutMetricsCollector {
    private let collector: any MetricsCollector
    
    public init(collector: any MetricsCollector) {
        self.collector = collector
    }
    
    public func recordTimeout(
        commandType: String,
        timeoutDuration: TimeInterval,
        actualDuration: TimeInterval,
        gracePeriodUsed: Bool,
        tags: [String: String]
    ) async {
        var enrichedTags = tags
        enrichedTags["command_type"] = commandType
        enrichedTags["grace_period_used"] = String(gracePeriodUsed)
        enrichedTags["timeout_exceeded_by"] = String(format: "%.3f", actualDuration - timeoutDuration)
        
        // Record timeout counter
        await collector.recordCounter("command.timeout", value: 1, tags: enrichedTags)
        
        // Record timeout duration distribution
        await collector.recordHistogram(
            "command.timeout.duration",
            value: actualDuration,
            tags: enrichedTags
        )
        
        // Record timeout threshold
        await collector.recordHistogram(
            "command.timeout.threshold",
            value: timeoutDuration,
            tags: enrichedTags
        )
        
        // Record timeout overage
        if actualDuration > timeoutDuration {
            await collector.recordHistogram(
                "command.timeout.overage",
                value: actualDuration - timeoutDuration,
                tags: enrichedTags
            )
        }
    }
    
    public func recordNearTimeout(
        commandType: String,
        duration: TimeInterval,
        threshold: TimeInterval,
        percentage: Double,
        tags: [String: String]
    ) async {
        var enrichedTags = tags
        enrichedTags["command_type"] = commandType
        enrichedTags["percentage"] = String(format: "%.1f", percentage)
        
        // Record near-timeout counter
        await collector.recordCounter("command.near_timeout", value: 1, tags: enrichedTags)
        
        // Record how close we got to timeout
        await collector.recordHistogram(
            "command.near_timeout.percentage",
            value: percentage,
            tags: enrichedTags
        )
        
        // Record the actual duration for near-timeouts
        await collector.recordHistogram(
            "command.near_timeout.duration",
            value: duration,
            tags: enrichedTags
        )
    }
    
    public func recordTimeoutRecovery(
        commandType: String,
        timeoutDuration: TimeInterval,
        recoveryDuration: TimeInterval,
        tags: [String: String]
    ) async {
        var enrichedTags = tags
        enrichedTags["command_type"] = commandType
        
        // Record recovery counter
        await collector.recordCounter("command.timeout.recovered", value: 1, tags: enrichedTags)
        
        // Record recovery duration (time in grace period)
        await collector.recordHistogram(
            "command.timeout.recovery_duration",
            value: recoveryDuration,
            tags: enrichedTags
        )
        
        // Record total duration
        await collector.recordHistogram(
            "command.timeout.total_duration",
            value: timeoutDuration + recoveryDuration,
            tags: enrichedTags
        )
    }
}

/// Statistics aggregator for timeout behavior analysis
public actor TimeoutStatisticsAggregator {
    private var timeoutCounts: [String: Int] = [:]
    private var nearTimeoutCounts: [String: Int] = [:]
    private var recoveryRates: [String: (recovered: Int, total: Int)] = [:]
    private var durationDistributions: [String: [TimeInterval]] = [:]
    
    public init() {}
    
    /// Record a timeout event
    public func recordTimeout(commandType: String, recovered: Bool) {
        timeoutCounts[commandType, default: 0] += 1
        
        var stats = recoveryRates[commandType] ?? (recovered: 0, total: 0)
        stats.total += 1
        if recovered {
            stats.recovered += 1
        }
        recoveryRates[commandType] = stats
    }
    
    /// Record a near-timeout event
    public func recordNearTimeout(commandType: String) {
        nearTimeoutCounts[commandType, default: 0] += 1
    }
    
    /// Record command duration
    public func recordDuration(commandType: String, duration: TimeInterval) {
        if durationDistributions[commandType] == nil {
            durationDistributions[commandType] = []
        }
        durationDistributions[commandType]?.append(duration)
        
        // Keep only last 1000 durations per command type
        if let count = durationDistributions[commandType]?.count, count > 1000 {
            durationDistributions[commandType]?.removeFirst(count - 1000)
        }
    }
    
    /// Get timeout statistics for a command type
    public func getStatistics(for commandType: String) -> TimeoutStatistics? {
        guard let durations = durationDistributions[commandType],
              !durations.isEmpty else { return nil }
        
        let sorted = durations.sorted()
        let recoveryStats = recoveryRates[commandType] ?? (0, 0)
        
        return TimeoutStatistics(
            commandType: commandType,
            timeoutCount: timeoutCounts[commandType] ?? 0,
            nearTimeoutCount: nearTimeoutCounts[commandType] ?? 0,
            recoveryRate: recoveryStats.total > 0 
                ? Double(recoveryStats.recovered) / Double(recoveryStats.total) 
                : 0,
            durationPercentiles: calculatePercentiles(sorted),
            averageDuration: durations.reduce(0, +) / Double(durations.count),
            maxDuration: sorted.last ?? 0,
            minDuration: sorted.first ?? 0
        )
    }
    
    /// Get all command types being tracked
    public func getTrackedCommands() -> [String] {
        var allKeys = Set<String>()
        allKeys.formUnion(timeoutCounts.keys)
        allKeys.formUnion(nearTimeoutCounts.keys)
        allKeys.formUnion(durationDistributions.keys)
        return Array(allKeys).sorted()
    }
    
    /// Reset all statistics
    public func reset() {
        timeoutCounts.removeAll()
        nearTimeoutCounts.removeAll()
        recoveryRates.removeAll()
        durationDistributions.removeAll()
    }
    
    private func calculatePercentiles(_ sorted: [TimeInterval]) -> [Double: TimeInterval] {
        guard !sorted.isEmpty else { return [:] }
        
        let percentiles = [0.5, 0.9, 0.95, 0.99]
        var result: [Double: TimeInterval] = [:]
        
        for p in percentiles {
            let index = Int(Double(sorted.count - 1) * p)
            result[p] = sorted[index]
        }
        
        return result
    }
}

/// Timeout behavior statistics
public struct TimeoutStatistics: Sendable {
    public let commandType: String
    public let timeoutCount: Int
    public let nearTimeoutCount: Int
    public let recoveryRate: Double
    public let durationPercentiles: [Double: TimeInterval]
    public let averageDuration: TimeInterval
    public let maxDuration: TimeInterval
    public let minDuration: TimeInterval
}