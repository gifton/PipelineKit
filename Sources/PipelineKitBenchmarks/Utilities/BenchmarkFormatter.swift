import Foundation

/// Formatting utilities for benchmark output.
public enum BenchmarkFormatter {
    /// Format a duration in seconds to a human-readable string.
    public static func duration(_ seconds: TimeInterval) -> String {
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
    
    /// Format bytes to a human-readable string.
    public static func bytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var unitIndex = 0
        
        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        
        if unitIndex == 0 {
            return "\(Int(size)) \(units[unitIndex])"
        } else {
            return String(format: "%.2f %@", size, units[unitIndex])
        }
    }
    
    /// Format a number with appropriate units.
    public static func number(_ value: Double) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.2fB", value / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.2fK", value / 1_000)
        } else if value >= 1 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.3f", value)
        }
    }
    
    /// Format a percentage.
    public static func percentage(_ value: Double) -> String {
        return String(format: "%.1f%%", value * 100)
    }
    
    /// Format benchmark results as a table.
    public static func table(results: [BenchmarkResult]) -> String {
        var output = [String]()
        
        // Header
        output.append("┌─────────────────────────────────┬──────────────┬──────────────┬──────────────┐")
        output.append("│ Benchmark                       │ Median       │ Mean         │ Std Dev      │")
        output.append("├─────────────────────────────────┼──────────────┼──────────────┼──────────────┤")
        
        // Rows
        for result in results {
            let name = result.metadata.benchmarkName.padding(toLength: 31, withPad: " ", startingAt: 0)
            let median = duration(result.statistics.median).padding(toLength: 12, withPad: " ", startingAt: 0)
            let mean = duration(result.statistics.mean).padding(toLength: 12, withPad: " ", startingAt: 0)
            let stdDev = duration(result.statistics.standardDeviation).padding(toLength: 12, withPad: " ", startingAt: 0)
            
            output.append("│ \(name) │ \(median) │ \(mean) │ \(stdDev) │")
        }
        
        output.append("└─────────────────────────────────┴──────────────┴──────────────┴──────────────┘")
        
        return output.joined(separator: "\n")
    }
    
    /// Format a single benchmark result.
    public static func result(_ result: BenchmarkResult, verbose: Bool = false) -> String {
        var output = [String]()
        
        output.append("Benchmark: \(result.metadata.benchmarkName)")
        output.append("─────────────────────────────────────")
        
        // Basic statistics
        output.append("Timing:")
        output.append("  Median:     \(duration(result.statistics.median))")
        output.append("  Mean:       \(duration(result.statistics.mean))")
        output.append("  Std Dev:    \(duration(result.statistics.standardDeviation))")
        
        if let p95 = result.statistics.p95 {
            output.append("  P95:        \(duration(p95))")
        }
        if let p99 = result.statistics.p99 {
            output.append("  P99:        \(duration(p99))")
        }
        
        // Memory statistics
        if let memStats = result.memoryStatistics {
            output.append("")
            output.append("Memory:")
            output.append("  Peak:       \(bytes(memStats.peakMedian))")
            output.append("  Allocated:  \(bytes(memStats.allocatedMedian))")
            if memStats.allocationsMedian > 0 {
                output.append("  Allocations: \(Int(memStats.allocationsMedian))")
            }
        }
        
        // Performance metrics
        output.append("")
        output.append("Performance:")
        let opsPerSec = 1.0 / result.statistics.median
        output.append("  Throughput: \(number(opsPerSec)) ops/sec")
        
        if result.statistics.coefficientOfVariation < 0.05 {
            output.append("  Stability:  ✅ Excellent (CV: \(percentage(result.statistics.coefficientOfVariation)))")
        } else if result.statistics.coefficientOfVariation < 0.10 {
            output.append("  Stability:  ⚠️  Good (CV: \(percentage(result.statistics.coefficientOfVariation)))")
        } else {
            output.append("  Stability:  ❌ Poor (CV: \(percentage(result.statistics.coefficientOfVariation)))")
        }
        
        // Warnings
        if !result.warnings.isEmpty {
            output.append("")
            output.append("Warnings:")
            for warning in result.warnings {
                output.append("  ⚠️  \(warning)")
            }
        }
        
        // Verbose output
        if verbose {
            output.append("")
            output.append("Details:")
            output.append("  Iterations:  \(result.measurements.count)")
            output.append("  Total time:  \(duration(result.statistics.sum))")
            output.append("  Min:         \(duration(result.statistics.min))")
            output.append("  Max:         \(duration(result.statistics.max))")
        }
        
        return output.joined(separator: "\n")
    }
}