import Foundation

/// Statistical analysis of performance measurements.
///
/// PerformanceStatistics provides comprehensive statistical calculations
/// for analyzing scenario execution performance across multiple runs.
public struct PerformanceStatistics: Sendable {
    
    // MARK: - Properties
    
    /// Number of samples analyzed
    public let sampleCount: Int
    
    /// Duration statistics
    public let duration: Statistics
    
    /// CPU usage statistics (if available)
    public let cpuUsage: Statistics?
    
    /// Memory usage statistics (if available)
    public let memoryUsage: Statistics?
    
    /// Task count statistics (if available)
    public let taskCount: Statistics?
    
    /// Outlier executions (beyond 2 standard deviations)
    public let outliers: [ScenarioExecution]
    
    // MARK: - Initialization
    
    /// Initialize from a collection of scenario executions
    public init(executions: [ScenarioExecution]) {
        self.sampleCount = executions.count
        
        // Duration statistics
        let durations = executions.map { $0.duration }
        self.duration = Statistics(values: durations)
        
        // CPU statistics
        let cpuValues = executions.compactMap { $0.metrics.averageCPU }
        self.cpuUsage = cpuValues.isEmpty ? nil : Statistics(values: cpuValues)
        
        // Memory statistics
        let memoryValues = executions.compactMap { $0.metrics.peakMemory }.map { Double($0) }
        self.memoryUsage = memoryValues.isEmpty ? nil : Statistics(values: memoryValues)
        
        // Task statistics
        let taskValues = executions.compactMap { $0.metrics.peakTasks }.map { Double($0) }
        self.taskCount = taskValues.isEmpty ? nil : Statistics(values: taskValues)
        
        // Identify outliers (duration-based)
        let mean = duration.mean
        let stdDev = duration.standardDeviation
        let lowerBound = mean - 2 * stdDev
        let upperBound = mean + 2 * stdDev
        
        self.outliers = executions.filter { execution in
            execution.duration < lowerBound || execution.duration > upperBound
        }
    }
    
    // MARK: - Summary
    
    /// Generate a human-readable summary
    public func summary() -> String {
        var report = """
        Performance Statistics (\(sampleCount) samples)
        =====================================
        
        Duration:
        \(duration.summary(unit: "s"))
        
        """
        
        if let cpu = cpuUsage {
            report += """
            CPU Usage:
            \(cpu.summary(unit: "%"))
            
            """
        }
        
        if let memory = memoryUsage {
            report += """
            Memory Usage:
            \(memory.summary(unit: "MB", divisor: 1_048_576))
            
            """
        }
        
        if let tasks = taskCount {
            report += """
            Task Count:
            \(tasks.summary())
            
            """
        }
        
        if !outliers.isEmpty {
            report += """
            Outliers: \(outliers.count) executions
              \(outliers.map { "- \($0.scenario): \(String(format: "%.2fs", $0.duration))" }.joined(separator: "\n  "))
            """
        }
        
        return report
    }
}

// MARK: - Core Statistics

/// Statistical calculations for a set of values
public struct Statistics: Sendable {
    
    // MARK: - Basic Statistics
    
    /// Arithmetic mean
    public let mean: Double
    
    /// Median value
    public let median: Double
    
    /// Standard deviation
    public let standardDeviation: Double
    
    /// Variance
    public let variance: Double
    
    /// Minimum value
    public let min: Double
    
    /// Maximum value
    public let max: Double
    
    /// Range (max - min)
    public let range: Double
    
    // MARK: - Percentiles
    
    /// 25th percentile
    public let p25: Double
    
    /// 50th percentile (same as median)
    public let p50: Double
    
    /// 75th percentile
    public let p75: Double
    
    /// 90th percentile
    public let p90: Double
    
    /// 95th percentile
    public let p95: Double
    
    /// 99th percentile
    public let p99: Double
    
    /// Interquartile range (p75 - p25)
    public let iqr: Double
    
    // MARK: - Initialization
    
    public init(values: [Double]) {
        guard !values.isEmpty else {
            // Handle empty case
            self.mean = 0
            self.median = 0
            self.standardDeviation = 0
            self.variance = 0
            self.min = 0
            self.max = 0
            self.range = 0
            self.p25 = 0
            self.p50 = 0
            self.p75 = 0
            self.p90 = 0
            self.p95 = 0
            self.p99 = 0
            self.iqr = 0
            return
        }
        
        let sorted = values.sorted()
        let count = Double(values.count)
        
        // Basic statistics
        self.mean = values.reduce(0, +) / count
        self.min = sorted.first!
        self.max = sorted.last!
        self.range = max - min
        
        // Variance and standard deviation
        let squaredDifferences = values.map { pow($0 - mean, 2) }
        self.variance = squaredDifferences.reduce(0, +) / count
        self.standardDeviation = sqrt(variance)
        
        // Percentiles
        self.p25 = percentile(sorted, 0.25)
        self.p50 = percentile(sorted, 0.50)
        self.median = p50
        self.p75 = percentile(sorted, 0.75)
        self.p90 = percentile(sorted, 0.90)
        self.p95 = percentile(sorted, 0.95)
        self.p99 = percentile(sorted, 0.99)
        self.iqr = p75 - p25
    }
    
    // MARK: - Summary
    
