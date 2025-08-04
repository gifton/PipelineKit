import Foundation
import PipelineKit

// MARK: - BackPressure Benchmarks

struct BackPressureUncontendedBenchmark {
    let name = "BackPressure-Uncontended"
    let description = "Tests uncontended fast path performance"
    
    func run() async throws {
        let runner = SimpleBenchmarkRunner()
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 1000)
        let iterations = 100_000
        
        _ = try await runner.measure(name: "Uncontended acquire/release", iterations: iterations) {
            for _ in 0..<iterations {
                let token = try await semaphore.acquire()
                token.release()
            }
        }
    }
}

struct BackPressureTryAcquireBenchmark {
    let name = "BackPressure-TryAcquire"
    let description = "Tests tryAcquire performance"
    
    func run() async throws {
        let runner = SimpleBenchmarkRunner()
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 100)
        let iterations = 100_000
        var successCount = 0
        
        _ = try await runner.measure(name: "tryAcquire operations", iterations: iterations) {
            for _ in 0..<iterations {
                if let token = semaphore.tryAcquire() {
                    successCount += 1
                    token.release()
                }
            }
        }
        
        print("  Success rate: \(String(format: "%.1f%%", Double(successCount) / Double(iterations) * 100))")
    }
}

struct BackPressureContentionBenchmark {
    let name = "BackPressure-Contention"
    let description = "Tests performance under contention"
    
    func run() async throws {
        let runner = SimpleBenchmarkRunner()
        
        // Mild contention - reduced iterations
        print("\n--- Mild Contention (50% suspension rate) ---")
        let semaphore1 = BackPressureAsyncSemaphore(maxConcurrency: 10)
        let tasks1 = 20
        let opsPerTask1 = 50
        let totalOps1 = tasks1 * opsPerTask1
        
        _ = try await runner.measure(name: "Mild contention", iterations: totalOps1) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<tasks1 {
                    group.addTask {
                        for _ in 0..<opsPerTask1 {
                            if let token = semaphore1.tryAcquire() {
                                // Got it immediately
                                token.release()
                            } else {
                                // Try async acquire with timeout
                                do {
                                    if let token = try await semaphore1.acquire(timeout: 0.01) {
                                        token.release()
                                    }
                                } catch {
                                    // Timeout or error - skip
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Heavy contention - reduced iterations and added timeout
        print("\n--- Heavy Contention (95% suspension rate) ---")
        let semaphore2 = BackPressureAsyncSemaphore(maxConcurrency: 2)
        let tasks2 = 10
        let opsPerTask2 = 20
        let totalOps2 = tasks2 * opsPerTask2
        
        _ = try await runner.measure(name: "Heavy contention", iterations: totalOps2) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<tasks2 {
                    group.addTask {
                        for _ in 0..<opsPerTask2 {
                            do {
                                if let token = try await semaphore2.acquire(timeout: 0.05) {
                                    await Task.yield()
                                    token.release()
                                }
                            } catch {
                                // Timeout or error - skip
                            }
                        }
                    }
                }
            }
        }
    }
}

struct BackPressureCancellationBenchmark {
    let name = "BackPressure-Cancellation"
    let description = "Tests cancellation performance"
    
    func run() async throws {
        let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 1)
        let blocker = try await semaphore.acquire()
        
        let numWaiters = 1000
        let waitingTasks = (0..<numWaiters).map { _ in
            Task {
                try await semaphore.acquire()
            }
        }
        
        // Let them queue up
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        // Measure cancellation
        let cancelStart = CFAbsoluteTimeGetCurrent()
        for task in waitingTasks {
            task.cancel()
        }
        
        // Wait for cancellations
        for task in waitingTasks {
            _ = try? await task.value
        }
        let cancelDuration = CFAbsoluteTimeGetCurrent() - cancelStart
        
        print("  Waiters cancelled: \(numWaiters)")
        print("  Cancellation duration: \(String(format: "%.3f", cancelDuration))s")
        print("  Rate: \(String(format: "%.0f", Double(numWaiters) / cancelDuration)) cancellations/sec")
        print("  Avg per cancellation: \(String(format: "%.1f", (cancelDuration / Double(numWaiters)) * 1_000_000))μs")
        
        blocker.release()
        
        // Verify cleanup
        let stats = await semaphore.getStats()
        print("  Post-cleanup queue size: \(stats.queuedOperations)")
    }
}

struct BackPressureMemoryBenchmark {
    let name = "BackPressure-Memory"
    let description = "Tests memory pressure handling"
    
    func run() async throws {
        let runner = SimpleBenchmarkRunner()
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 100,
            maxQueueMemory: 1_048_576 // 1MB
        )
        
        var memoryHits = 0
        var successes = 0
        let attempts = 500
        
        _ = try await runner.measure(name: "Memory pressure handling", iterations: attempts) {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<attempts {
                    group.addTask {
                        do {
                            let size = (i % 10 + 1) * 10_240 // 10KB to 100KB
                            let token = try await semaphore.acquire(estimatedSize: size)
                            await Task.yield()
                            token.release()
                            successes += 1
                        } catch PipelineError.backPressure(reason: .memoryPressure) {
                            memoryHits += 1
                        } catch {
                            // Other errors
                        }
                    }
                }
            }
        }
        
        print("  Successful acquisitions: \(successes)")
        print("  Memory limit hits: \(memoryHits)")
    }
}

