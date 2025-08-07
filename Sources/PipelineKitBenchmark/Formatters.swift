import Foundation

/// Output format for benchmark results.
public enum OutputFormat: Sendable {
    /// Human-readable format for terminal output.
    case human
    
    /// JSON format for machine processing.
    case json
    
    /// CSV format for spreadsheet analysis.
    case csv
    
    /// Minimal format with just key metrics.
    case minimal
}

/// Memory usage information.
public struct MemoryInfo: Sendable {
    /// Memory used in bytes.
    public let used: Int
    
    /// Peak memory used.
    public let peak: Int
    
    /// Number of allocations.
    public let allocations: Int
    
    /// Get current memory info.
    static func current() -> MemoryInfo {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return MemoryInfo(
                used: Int(info.resident_size),
                peak: Int(info.resident_size_max),
                allocations: 0 // Would need malloc statistics for this
            )
        }
        
        return MemoryInfo(used: 0, peak: 0, allocations: 0)
    }
    
    /// Calculate delta between two memory snapshots.
    static func delta(from before: MemoryInfo?, to after: MemoryInfo?) -> MemoryInfo? {
        guard let before = before, let after = after else { return nil }
        
        return MemoryInfo(
            used: after.used - before.used,
            peak: after.peak,
            allocations: after.allocations - before.allocations
        )
    }
    
    /// Format memory size in human-readable format.
    public func formatted() -> String {
        formatBytes(used)
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(bytes)
        var unitIndex = 0
        
        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        
        return String(format: "%.1f%s", size, units[unitIndex])
    }
}

/// Format benchmark results for output.
public enum Formatter {
    
    /// Format a benchmark result.
    public static func format<T>(_ result: Benchmark.Result<T>, as format: OutputFormat) -> String {
        switch format {
        case .human:
            return formatHuman(result)
        case .json:
            return formatJSON(result)
        case .csv:
            return formatCSV(result)
        case .minimal:
            return formatMinimal(result)
        }
    }
    
    // MARK: - Human Format
    
    private static func formatHuman<T>(_ result: Benchmark.Result<T>) -> String {
        let formatter = DurationFormatter()
        var output = [String]()
        
        output.append("")
        output.append("=== \(result.metadata.name) ===")
        output.append("")
        
        // Basic timing
        output.append("Timing:")
        output.append("  Total: \(formatter.format(result.timing.total))")
        output.append("  Average: \(formatter.format(result.timing.average))")
        
        if result.metadata.iterations > 1 {
            output.append("  Min: \(formatter.format(result.timing.min))")
            output.append("  Max: \(formatter.format(result.timing.max))")
            
            let throughput = Double(result.metadata.iterations) / result.timing.total
            output.append("  Throughput: \(formatter.formatThroughput(throughput))")
        }
        
        // Statistics
        if let stats = result.statistics {
            output.append("")
            output.append("Statistics:")
            output.append("  Samples: \(stats.count)")
            output.append("  Std Dev: \(formatter.format(stats.standardDeviation))")
            output.append("  CV: \(String(format: "%.1f%%", stats.coefficientOfVariation * 100))")
            
            output.append("")
            output.append("Percentiles:")
            output.append("  P50: \(formatter.format(stats.p50))")
            output.append("  P90: \(formatter.format(stats.p90))")
            output.append("  P95: \(formatter.format(stats.p95))")
            output.append("  P99: \(formatter.format(stats.p99))")
            
            if !stats.outliers.isEmpty {
                output.append("")
                output.append("Outliers: \(stats.outliers.count) detected")
            }
        }
        
        // Memory info
        if let memory = result.memory {
            output.append("")
            output.append("Memory:")
            output.append("  Used: \(memory.formatted())")
            if memory.peak > 0 {
                output.append("  Peak: \(MemoryInfo(used: memory.peak, peak: memory.peak, allocations: 0).formatted())")
            }
        }
        
        output.append("")
        return output.joined(separator: "\n")
    }
    
    // MARK: - JSON Format
    
    private static func formatJSON<T>(_ result: Benchmark.Result<T>) -> String {
        var json: [String: Any] = [
            "name": result.metadata.name,
            "timestamp": ISO8601DateFormatter().string(from: result.metadata.timestamp),
            "iterations": result.metadata.iterations,
            "warmup_iterations": result.metadata.warmupIterations,
            "concurrent_tasks": result.metadata.concurrentTasks,
            "timing": [
                "total": result.timing.total,
                "average": result.timing.average,
                "min": result.timing.min,
                "max": result.timing.max
            ]
        ]
        
        if let stats = result.statistics {
            json["statistics"] = [
                "count": stats.count,
                "mean": stats.mean,
                "median": stats.median,
                "std_dev": stats.standardDeviation,
                "variance": stats.variance,
                "cv": stats.coefficientOfVariation,
                "p50": stats.p50,
                "p90": stats.p90,
                "p95": stats.p95,
                "p99": stats.p99,
                "p999": stats.p999,
                "min": stats.min,
                "max": stats.max,
                "range": stats.range,
                "outliers": stats.outliers.count
            ]
        }
        
        if let memory = result.memory {
            json["memory"] = [
                "used": memory.used,
                "peak": memory.peak,
                "allocations": memory.allocations
            ]
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"Failed to encode JSON\"}"
        }
    }
    
    // MARK: - CSV Format
    
    private static func formatCSV<T>(_ result: Benchmark.Result<T>) -> String {
        var headers = ["name", "timestamp", "iterations", "total", "average", "min", "max"]
        var values = [
            result.metadata.name,
            ISO8601DateFormatter().string(from: result.metadata.timestamp),
            String(result.metadata.iterations),
            String(result.timing.total),
            String(result.timing.average),
            String(result.timing.min),
            String(result.timing.max)
        ]
        
        if let stats = result.statistics {
            headers.append(contentsOf: ["mean", "median", "std_dev", "p95", "p99"])
            values.append(contentsOf: [
                String(stats.mean),
                String(stats.median),
                String(stats.standardDeviation),
                String(stats.p95),
                String(stats.p99)
            ])
        }
        
        if let memory = result.memory {
            headers.append(contentsOf: ["memory_used", "memory_peak"])
            values.append(contentsOf: [
                String(memory.used),
                String(memory.peak)
            ])
        }
        
        return headers.joined(separator: ",") + "\n" + values.joined(separator: ",")
    }
    
    // MARK: - Minimal Format
    
    private static func formatMinimal<T>(_ result: Benchmark.Result<T>) -> String {
        let formatter = DurationFormatter()
        let throughput = Double(result.metadata.iterations) / result.timing.total
        
        return "\(result.metadata.name): \(formatter.format(result.timing.average)) avg, \(formatter.formatThroughput(throughput))"
    }
}