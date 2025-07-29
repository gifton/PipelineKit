import Foundation
import PipelineKit

/// Main benchmark runner executable.
struct PipelineKitBenchmarkRunner {
    static func main() async {
        print("PipelineKit Benchmark Suite")
        print("===========================\n")
        
        // Parse command line arguments
        let arguments = CommandLine.arguments
        let shouldRunQuick = arguments.contains("--quick")
        let shouldSaveBaseline = arguments.contains("--save-baseline")
        let compareBaseline = arguments.contains("--compare-baseline")
        let specificBenchmark = arguments.firstIndex(of: "--benchmark").flatMap { idx in
            arguments.indices.contains(idx + 1) ? arguments[idx + 1] : nil
        }
        
        // Configure runner
        let configuration = shouldRunQuick ? BenchmarkConfiguration.quick : BenchmarkConfiguration.default
        let runner = BenchmarkRunner(configuration: configuration)
        
        // Select benchmarks to run
        let allBenchmarks = getAllBenchmarks()
        let benchmarksToRun: [any Benchmark]
        
        if let specific = specificBenchmark {
            benchmarksToRun = allBenchmarks.filter { $0.name.contains(specific) }
            if benchmarksToRun.isEmpty {
                print("No benchmark found matching: \(specific)")
                print("Available benchmarks:")
                for benchmark in allBenchmarks {
                    print("  - \(benchmark.name)")
                }
                return
            }
        } else {
            benchmarksToRun = allBenchmarks
        }
        
        // Run benchmarks
        do {
            let results = try await runner.runAll(benchmarksToRun)
            
            // Save baseline if requested
            if shouldSaveBaseline {
                try await saveBaseline(results)
                print("\nBaseline saved successfully.")
            }
            
            // Compare with baseline if requested
            if compareBaseline {
                await compareWithBaseline(results)
            }
            
            // Print summary
            if results.count > 1 {
                printOverallSummary(results)
            }
            
        } catch {
            print("\nError running benchmarks: \(error)")
            exit(1)
        }
    }
    
    /// Get all available benchmarks.
    static func getAllBenchmarks() -> [any Benchmark] {
        var benchmarks: [any Benchmark] = []
        
        // Add all benchmark suites
        benchmarks.append(contentsOf: SimpleBenchmarkSuite.all())
        benchmarks.append(contentsOf: CommandContextBenchmarkSuite.all())
        // benchmarks.append(contentsOf: PipelineBenchmarkSuite.all())
        // benchmarks.append(contentsOf: MiddlewareBenchmarkSuite.all())
        
        return benchmarks
    }
    
    /// Save results as baseline.
    static func saveBaseline(_ results: [BenchmarkResult]) async throws {
        let baselineDir = URL(fileURLWithPath: ".benchmarks/baselines")
        try FileManager.default.createDirectory(
            at: baselineDir,
            withIntermediateDirectories: true
        )
        
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let baselineFile = baselineDir.appendingPathComponent("baseline-\(timestamp).json")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(results)
        try data.write(to: baselineFile)
        
        // Also save as latest
        let latestFile = baselineDir.appendingPathComponent("latest.json")
        try data.write(to: latestFile)
    }
    
    /// Compare results with baseline.
    static func compareWithBaseline(_ results: [BenchmarkResult]) async {
        let baselineFile = URL(fileURLWithPath: ".benchmarks/baselines/latest.json")
        
        guard let data = try? Data(contentsOf: baselineFile),
              let baseline = try? JSONDecoder().decode([BenchmarkResult].self, from: data) else {
            print("\nNo baseline found for comparison.")
            return
        }
        
        print("\n\nComparison with Baseline")
        print("========================")
        
        for result in results {
            guard let baselineResult = baseline.first(where: { $0.name == result.name }) else {
                print("\n\(result.name): No baseline available")
                continue
            }
            
            let comparison = BenchmarkComparison(
                baseline: baselineResult,
                current: result
            )
            
            print("\n\(result.name):")
            print("  Change: \(String(format: "%+.1f%%", comparison.percentageChange))")
            print("  Status: \(comparison.message)")
            
            if comparison.isRegression {
                print("  ⚠️  REGRESSION DETECTED")
            }
        }
    }
    
    /// Print overall summary of all benchmarks.
    static func printOverallSummary(_ results: [BenchmarkResult]) {
        print("\n\nOverall Summary")
        print("===============")
        print("Total benchmarks run: \(results.count)")
        
        let totalSamples = results.reduce(0) { $0 + $1.statistics.count }
        print("Total samples collected: \(totalSamples)")
        
        let unstable = results.filter { !$0.statistics.isStable }
        if !unstable.isEmpty {
            print("\nUnstable benchmarks (high variance):")
            for result in unstable {
                print("  - \(result.name) (CV: \(String(format: "%.1f%%", result.statistics.coefficientOfVariation * 100)))")
            }
        }
        
        print("\nUsage:")
        print("  --quick              Run with reduced iterations")
        print("  --benchmark <name>   Run specific benchmark")
        print("  --save-baseline      Save results as baseline")
        print("  --compare-baseline   Compare with saved baseline")
    }
}


// Entry point
await PipelineKitBenchmarkRunner.main()