// MARK: - CommandContext Benchmarks

struct CommandContextBenchmark {
    let name = "CommandContext"
    let description = "Tests CommandContext performance"
    
    func run() async throws {
        let runner = SimpleBenchmarkRunner()
        
        // Test 1: Context creation
        _ = try await runner.measure(name: "Context creation", iterations: 10_000) {
            for _ in 0..<10_000 {
                _ = CommandContext()
            }
        }
        
        // Test 2: Value storage and retrieval
        let context = CommandContext()
        struct TestKey: ContextKey {
            typealias Value = String
        }
        
        _ = try await runner.measure(name: "Value storage/retrieval", iterations: 10_000) {
            for i in 0..<10_000 {
                context[TestKey.self] = "value-\(i)"
                _ = context[TestKey.self]
            }
        }
        
        // Test 3: Context forking
        _ = try await runner.measure(name: "Context forking", iterations: 1_000) {
            for _ in 0..<1_000 {
                let forked = context.fork()
                forked[TestKey.self] = "forked-value"
            }
        }
    }
}

// MARK: - Pipeline Benchmarks

struct PipelineBenchmark {
    let name = "Pipeline"
    let description = "Tests pipeline execution performance"
    
    struct SimpleCommand: Command {
        typealias Result = Int
        let value: Int
    }
    
    struct PassthroughMiddleware: Middleware {
        func execute<T>(_ command: T, context: PipelineKitCore.CommandContext, next: @Sendable (T, PipelineKitCore.CommandContext) async throws -> T.Result) async throws -> T.Result where T : PipelineKitCore.Command {
            return try await next(command, context)
        }
    }
    
    struct SimpleHandler: CommandHandler {
        typealias CommandType = SimpleCommand
        
        func handle(_ command: SimpleCommand) async throws -> Int {
            return command.value
        }
    }
    
    func run() async throws {
        let runner = SimpleBenchmarkRunner()
        
        // Test 1: CommandBus without middleware
        let bus1 = CommandBus()
        try await bus1.register(SimpleCommand.self, handler: SimpleHandler())
        
        _ = try await runner.measure(name: "CommandBus without middleware", iterations: 10_000) {
            for i in 0..<10_000 {
                _ = try await bus1.send(SimpleCommand(value: i), context: CommandContext())
            }
        }
        
        // Test 2: CommandBus with middleware
        let bus2 = CommandBus()
        try await bus2.register(SimpleCommand.self, handler: SimpleHandler())
        
        // For now, we'll skip middleware test since CommandBus doesn't have a direct middleware API
        // We would need to use a Pipeline wrapper or similar
        print("\nNote: CommandBus middleware test skipped (not directly supported)")
    }
}

// MARK: - Simple Benchmark Runner

