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
        let category = arguments.firstIndex(of: "--category").flatMap { idx in
            arguments.indices.contains(idx + 1) ? arguments[idx + 1] : nil
        }
        let listBaselines = arguments.contains("--list-baselines")
        let deleteBaselines = arguments.contains("--delete-baselines")
        let verbose = arguments.contains("--verbose")
        let showHelp = arguments.contains("--help") || arguments.contains("-h")
        
        // Show help if requested
        if showHelp {
            printHelp()
            return
        }
        
        // Configure runner
        let configuration = shouldRunQuick ? BenchmarkConfiguration.quick : BenchmarkConfiguration.default
        let runner = BenchmarkRunner(configuration: configuration)
        
        // Initialize baseline storage and regression detector
        let baselineStorage = BaselineStorage()
        let regressionConfig = RegressionDetector.Configuration(
            timeRegressionThreshold: 0.05,
            memoryRegressionThreshold: 0.10,
            failOnRegression: true,
            verbose: verbose
        )
        let regressionDetector = RegressionDetector(
            configuration: regressionConfig,
            baselineStorage: baselineStorage
        )
        
        do {
            // Handle baseline management commands
            if listBaselines {
                try await listAvailableBaselines(baselineStorage)
                return
            }
            
            if deleteBaselines {
                try await deleteAllBaselines(baselineStorage)
                return
            }
            
            // Select benchmarks to run
            let benchmarksToRun: [any Benchmark]
            
            if let categoryName = category {
                // Run by category
                if let benchmarkCategory = PipelineKitBenchmarkSuite.Category.allCases.first(where: { 
                    $0.rawValue.lowercased().contains(categoryName.lowercased())
                }) {
                    benchmarksToRun = PipelineKitBenchmarkSuite.benchmarks(for: benchmarkCategory)
                    print("Running category: \(benchmarkCategory.rawValue)")
                } else {
                    print("Unknown category: \(categoryName)")
                    print("Available categories:")
                    for cat in PipelineKitBenchmarkSuite.Category.allCases {
                        print("  - \(cat.rawValue)")
                    }
                    return
                }
            } else if let specific = specificBenchmark {
                // Run specific benchmark
                let allBenchmarks = PipelineKitBenchmarkSuite.allBenchmarks
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
                // Run all benchmarks
                benchmarksToRun = PipelineKitBenchmarkSuite.allBenchmarks
            }
            
            // Run benchmarks
            let results = try await runner.runAll(benchmarksToRun)
            
            // Save baseline if requested
            if shouldSaveBaseline {
                for result in results {
                    try await baselineStorage.saveBaseline(result)
                }
                print("\n✅ Baseline saved successfully for \(results.count) benchmark(s).")
            }
            
            // Compare with baseline if requested
            if compareBaseline {
                var regressionResults: [RegressionCheckResult] = []
                
                for result in results {
                    let checkResult = try await regressionDetector.checkForRegression(result)
                    regressionResults.append(checkResult)
                }
                
                let report = await regressionDetector.generateReport(regressionResults)
                print(report.format())
                
                // Exit with error code if regressions detected and configured to fail
                if report.hasRegressions && regressionConfig.failOnRegression {
                    exit(1)
                }
            }
            
            // Print summary
            if results.count > 1 && !compareBaseline {
                printOverallSummary(results)
            }
            
        } catch {
            print("\nError running benchmarks: \(error)")
            exit(1)
        }
    }
    
    /// Get all available benchmarks.
    static func getAllBenchmarks() -> [any Benchmark] {
        return PipelineKitBenchmarkSuite.allBenchmarks
    }
    
    /// List available baselines.
    static func listAvailableBaselines(_ storage: BaselineStorage) async throws {
        let baselines = try await storage.listBaselines()
        
        if baselines.isEmpty {
            print("No baselines found.")
        } else {
            print("Available baselines:")
            for baseline in baselines.sorted() {
                print("  - \(baseline)")
            }
        }
    }
    
    /// Delete all baselines.
    static func deleteAllBaselines(_ storage: BaselineStorage) async throws {
        print("Deleting all baselines...")
        try await storage.deleteAllBaselines()
        print("✅ All baselines deleted.")
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
    }
    
    /// Print help message.
    static func printHelp() {
        print("""
        Usage: swift run PipelineKitBenchmarks [options]
        
        Options:
          --quick                Run with reduced iterations
          --benchmark <name>     Run specific benchmark
          --category <name>      Run benchmarks by category
          --save-baseline        Save results as baseline
          --compare-baseline     Compare with saved baseline
          --list-baselines       List available baselines
          --delete-baselines     Delete all baselines
          --verbose              Show detailed output
          --help, -h             Show this help message
        
        Categories:
          context      - Context storage benchmarks
          middleware   - Middleware chain benchmarks
          pipeline     - Pipeline execution benchmarks
          optimization - Optimization benchmarks
          memory       - Memory management benchmarks
          concurrency  - Concurrency benchmarks
          all          - All benchmarks (default)
        
        Examples:
          # Run all benchmarks
          swift run PipelineKitBenchmarks
        
          # Run specific category
          swift run PipelineKitBenchmarks --category context
        
          # Run specific benchmark
          swift run PipelineKitBenchmarks --benchmark CommandContext
        
          # Save baseline
          swift run PipelineKitBenchmarks --save-baseline
        
          # Compare with baseline
          swift run PipelineKitBenchmarks --compare-baseline
        
          # Quick mode with specific benchmark
          swift run PipelineKitBenchmarks --quick --benchmark Context
        """)
    }
}

// Legacy support structures for transition
struct BenchmarkComparison {
    let baseline: BenchmarkResult
    let current: BenchmarkResult
    
    var percentageChange: Double {
        (current.statistics.median - baseline.statistics.median) / baseline.statistics.median * 100
    }
    
    var isRegression: Bool {
        percentageChange > 5.0
    }
    
    var message: String {
        if abs(percentageChange) < 1.0 {
            return "No significant change"
        } else if percentageChange > 0 {
            return isRegression ? "Performance regression" : "Slower but within tolerance"
        } else {
            return "Performance improvement"
        }
    }
}

// Entry point
await PipelineKitBenchmarkRunner.main()