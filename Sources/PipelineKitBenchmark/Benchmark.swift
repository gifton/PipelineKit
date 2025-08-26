import Foundation

/// Benchmark-related errors
public enum BenchmarkError: Error {
    case noIterationsExecuted
}

/// A high-performance benchmarking framework with zero-overhead abstractions.
public struct Benchmark: Sendable {
    // MARK: - Types

    /// The result of a benchmark operation.
    public struct Result<T: Sendable>: Sendable {
        /// The value returned by the benchmark operation.
        public let value: T

        /// Timing information for the benchmark.
        public let timing: Timing

        /// Statistical analysis of multiple iterations.
        public let statistics: Statistics?

        /// Memory usage information if tracking was enabled.
        public let memory: MemoryInfo?

        /// Metadata about the benchmark execution.
        public let metadata: Metadata
    }

    /// Metadata about benchmark execution.
    public struct Metadata: Sendable {
        public let name: String
        public let iterations: Int
        public let warmupIterations: Int
        public let concurrentTasks: Int
        public let timestamp: Date

        init(
            name: String,
            iterations: Int,
            warmupIterations: Int,
            concurrentTasks: Int = 1
        ) {
            self.name = name
            self.iterations = iterations
            self.warmupIterations = warmupIterations
            self.concurrentTasks = concurrentTasks
            self.timestamp = Date()
        }
    }

    /// Configuration for benchmark execution.
    @usableFromInline
    struct Configuration: Sendable {
        var name: String
        var iterations: Int = 1
        var warmupIterations: Int = 0
        var concurrentTasks: Int = 1
        var trackMemory: Bool = false
        var outputFormat: OutputFormat = .human
        var quiet: Bool = false
    }

    // MARK: - Properties

    @usableFromInline
    internal var configuration: Configuration // swiftlint:disable:this attributes

    // MARK: - Initialization