class SimpleBenchmarkRunner {
    func measure(name: String, iterations: Int = 1, _ block: () async throws -> Void) async throws -> (duration: TimeInterval, throughput: Double) {
        let start = CFAbsoluteTimeGetCurrent()
        try await block()
        let duration = CFAbsoluteTimeGetCurrent() - start
        let throughput = Double(iterations) / duration
        
        // Print immediate results
        print("  Duration: \(String(format: "%.3f", duration))s")
        print("  Operations: \(iterations)")
        print("  Throughput: \(String(format: "%.0f", throughput)) ops/sec")
        
        if iterations > 1 {
            let avgLatency = duration / Double(iterations)
            if avgLatency < 0.000001 {
                print("  Avg latency: \(String(format: "%.1f", avgLatency * 1_000_000_000))ns")
            } else if avgLatency < 0.001 {
                print("  Avg latency: \(String(format: "%.1f", avgLatency * 1_000_000))μs")
            } else {
                print("  Avg latency: \(String(format: "%.3f", avgLatency * 1000))ms")
            }
        }
        
        return (duration, throughput)
    }
}

// MARK: - Main

// Simple benchmark type
protocol SimpleBenchmark {
    var name: String { get }
    var description: String { get }
    func run() async throws
}

// Make our benchmarks conform
extension BackPressureUncontendedBenchmark: SimpleBenchmark {}
extension BackPressureTryAcquireBenchmark: SimpleBenchmark {}
extension BackPressureContentionBenchmark: SimpleBenchmark {}
extension BackPressureCancellationBenchmark: SimpleBenchmark {}
extension BackPressureMemoryBenchmark: SimpleBenchmark {}
extension CommandContextBenchmark: SimpleBenchmark {}
extension PipelineBenchmark: SimpleBenchmark {}

@main
struct BenchmarkMain {
    static func main() async throws {
        let arguments = CommandLine.arguments
        var quick = false
        var filter: String?
        var benchmark: String?
        
        // Parse arguments
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--quick", "-q":
                quick = true
            case "--filter", "-f":
                i += 1
                if i < arguments.count {
                    filter = arguments[i]
                }
            case "--benchmark", "-b":
                i += 1
                if i < arguments.count {
                    benchmark = arguments[i]
                }
            case "--help", "-h":
                printHelp()
                exit(0)
            default:
                if !arguments[i].starts(with: "-") {
                    benchmark = arguments[i]
                }
            }
            i += 1
        }
        
        // Create benchmarks
        let benchmarks: [SimpleBenchmark] = [
            BackPressureUncontendedBenchmark(),
            BackPressureTryAcquireBenchmark(),
            BackPressureContentionBenchmark(),
            BackPressureCancellationBenchmark(),
            BackPressureMemoryBenchmark(),
            CommandContextBenchmark(),
            PipelineBenchmark()
        ]
        
        // Filter benchmarks
        let benchmarksToRun = filter.map { pattern in
            benchmarks.filter { $0.name.contains(pattern) }
        } ?? benchmark.map { pattern in
            benchmarks.filter { $0.name.contains(pattern) }
        } ?? benchmarks
        
        // Run benchmarks
        print("=== PipelineKit Benchmark Suite ===")
        print("Date: \(Date())")
        print("Mode: \(quick ? "Quick" : "Full")")
        print(String(repeating: "=", count: 60))
        print("")
        
        for benchmark in benchmarksToRun {
            print("Running: \(benchmark.name)")
            print("Description: \(benchmark.description)")
            print(String(repeating: "-", count: 40))
            
            do {
                try await benchmark.run()
                print("")
            } catch {
                print("Error: \(error)")
                print("")
            }
        }
        
        print(String(repeating: "=", count: 60))
        print("Benchmark suite completed")
        
        exit(0)
    }
    
    static func printHelp() {
        print("""
        PipelineKit Benchmark Suite
        
        Usage: PipelineKitBenchmarks [options] [benchmark]
        
        Options:
          --quick, -q              Run in quick mode (fewer iterations)
          --filter, -f <pattern>   Filter benchmarks by name pattern
          --benchmark, -b <name>   Run specific benchmark
          --help, -h               Show this help message
        
        Available benchmarks:
          BackPressure-Uncontended   Tests uncontended fast path performance
          BackPressure-TryAcquire    Tests tryAcquire performance
          BackPressure-Contention    Tests performance under contention
          BackPressure-Cancellation  Tests cancellation performance
          BackPressure-Memory        Tests memory pressure handling
          CommandContext             Tests CommandContext performance
          Pipeline                   Tests pipeline execution performance
        
        Examples:
          PipelineKitBenchmarks --quick
          PipelineKitBenchmarks BackPressure
          PipelineKitBenchmarks --filter Context
        """)
    }
}