import Foundation
import PipelineKit

/// Command-line benchmark runner for PipelineKit
@main
struct BenchmarkRunner {
    static func main() async {
        print("🚀 PipelineKit Performance Benchmark Runner")
        print("=" * 60)
        print("System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Processors: \(ProcessInfo.processInfo.processorCount)")
        print("Memory: \(formatBytes(ProcessInfo.processInfo.physicalMemory))")
        print("Date: \(Date())")
        print("=" * 60)
        
        // Parse command line arguments
        let arguments = CommandLine.arguments
        let iterations = parseIterations(from: arguments)
        let warmup = parseWarmup(from: arguments)
        let outputFormat = parseFormat(from: arguments)
        
        // Run benchmarks
        let benchmark = PipelineKitPerformanceBenchmark(
            iterations: iterations,
            warmupIterations: warmup
        )
        
        do {
            let results = try await benchmark.runAll()
            
            // Output results
            switch outputFormat {
            case .console:
                // Already printed by benchmark
                break
            case .json:
                outputJSON(results)
            case .csv:
                outputCSV(results)
            case .markdown:
                outputMarkdown(results)
            }
            
            // Generate comparison report if baseline exists
            if let baseline = loadBaseline() {
                generateComparisonReport(current: results, baseline: baseline)
            }
            
            // Save as new baseline if requested
            if arguments.contains("--save-baseline") {
                saveBaseline(results)
                print("\n✅ Saved results as new baseline")
            }
            
        } catch {
            print("\n❌ Error running benchmarks: \(error)")
            exit(1)
        }
    }
    
    // MARK: - Command Line Parsing
    
    private static func parseIterations(from args: [String]) -> Int {
        if let index = args.firstIndex(of: "--iterations"),
           index + 1 < args.count,
           let value = Int(args[index + 1]) {
            return value
        }
        return 10000 // Default
    }
    
    private static func parseWarmup(from args: [String]) -> Int {
        if let index = args.firstIndex(of: "--warmup"),
           index + 1 < args.count,
           let value = Int(args[index + 1]) {
            return value
        }
        return 100 // Default
    }
    
    private static func parseFormat(from args: [String]) -> OutputFormat {
        if let index = args.firstIndex(of: "--format"),
           index + 1 < args.count {
            switch args[index + 1].lowercased() {
            case "json": return .json
            case "csv": return .csv
            case "markdown": return .markdown
            default: return .console
            }
        }
        return .console
    }
    
    private enum OutputFormat {
        case console
        case json
        case csv
        case markdown
    }
    
    // MARK: - Output Formats
    
    private static func outputJSON(_ results: [PipelineKitPerformanceBenchmark.BenchmarkResult]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let output = BenchmarkOutput(
            timestamp: Date(),
            system: ProcessInfo.processInfo.operatingSystemVersionString,
            results: results.map { result in
                BenchmarkOutput.Result(
                    name: result.name,
                    iterations: result.iterations,
                    averageTimeMs: result.averageTimeMilliseconds,
                    minTimeMs: result.minTime * 1000,
                    maxTimeMs: result.maxTime * 1000,
                    standardDeviationMs: result.standardDeviation * 1000
                )
            }
        )
        
        if let data = try? encoder.encode(output),
           let json = String(data: data, encoding: .utf8) {
            print("\n" + json)
        }
    }
    
    private static func outputCSV(_ results: [PipelineKitPerformanceBenchmark.BenchmarkResult]) {
        print("\nBenchmark,Iterations,Average(ms),Min(ms),Max(ms),StdDev(ms)")
        for result in results {
            print("\(result.name),\(result.iterations),\(result.averageTimeMilliseconds),\(result.minTime * 1000),\(result.maxTime * 1000),\(result.standardDeviation * 1000)")
        }
    }
    
