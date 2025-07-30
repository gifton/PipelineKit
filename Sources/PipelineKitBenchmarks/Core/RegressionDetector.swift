import Foundation

/// Detects performance regressions by comparing benchmark results against baselines.
public actor RegressionDetector {
    /// Configuration for regression detection.
    public struct Configuration: Sendable {
        /// Percentage threshold for time regression (default: 5%)
        public let timeRegressionThreshold: Double
        
        /// Percentage threshold for memory regression (default: 10%)
        public let memoryRegressionThreshold: Double
        
        /// Whether to fail on any regression
        public let failOnRegression: Bool
        
        /// Whether to include detailed comparison in output
        public let verbose: Bool
        
        public init(
            timeRegressionThreshold: Double = 0.05,
            memoryRegressionThreshold: Double = 0.10,
            failOnRegression: Bool = true,
            verbose: Bool = false
        ) {
            self.timeRegressionThreshold = timeRegressionThreshold
            self.memoryRegressionThreshold = memoryRegressionThreshold
            self.failOnRegression = failOnRegression
            self.verbose = verbose
        }
        
        public static let `default` = Configuration()
        
        public static let strict = Configuration(
            timeRegressionThreshold: 0.02,
            memoryRegressionThreshold: 0.05,
            failOnRegression: true,
            verbose: true
        )
        
        public static let relaxed = Configuration(
            timeRegressionThreshold: 0.10,
            memoryRegressionThreshold: 0.20,
            failOnRegression: false,
            verbose: false
        )
    }
    
    private let configuration: Configuration
    private let baselineStorage: BaselineStorage
    
    public init(
        configuration: Configuration = .default,
        baselineStorage: BaselineStorage? = nil
    ) {
        self.configuration = configuration
        self.baselineStorage = baselineStorage ?? BaselineStorage()
    }
    
    /// Checks for regressions in a benchmark result against its baseline.
    public func checkForRegression(_ result: BenchmarkResult) async throws -> RegressionCheckResult {
        // Try to load baseline
        guard let baseline = try await baselineStorage.loadBaseline(for: result.metadata.benchmarkName) else {
            return .noBaseline(result)
        }
        
        // Compare results
        let comparison = compare(current: result, baseline: baseline)
        
        // Determine if there are regressions
        var regressions: [RegressionDetail] = []
        
        // Check time regression
        if comparison.timeDelta.isRegression {
            regressions.append(.time(comparison.timeDelta))
        }
        
        // Check memory regression if available
        if let memoryDelta = comparison.memoryDelta, memoryDelta.isRegression {
            regressions.append(.memory(memoryDelta))
        }
        
        if regressions.isEmpty {
            return .noRegression(comparison)
        } else {
            return .regression(comparison, regressions)
        }
    }
    
    /// Compares current results against baseline.
    private func compare(current: BenchmarkResult, baseline: BenchmarkResult) -> BaselineComparison {
        let timeDelta = BaselineComparison.TimeDelta(
            current: current.statistics.median,
            baseline: baseline.statistics.median,
            threshold: configuration.timeRegressionThreshold
        )
        
        let memoryDelta: BaselineComparison.MemoryDelta?
        if let currentMemory = current.statistics.memoryPeakMedian,
           let baselineMemory = baseline.statistics.memoryPeakMedian {
            memoryDelta = BaselineComparison.MemoryDelta(
                current: currentMemory,
                baseline: baselineMemory,
                threshold: configuration.memoryRegressionThreshold
            )
        } else {
            memoryDelta = nil
        }
        
        return BaselineComparison(
            benchmarkName: current.metadata.benchmarkName,
            current: current,
            baseline: baseline,
            timeDelta: timeDelta,
            memoryDelta: memoryDelta
        )
    }
    
    /// Generates a report for regression check results.
    public func generateReport(_ results: [RegressionCheckResult]) -> RegressionReport {
        var hasRegressions = false
        var criticalCount = 0
        var highCount = 0
        var mediumCount = 0
        var lowCount = 0
        
        for result in results {
            if case .regression(let comparison, _) = result {
                hasRegressions = true
                
                switch comparison.timeDelta.severity {
                case .critical:
                    criticalCount += 1
                case .high:
                    highCount += 1
                case .medium:
                    mediumCount += 1
                case .low:
                    lowCount += 1
                }
            }
        }
        
        return RegressionReport(
            results: results,
            hasRegressions: hasRegressions,
            criticalCount: criticalCount,
            highCount: highCount,
            mediumCount: mediumCount,
            lowCount: lowCount,
            configuration: configuration
        )
    }
}

// MARK: - Result Types

