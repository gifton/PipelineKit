import Foundation

/// A benchmark that can be run and measured.
///
/// Benchmarks provide a standardized way to measure performance of code,
/// including warm-up phases, multiple iterations, and statistical analysis.
///
/// ## Example
/// ```swift
/// struct ContextAccessBenchmark: Benchmark {
///     let name = "CommandContext Access"
///     let iterations = 10_000
///     let warmupIterations = 1_000
///     
///     func run() async throws {
///         let context = CommandContext()
///         for i in 0..<1000 {
///             context.set(i, for: TestKey.self)
///             _ = context.get(TestKey.self)
///         }
///     }
/// }
/// ```
public protocol Benchmark: Sendable {
    /// The name of this benchmark.
    var name: String { get }
    
    /// Number of iterations to run for measurement.
    var iterations: Int { get }
    
    /// Number of warm-up iterations before measurement.
    var warmupIterations: Int { get }
    
    /// Set up any resources needed for the benchmark.
    /// Called once before warm-up iterations.
    func setUp() async throws
    
    /// Clean up any resources after the benchmark.
    /// Called once after all iterations complete.
    func tearDown() async throws
    
    /// Run one iteration of the benchmark.
    /// This is what gets measured.
    func run() async throws
}

// Default implementations
public extension Benchmark {
    var iterations: Int { 1000 }
    var warmupIterations: Int { 100 }
    
    func setUp() async throws {
        // Default: no setup needed
    }
    
    func tearDown() async throws {
        // Default: no teardown needed
    }
}

/// A benchmark that operates on specific input.
public protocol ParameterizedBenchmark: Benchmark {
    associatedtype Input: Sendable
    
    /// Generate or provide the input for benchmark iterations.
    func makeInput() async throws -> Input
    
    /// Run one iteration with the given input.
    func run(input: Input) async throws
}

public extension ParameterizedBenchmark {
    /// Default implementation that generates input and calls parameterized run.
    func run() async throws {
        let input = try await makeInput()
        try await run(input: input)
    }
}

/// Configuration for benchmark execution.
public struct BenchmarkConfiguration: Sendable {
    /// Maximum time to run the benchmark (seconds).
    public let timeout: TimeInterval
    
    /// Whether to collect memory statistics.
    public let measureMemory: Bool
    
    /// Whether to collect detailed timing percentiles.
    public let collectPercentiles: Bool
    
    /// Number of iterations between progress updates.
    public let progressInterval: Int?
    
    /// Whether to run in quiet mode (minimal output).
    public let quiet: Bool
    
    public init(
        timeout: TimeInterval = 300,
        measureMemory: Bool = true,
        collectPercentiles: Bool = true,
        progressInterval: Int? = nil,
        quiet: Bool = false
    ) {
        self.timeout = timeout
        self.measureMemory = measureMemory
        self.collectPercentiles = collectPercentiles
        self.progressInterval = progressInterval
        self.quiet = quiet
    }
    
    /// Default configuration for most benchmarks.
    public static let `default` = BenchmarkConfiguration()
    
    /// Configuration for quick smoke tests.
    public static let quick = BenchmarkConfiguration(
        timeout: 30,
        measureMemory: false,
        collectPercentiles: false,
        quiet: true
    )
    
    /// Configuration for detailed analysis.
    public static let detailed = BenchmarkConfiguration(
        timeout: 600,
        measureMemory: true,
        collectPercentiles: true,
        progressInterval: 100
    )
}