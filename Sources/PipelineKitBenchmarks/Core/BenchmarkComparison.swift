import Foundation

/// Tools for comparing benchmark results.
public struct BenchmarkComparison {
    /// Comparison result between two benchmark runs.
    public struct ComparisonResult: Sendable {
        public let name: String
        public let baseline: BenchmarkStatistics
        public let current: BenchmarkStatistics
        public let percentageChange: Double
        public let isRegression: Bool
        public let isImprovement: Bool
        public let significanceLevel: Double
        
        /// Format the comparison as a string.
        public func format() -> String {
            let changeSymbol: String
            let changeColor: String
            
            if abs(percentageChange) < 1.0 {
                changeSymbol = "≈"
                changeColor = ""
            } else if percentageChange > 0 {
                changeSymbol = isRegression ? "⚠️" : "+"
                changeColor = isRegression ? "" : ""
            } else {
                changeSymbol = isImprovement ? "✅" : "-"
                changeColor = isImprovement ? "" : ""
            }
            
            var output = "\(name):\n"
            output += "  Baseline: \(BenchmarkFormatter.duration(baseline.median))\n"
            output += "  Current:  \(BenchmarkFormatter.duration(current.median))\n"
            output += "  Change:   \(changeSymbol)\(String(format: "%.1f", abs(percentageChange)))%"
            
            if significanceLevel < 0.05 {
                output += " (statistically significant)"
            }
            
            return output
        }
    }
    
    /// Compare two benchmark results.
    public static func compare(
        baseline: BenchmarkResult,
        current: BenchmarkResult,
        threshold: Double = 0.05
    ) -> ComparisonResult {
        let baselineMedian = baseline.statistics.median
        let currentMedian = current.statistics.median
        
        let percentageChange = ((currentMedian - baselineMedian) / baselineMedian) * 100
        
        // Use t-test for statistical significance
        let significanceLevel = Statistics.tTest(
            baseline: baseline.measurements.map { $0.duration },
            current: current.measurements.map { $0.duration }
        )
        
        return ComparisonResult(
            name: current.metadata.benchmarkName,
            baseline: baseline.statistics,
            current: current.statistics,
            percentageChange: percentageChange,
            isRegression: percentageChange > threshold * 100,
            isImprovement: percentageChange < -threshold * 100,
            significanceLevel: significanceLevel
        )
    }
    
    /// Compare multiple benchmark results.
    public static func compareMultiple(
        baselines: [String: BenchmarkResult],
        current: [String: BenchmarkResult],
        threshold: Double = 0.05
    ) -> [ComparisonResult] {
        var comparisons: [ComparisonResult] = []
        
        for (name, currentResult) in current {
            guard let baselineResult = baselines[name] else {
                continue
            }
            
            let comparison = compare(
                baseline: baselineResult,
                current: currentResult,
                threshold: threshold
            )
            comparisons.append(comparison)
        }
        
        return comparisons.sorted { $0.name < $1.name }
    }
    
    /// Generate a comparison report.
    public static func generateReport(
        comparisons: [ComparisonResult],
        title: String = "Benchmark Comparison Report"
    ) -> String {
        var output = [String]()
        
        output.append("═══════════════════════════════════════════════════════════════")
        output.append(title.center(63))
        output.append("═══════════════════════════════════════════════════════════════")
        output.append("")
        
        // Summary
        let regressions = comparisons.filter { $0.isRegression }
        let improvements = comparisons.filter { $0.isImprovement }
        let stable = comparisons.filter { !$0.isRegression && !$0.isImprovement }
        
        output.append("Summary:")
        output.append("  Total benchmarks: \(comparisons.count)")
        output.append("  Regressions:      \(regressions.count)")
        output.append("  Improvements:     \(improvements.count)")
        output.append("  Stable:           \(stable.count)")
        output.append("")
        
        // Regressions
        if !regressions.isEmpty {
            output.append("⚠️  REGRESSIONS:")
            output.append("───────────────")
            for regression in regressions.sorted(by: { $0.percentageChange > $1.percentageChange }) {
                output.append(formatComparison(regression, indent: "  "))
                output.append("")
            }
        }
        
        // Improvements
        if !improvements.isEmpty {
            output.append("✅ IMPROVEMENTS:")
            output.append("───────────────")
            for improvement in improvements.sorted(by: { $0.percentageChange < $1.percentageChange }) {
                output.append(formatComparison(improvement, indent: "  "))
                output.append("")
            }
        }
        
        // Stable
        if !stable.isEmpty {
            output.append("➡️  STABLE:")
            output.append("──────────")
            for result in stable {
                output.append(formatComparison(result, indent: "  "))
                output.append("")
            }
        }
        
        // Statistical summary
        output.append("Statistical Analysis:")
        output.append("────────────────────")
        let significantChanges = comparisons.filter { $0.significanceLevel < 0.05 }
        output.append("  Statistically significant changes: \(significantChanges.count)")
        
        if !comparisons.isEmpty {
            let avgChange = comparisons.map { $0.percentageChange }.reduce(0, +) / Double(comparisons.count)
            output.append("  Average change: \(String(format: "%.1f", avgChange))%")
        }
        
        output.append("")
        output.append("═══════════════════════════════════════════════════════════════")
        
        return output.joined(separator: "\n")
    }
    