/// Result of checking for regressions.
public enum RegressionCheckResult: Sendable {
    /// No baseline exists for comparison
    case noBaseline(BenchmarkResult)
    
    /// Baseline exists but no regression detected
    case noRegression(BaselineComparison)
    
    /// Regression detected
    case regression(BaselineComparison, [RegressionDetail])
    
    public var isRegression: Bool {
        if case .regression = self {
            return true
        }
        return false
    }
    
    public var benchmarkName: String {
        switch self {
        case .noBaseline(let result):
            return result.metadata.benchmarkName
        case .noRegression(let comparison), .regression(let comparison, _):
            return comparison.benchmarkName
        }
    }
}

/// Details about a specific regression.
public enum RegressionDetail: Sendable {
    case time(BaselineComparison.TimeDelta)
    case memory(BaselineComparison.MemoryDelta)
}

/// Report summarizing regression check results.
public struct RegressionReport: Sendable {
    public let results: [RegressionCheckResult]
    public let hasRegressions: Bool
    public let criticalCount: Int
    public let highCount: Int
    public let mediumCount: Int
    public let lowCount: Int
    public let configuration: RegressionDetector.Configuration
    
    /// Formats the report as a string.
    public func format(verbose: Bool? = nil) -> String {
        let isVerbose = verbose ?? configuration.verbose
        var output = [""]
        
        output.append("═══════════════════════════════════════════════════════════════")
        output.append("                    REGRESSION REPORT")
        output.append("═══════════════════════════════════════════════════════════════")
        output.append("")
        
        if hasRegressions {
            output.append("⚠️  REGRESSIONS DETECTED")
            output.append("")
            if criticalCount > 0 {
                output.append("🔴 Critical: \(criticalCount)")
            }
            if highCount > 0 {
                output.append("🟠 High: \(highCount)")
            }
            if mediumCount > 0 {
                output.append("🟡 Medium: \(mediumCount)")
            }
            if lowCount > 0 {
                output.append("🟢 Low: \(lowCount)")
            }
            output.append("")
        } else {
            output.append("✅ No regressions detected")
            output.append("")
        }
        
        // Detailed results
        for result in results {
            switch result {
            case .noBaseline(let benchmarkResult):
                output.append("📊 \(benchmarkResult.metadata.benchmarkName)")
                output.append("   ⚪ No baseline available")
                output.append("")
                
            case .noRegression(let comparison):
                output.append("📊 \(comparison.benchmarkName)")
                output.append("   ✅ No regression")
                if isVerbose {
                    output.append(formatComparison(comparison, indent: "   "))
                }
                output.append("")
                
            case .regression(let comparison, let details):
                output.append("📊 \(comparison.benchmarkName)")
                output.append("   ⚠️  REGRESSION DETECTED")
                
                for detail in details {
                    switch detail {
                    case .time(let delta):
                        let icon = severityIcon(delta.severity)
                        output.append("   \(icon) Time: +\(formatPercentage(delta.percentageChange)) (\(formatDuration(delta.absoluteChange)))")
                        
                    case .memory(let delta):
                        output.append("   🟠 Memory: +\(formatPercentage(delta.percentageChange)) (\(formatBytes(delta.absoluteChange)))")
                    }
                }
                
                if isVerbose {
                    output.append(formatComparison(comparison, indent: "   "))
                }
                output.append("")
            }
        }
        
        output.append("═══════════════════════════════════════════════════════════════")
        
        return output.joined(separator: "\n")
    }
    
    private func severityIcon(_ severity: BaselineComparison.RegressionSeverity) -> String {
        switch severity {
        case .critical: return "🔴"
        case .high: return "🟠"
        case .medium: return "🟡"
        case .low: return "🟢"
        }
    }
    
    private func formatComparison(_ comparison: BaselineComparison, indent: String) -> String {
        var lines: [String] = []
        
        lines.append("\(indent)├─ Baseline: \(formatDuration(comparison.baseline.statistics.median))")
        lines.append("\(indent)├─ Current:  \(formatDuration(comparison.current.statistics.median))")
        lines.append("\(indent)└─ Change:   \(formatPercentage(comparison.timeDelta.percentageChange))")
        
        return lines.joined(separator: "\n")
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0.000001 {
            return String(format: "%.0f ns", seconds * 1_000_000_000)
        } else if seconds < 0.001 {
            return String(format: "%.2f µs", seconds * 1_000_000)
        } else if seconds < 1.0 {
            return String(format: "%.2f ms", seconds * 1_000)
        } else {
            return String(format: "%.2f s", seconds)
        }
    }
    
    private func formatPercentage(_ value: Double) -> String {
        return String(format: "%.1f%%", value * 100)
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}