    private static func outputMarkdown(_ results: [PipelineKitPerformanceBenchmark.BenchmarkResult]) {
        print("\n## PipelineKit Performance Benchmarks")
        print("\n| Benchmark | Iterations | Average (ms) | Min (ms) | Max (ms) | Std Dev (ms) |")
        print("|-----------|------------|--------------|----------|----------|--------------|")
        
        for result in results {
            print(String(format: "| %-40s | %10d | %12.3f | %8.3f | %8.3f | %12.3f |",
                result.name,
                result.iterations,
                result.averageTimeMilliseconds,
                result.minTime * 1000,
                result.maxTime * 1000,
                result.standardDeviation * 1000
            ))
        }
    }
    
    // MARK: - Baseline Management
    
    private static func loadBaseline() -> [PipelineKitPerformanceBenchmark.BenchmarkResult]? {
        let baselinePath = FileManager.default.currentDirectoryPath + "/benchmark-baseline.json"
        
        guard FileManager.default.fileExists(atPath: baselinePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: baselinePath)),
              let output = try? JSONDecoder().decode(BenchmarkOutput.self, from: data) else {
            return nil
        }
        
        return output.results.map { result in
            PipelineKitPerformanceBenchmark.BenchmarkResult(
                name: result.name,
                iterations: result.iterations,
                totalTime: Double(result.iterations) * result.averageTimeMs / 1000,
                averageTime: result.averageTimeMs / 1000,
                minTime: result.minTimeMs / 1000,
                maxTime: result.maxTimeMs / 1000,
                standardDeviation: result.standardDeviationMs / 1000
            )
        }
    }
    
    private static func saveBaseline(_ results: [PipelineKitPerformanceBenchmark.BenchmarkResult]) {
        let baselinePath = FileManager.default.currentDirectoryPath + "/benchmark-baseline.json"
        outputJSON(results) // This will save to the baseline file
    }
    
    private static func generateComparisonReport(
        current: [PipelineKitPerformanceBenchmark.BenchmarkResult],
        baseline: [PipelineKitPerformanceBenchmark.BenchmarkResult]
    ) {
        print("\n" + "=" * 60)
        print("📊 Performance Comparison vs Baseline")
        print("=" * 60)
        
        var improvements: [(name: String, change: Double)] = []
        var regressions: [(name: String, change: Double)] = []
        
        for currentResult in current {
            if let baselineResult = baseline.first(where: { $0.name == currentResult.name }) {
                let change = ((baselineResult.averageTime - currentResult.averageTime) / baselineResult.averageTime) * 100
                
                print(String(format: "%-40s: %8.3fms → %8.3fms (%+.1f%%)",
                    currentResult.name,
                    baselineResult.averageTimeMilliseconds,
                    currentResult.averageTimeMilliseconds,
                    change
                ))
                
                if change > 5 {
                    improvements.append((currentResult.name, change))
                } else if change < -5 {
                    regressions.append((currentResult.name, change))
                }
            }
        }
        
        if !improvements.isEmpty {
            print("\n✅ Significant Improvements:")
            for (name, change) in improvements.sorted(by: { $0.change > $1.change }) {
                print(String(format: "  • %-36s: %.1f%% faster", name, change))
            }
        }
        
        if !regressions.isEmpty {
            print("\n⚠️  Performance Regressions:")
            for (name, change) in regressions.sorted(by: { $0.change < $1.change }) {
                print(String(format: "  • %-36s: %.1f%% slower", name, abs(change)))
            }
        }
    }
    
    // MARK: - Helpers
    
    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Supporting Types

private struct BenchmarkOutput: Codable {
    let timestamp: Date
    let system: String
    let results: [Result]
    
    struct Result: Codable {
        let name: String
        let iterations: Int
        let averageTimeMs: Double
        let minTimeMs: Double
        let maxTimeMs: Double
        let standardDeviationMs: Double
    }
}

// String multiplication extension
private extension String {
    static func *(lhs: String, rhs: Int) -> String {
        return String(repeating: lhs, count: rhs)
    }
}