import Foundation

/// Adapter for running legacy benchmarks through the modern infrastructure.
///
/// This adapter allows existing standalone benchmark scripts to be integrated
/// into the new benchmarking framework without requiring immediate rewrites.
public struct LegacyBenchmarkAdapter: Benchmark {
    public let name: String
    public let iterations: Int
    public let warmupIterations: Int
    
    private let benchmarkClosure: () async throws -> Void
    
    /// Creates a legacy benchmark adapter.
    ///
    /// - Parameters:
    ///   - name: The benchmark name.
    ///   - iterations: Number of iterations to run.
    ///   - warmupIterations: Number of warmup iterations.
    ///   - benchmark: The benchmark closure to execute.
    public init(
        name: String,
        iterations: Int = 1000,
        warmupIterations: Int = 100,
        benchmark: @escaping () async throws -> Void
    ) {
        self.name = name
        self.iterations = iterations
        self.warmupIterations = warmupIterations
        self.benchmarkClosure = benchmark
    }
    
    /// Creates a legacy benchmark adapter from a synchronous benchmark.
    ///
    /// - Parameters:
    ///   - name: The benchmark name.
    ///   - iterations: Number of iterations to run.
    ///   - warmupIterations: Number of warmup iterations.
    ///   - benchmark: The synchronous benchmark closure to execute.
    public init(
        name: String,
        iterations: Int = 1000,
        warmupIterations: Int = 100,
        benchmark: @escaping () throws -> Void
    ) {
        self.name = name
        self.iterations = iterations
        self.warmupIterations = warmupIterations
        self.benchmarkClosure = {
            try await Task {
                try benchmark()
            }.value
        }
    }
    
    public func run() async throws {
        try await benchmarkClosure()
    }
}

/// Builder for migrating legacy benchmark patterns.
public struct LegacyBenchmarkMigrator {
    /// Migrates a measure-style benchmark.
    ///
    /// This converts the common pattern:
    /// ```
    /// measure("Name", iterations: N) { ... }
    /// ```
    /// Into a proper Benchmark implementation.
    public static func migrate(
        name: String,
        iterations: Int,
        warmup: Int = 100,
        block: @escaping () throws -> Void
    ) -> LegacyBenchmarkAdapter {
        return LegacyBenchmarkAdapter(
            name: name,
            iterations: iterations,
            warmupIterations: warmup,
            benchmark: block
        )
    }
    
    /// Migrates a parameterized benchmark.
    ///
    /// This converts benchmarks that set up data before measuring.
    public static func migrateParameterized<T>(
        name: String,
        iterations: Int,
        warmup: Int = 100,
        setup: @escaping () throws -> T,
        benchmark: @escaping (T) throws -> Void
    ) -> ParameterizedBenchmarkAdapter<T> {
        return ParameterizedBenchmarkAdapter(
            name: name,
            iterations: iterations,
            warmupIterations: warmup,
            setup: setup,
            benchmark: benchmark
        )
    }
}

/// Adapter for parameterized legacy benchmarks.
public struct ParameterizedBenchmarkAdapter<Input>: ParameterizedBenchmark {
    public let name: String
    public let iterations: Int
    public let warmupIterations: Int
    
    private let setupClosure: () async throws -> Input
    private let benchmarkClosure: (Input) async throws -> Void
    
    init(
        name: String,
        iterations: Int,
        warmupIterations: Int,
        setup: @escaping () throws -> Input,
        benchmark: @escaping (Input) throws -> Void
    ) {
        self.name = name
        self.iterations = iterations
        self.warmupIterations = warmupIterations
        self.setupClosure = {
            try await Task { try setup() }.value
        }
        self.benchmarkClosure = { input in
            try await Task { try benchmark(input) }.value
        }
    }
    
    public func makeInput() async throws -> Input {
        try await setupClosure()
    }
    
    public func run(input: Input) async throws {
        try await benchmarkClosure(input)
    }
}

/// Convenience extensions for running legacy benchmarks.
extension BenchmarkRunner {
    /// Runs a legacy benchmark using the modern infrastructure.
    public static func runLegacy(
        name: String,
        iterations: Int = 1000,
        warmup: Int = 100,
        benchmark: @escaping () throws -> Void
    ) async throws -> BenchmarkResult {
        let adapter = LegacyBenchmarkAdapter(
            name: name,
            iterations: iterations,
            warmupIterations: warmup,
            benchmark: benchmark
        )
        
        let runner = BenchmarkRunner()
        return try await runner.run(adapter)
    }
    
    /// Runs multiple legacy benchmarks and formats results.
    public static func runLegacySuite(
        _ benchmarks: [(name: String, iterations: Int, block: () throws -> Void)]
    ) async throws {
        print("PipelineKit Legacy Benchmark Suite")
        print("==================================\n")
        
        var results: [BenchmarkResult] = []
        
        for (name, iterations, block) in benchmarks {
            let result = try await runLegacy(
                name: name,
                iterations: iterations,
                benchmark: block
            )
            results.append(result)
            
            // Print immediate result
            print("Benchmark: \(name)")
            print("  Median: \(formatDuration(result.statistics.median))")
            print("  Mean: \(formatDuration(result.statistics.mean))")
            print("  Std Dev: \(formatDuration(result.statistics.standardDeviation))")
            if let p95 = result.statistics.p95 {
                print("  P95: \(formatDuration(p95))")
            }
            print()
        }
        
        // Summary
        print("\nSummary")
        print("-------")
        for result in results {
            let opsPerSec = 1.0 / result.statistics.median
            print("\(result.metadata.benchmarkName): \(formatDuration(result.statistics.median)) (\(Int(opsPerSec)) ops/sec)")
        }
    }
    
    private static func formatDuration(_ seconds: TimeInterval) -> String {
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
}