    /// Generate a formatted summary
    public func summary(unit: String = "", divisor: Double = 1.0) -> String {
        let format = { (value: Double) -> String in
            let adjusted = value / divisor
            return String(format: "%.2f%@", adjusted, unit.isEmpty ? "" : unit)
        }
        
        return """
          Mean: \(format(mean))
          Median: \(format(median))
          Std Dev: \(format(standardDeviation))
          Min: \(format(min))
          Max: \(format(max))
          P50: \(format(p50))
          P90: \(format(p90))
          P95: \(format(p95))
          P99: \(format(p99))
        """
    }
}

// MARK: - Benchmark Result

/// Results from benchmarking a scenario
public struct BenchmarkResult: Sendable {
    
    /// Name of the benchmarked scenario
    public let scenario: String
    
    /// Benchmark configuration used
    public let configuration: ScenarioTestHarness.BenchmarkConfiguration
    
    /// Warmup run results (not included in statistics)
    public let warmupResults: [ScenarioExecution]
    
    /// Measurement run results
    public let measurementResults: [ScenarioExecution]
    
    /// Statistical analysis of measurements
    public let statistics: PerformanceStatistics
    
    /// Whether all runs succeeded
    public var allRunsSucceeded: Bool {
        measurementResults.allSatisfy { $0.passed }
    }
    
    /// Average duration across measurement runs
    public var averageDuration: TimeInterval {
        statistics.duration.mean
    }
    
    /// Generate a benchmark report
    public func report() -> String {
        var report = """
        Benchmark Report: \(scenario)
        ================================
        
        Configuration:
          Warmup Runs: \(configuration.warmupRuns)
          Measurement Runs: \(configuration.runs)
          Cooldown: \(configuration.cooldownBetweenRuns)s
        
        Results:
          Success Rate: \(successRate())%
          Average Duration: \(String(format: "%.3fs", averageDuration))
        
        \(statistics.summary())
        """
        
        // Add failure details if any
        let failures = measurementResults.filter { !$0.passed }
        if !failures.isEmpty {
            report += "\n\nFailures (\(failures.count)):\n"
            for (index, failure) in failures.enumerated() {
                report += "  Run \(index + 1): \(failure.errors.first?.localizedDescription ?? "Unknown error")\n"
            }
        }
        
        return report
    }
    
    /// Calculate success rate percentage
    public func successRate() -> Double {
        let successCount = measurementResults.filter { $0.passed }.count
        return (Double(successCount) / Double(measurementResults.count)) * 100
    }
    
    /// Compare with another benchmark result
    public func compare(with other: BenchmarkResult) -> ComparisonResult {
        ComparisonResult(
            baseline: self,
            comparison: other
        )
    }
}

// MARK: - Comparison Result

/// Result of comparing two benchmarks
public struct ComparisonResult: Sendable {
    public let baseline: BenchmarkResult
    public let comparison: BenchmarkResult
    
    /// Duration change (positive means slower)
    public var durationChange: Double {
        let baselineDuration = baseline.statistics.duration.mean
        let comparisonDuration = comparison.statistics.duration.mean
        return ((comparisonDuration - baselineDuration) / baselineDuration) * 100
    }
    
    /// Whether performance improved
    public var improved: Bool {
        durationChange < 0
    }
    
    /// Statistical significance (using t-test approximation)
    public var isSignificant: Bool {
        // Simple check: if confidence intervals don't overlap
        let baseline95CI = confidenceInterval(baseline.statistics.duration)
        let comparison95CI = confidenceInterval(comparison.statistics.duration)
        
        return baseline95CI.upperBound < comparison95CI.lowerBound ||
               comparison95CI.upperBound < baseline95CI.lowerBound
    }
    
    /// Generate comparison report
    public func report() -> String {
        let changeSymbol = improved ? "↓" : "↑"
        let changeDescription = improved ? "improvement" : "regression"
        
        return """
        Performance Comparison
        =====================
        
        Baseline: \(baseline.scenario)
          Mean: \(String(format: "%.3fs", baseline.statistics.duration.mean))
          P95: \(String(format: "%.3fs", baseline.statistics.duration.p95))
        
        Comparison: \(comparison.scenario)
          Mean: \(String(format: "%.3fs", comparison.statistics.duration.mean))
          P95: \(String(format: "%.3fs", comparison.statistics.duration.p95))
        
        Change: \(changeSymbol) \(String(format: "%.1f%%", abs(durationChange))) (\(changeDescription))
        Statistically Significant: \(isSignificant ? "Yes" : "No")
        """
    }
    
    private func confidenceInterval(_ stats: Statistics) -> ClosedRange<Double> {
        // 95% confidence interval approximation
        let margin = 1.96 * stats.standardDeviation / sqrt(Double(baseline.measurementResults.count))
        return (stats.mean - margin)...(stats.mean + margin)
    }
}

// MARK: - Helpers

private func percentile(_ sortedValues: [Double], _ p: Double) -> Double {
    guard !sortedValues.isEmpty else { return 0 }
    
    let index = p * Double(sortedValues.count - 1)
    let lower = Int(index)
    let upper = lower + 1
    let weight = index - Double(lower)
    
    if upper >= sortedValues.count {
        return sortedValues[lower]
    }
    
    return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
}