    private static func formatComparison(_ comparison: ComparisonResult, indent: String) -> String {
        var lines = [String]()
        
        lines.append("\(indent)\(comparison.name)")
        lines.append("\(indent)  Baseline: \(BenchmarkFormatter.duration(comparison.baseline.median))")
        lines.append("\(indent)  Current:  \(BenchmarkFormatter.duration(comparison.current.median))")
        
        let changeSymbol = comparison.percentageChange > 0 ? "+" : ""
        lines.append("\(indent)  Change:   \(changeSymbol)\(String(format: "%.1f", comparison.percentageChange))%")
        
        if comparison.significanceLevel < 0.05 {
            lines.append("\(indent)  Status:   Statistically significant (p=\(String(format: "%.4f", comparison.significanceLevel)))")
        } else {
            lines.append("\(indent)  Status:   Not statistically significant")
        }
        
        // Memory comparison if available
        if let baselineMemory = comparison.baseline.memoryPeakMedian,
           let currentMemory = comparison.current.memoryPeakMedian {
            let memoryChange = ((Double(currentMemory) - Double(baselineMemory)) / Double(baselineMemory)) * 100
            lines.append("\(indent)  Memory:   \(memoryChange > 0 ? "+" : "")\(String(format: "%.1f", memoryChange))%")
        }
        
        return lines.joined(separator: "\n")
    }
}

// MARK: - Visualization

extension BenchmarkComparison {
    /// Generate an ASCII chart comparing benchmarks.
    public static func generateChart(comparisons: [ComparisonResult], width: Int = 60) -> String {
        var output = [String]()
        
        output.append("Performance Comparison Chart")
        output.append("═" * width)
        output.append("")
        
        // Find max name length for alignment
        let maxNameLength = comparisons.map { $0.name.count }.max() ?? 0
        
        // Find max percentage for scaling
        let maxPercentage = comparisons.map { abs($0.percentageChange) }.max() ?? 1.0
        let scale = Double(width - maxNameLength - 15) / maxPercentage
        
        for comparison in comparisons {
            let name = comparison.name.padding(toLength: maxNameLength, withPad: " ", startingAt: 0)
            let percentage = comparison.percentageChange
            let barLength = Int(abs(percentage) * scale)
            
            var bar: String
            if abs(percentage) < 1.0 {
                bar = "│"
            } else if percentage > 0 {
                bar = "│" + String(repeating: "█", count: barLength) + "▶"
            } else {
                bar = "◀" + String(repeating: "█", count: barLength) + "│"
            }
            
            let percentStr = String(format: "%+.1f%%", percentage)
            output.append("\(name) \(percentStr.padding(toLength: 8, withPad: " ", startingAt: 0)) \(bar)")
        }
        
        output.append("")
        output.append("═" * width)
        output.append("◀ Faster | Slower ▶")
        
        return output.joined(separator: "\n")
    }
}

// MARK: - Helpers

private extension String {
    func center(_ width: Int) -> String {
        let padding = max(0, width - count)
        let leftPad = padding / 2
        let rightPad = padding - leftPad
        return String(repeating: " ", count: leftPad) + self + String(repeating: " ", count: rightPad)
    }
    
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}