    @usableFromInline
    internal init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Measure the performance of an operation.
    ///
    /// - Parameters:
    ///   - name: Name of the benchmark
    ///   - iterations: Number of iterations to run
    ///   - warmup: Number of warmup iterations
    ///   - operation: The operation to benchmark
    /// - Returns: Benchmark result with timing and statistics
    public static func measure<T: Sendable>(
        _ name: String,
        iterations: Int = 1,
        warmup: Int = 0,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> Result<T> {
        let benchmark = Benchmark(configuration: Configuration(
            name: name,
            iterations: iterations,
            warmupIterations: warmup
        ))
        return try await benchmark.run(operation)
    }

    /// Create a benchmark with a specific name.
    public static func named(_ name: String) -> Benchmark {
        Benchmark(configuration: Configuration(name: name))
    }

    // MARK: - Fluent Configuration

    /// Set the number of iterations.
    public func iterations(_ count: Int) -> Benchmark {
        var config = configuration
        config.iterations = count
        return Benchmark(configuration: config)
    }

    /// Set the number of warmup iterations.
    public func warmup(_ count: Int) -> Benchmark {
        var config = configuration
        config.warmupIterations = count
        return Benchmark(configuration: config)
    }

    /// Run the benchmark with concurrent tasks.
    public func concurrent(tasks: Int) -> Benchmark {
        var config = configuration
        config.concurrentTasks = tasks
        return Benchmark(configuration: config)
    }

    /// Enable memory tracking.
    public func memory(tracking: Bool = true) -> Benchmark {
        var config = configuration
        config.trackMemory = tracking
        return Benchmark(configuration: config)
    }

    /// Set the output format.
    public func output(_ format: OutputFormat) -> Benchmark {
        var config = configuration
        config.outputFormat = format
        return Benchmark(configuration: config)
    }

    /// Run in quiet mode (no output during execution).
    public func quiet(_ enabled: Bool = true) -> Benchmark {
        var config = configuration
        config.quiet = enabled
        return Benchmark(configuration: config)
    }

    // MARK: - Execution

    /// Run the benchmark with the configured settings.
    public func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> Result<T> {
        // Run warmup iterations
        if configuration.warmupIterations > 0 && !configuration.quiet {
            print("Running \(configuration.warmupIterations) warmup iterations...")
        }

        for _ in 0..<configuration.warmupIterations {
            _ = try await operation()
        }

        // Track memory if enabled
        let memoryBefore = configuration.trackMemory ? MemoryInfo.current() : nil

        // Run actual benchmark
        let timings: [TimeInterval]
        let finalValue: T

        if configuration.concurrentTasks > 1 {
            // Concurrent execution
            (finalValue, timings) = try await runConcurrent(operation)
        } else {
            // Sequential execution
            (finalValue, timings) = try await runSequential(operation)
        }

        // Track memory after
        let memoryAfter = configuration.trackMemory ? MemoryInfo.current() : nil
        let memoryInfo = MemoryInfo.delta(from: memoryBefore, to: memoryAfter)

        // Calculate statistics
        let statistics = timings.count > 1 ? Statistics(timings: timings) : nil

        // Create result
        let timing = Timing(
            total: timings.reduce(0, +),
            average: timings.reduce(0, +) / Double(timings.count),
            min: timings.min() ?? 0,
            max: timings.max() ?? 0
        )

        let result = Result(
            value: finalValue,
            timing: timing,
            statistics: statistics,
            memory: memoryInfo,
            metadata: Metadata(
                name: configuration.name,
                iterations: configuration.iterations,
                warmupIterations: configuration.warmupIterations,
                concurrentTasks: configuration.concurrentTasks
            )
        )

        // Output results
        if !configuration.quiet {
            print(Formatter.format(result, as: configuration.outputFormat))
        }

        return result
    }

    // MARK: - Private Methods

    private func runSequential<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> (T, [TimeInterval]) {
        var timings: [TimeInterval] = []
        timings.reserveCapacity(configuration.iterations)

        var lastValue: T?

        for _ in 0..<configuration.iterations {
            let (value, duration) = try await time(operation)
            lastValue = value
            timings.append(duration)
        }

        guard let finalValue = lastValue else {
            throw BenchmarkError.noIterationsExecuted
        }
        return (finalValue, timings)
    }

    private func runConcurrent<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> (T, [TimeInterval]) {
        let iterationsPerTask = configuration.iterations / configuration.concurrentTasks
        let remainder = configuration.iterations % configuration.concurrentTasks

        return try await withThrowingTaskGroup(of: (T, [TimeInterval]).self) { group in
            for taskIndex in 0..<configuration.concurrentTasks {
                let taskIterations = iterationsPerTask + (taskIndex < remainder ? 1 : 0)

                group.addTask {
                    var timings: [TimeInterval] = []
                    timings.reserveCapacity(taskIterations)
                    var lastValue: T?

                    for _ in 0..<taskIterations {
                        let (value, duration) = try await time(operation)
                        lastValue = value
                        timings.append(duration)
                    }

                    guard let finalValue = lastValue else {
                        throw BenchmarkError.noIterationsExecuted
                    }
                    return (finalValue, timings)
                }
            }

            var allTimings: [TimeInterval] = []
            var finalValue: T?

            for try await (value, timings) in group {
                finalValue = value
                allTimings.append(contentsOf: timings)
            }

            guard let result = finalValue else {
                throw BenchmarkError.noIterationsExecuted
            }
            return (result, allTimings)
        }
    }
}

// MARK: - Convenience Extensions

public extension Benchmark {
    /// Run a simple benchmark without configuration.
    static func run<T: Sendable>(
        _ name: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let result = try await measure(name, operation)
        return result.value
    }

    /// Run a benchmark with automatic pretty printing.
    static func profile<T: Sendable>(
        _ name: String,
        iterations: Int = 1,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let result = try await measure(name, iterations: iterations, operation)
        return result.value
    }
}
