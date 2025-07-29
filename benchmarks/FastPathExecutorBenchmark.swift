#!/usr/bin/env swift

import Foundation
@testable import PipelineKit

// MARK: - Test Infrastructure

struct BenchmarkCommand: Command {
    typealias Result = String
    let id: String
    let payload: String
    
    init(id: String = UUID().uuidString, payload: String = "test") {
        self.id = id
        self.payload = payload
    }
}

struct BenchmarkHandler: CommandHandler {
    typealias CommandType = BenchmarkCommand
    
    func handle(_ command: BenchmarkCommand) async throws -> String {
        // Simulate minimal work
        return "\(command.id):\(command.payload)"
    }
}

// MARK: - Test Middleware

struct LightweightMiddleware: Middleware {
    let name: String
    let priority: ExecutionPriority = .custom
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Minimal work - just pass through
        context.set(name, for: StringKey.self)
        return try await next(command, context)
    }
}

struct ProcessingMiddleware: Middleware {
    let name: String
    let priority: ExecutionPriority = .processing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate some processing
        context.set("\(name)-processed", for: StringKey.self)
        let result = try await next(command, context)
        context.set("\(name)-complete", for: ProcessedKey.self)
        return result
    }
}

// Context Keys
private struct StringKey: ContextKey {
    typealias Value = String
}

private struct ProcessedKey: ContextKey {
    typealias Value = String
}

// MARK: - Benchmark Runner

struct BenchmarkResult {
    let name: String
    let iterations: Int
    let totalTime: TimeInterval
    let averageTime: TimeInterval
    let minTime: TimeInterval
    let maxTime: TimeInterval
    
    var formattedReport: String {
        """
        \(name):
          Iterations: \(iterations)
          Total: \(String(format: "%.3f", totalTime))s
          Average: \(String(format: "%.6f", averageTime))s
          Min: \(String(format: "%.6f", minTime))s
          Max: \(String(format: "%.6f", maxTime))s
        """
    }
}

class FastPathBenchmark {
    private let iterations: Int
    private let warmupIterations: Int
    
    init(iterations: Int = 10000, warmupIterations: Int = 1000) {
        self.iterations = iterations
        self.warmupIterations = warmupIterations
    }
    
    func runBenchmark(
        name: String,
        operation: () async throws -> Void
    ) async throws -> BenchmarkResult {
        // Warmup
        for _ in 0..<warmupIterations {
            try await operation()
        }
        
        // Actual measurements
        var times: [TimeInterval] = []
        let startTotal = CFAbsoluteTimeGetCurrent()
        
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            try await operation()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            times.append(elapsed)
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTotal
        
        return BenchmarkResult(
            name: name,
            iterations: iterations,
            totalTime: totalTime,
            averageTime: times.reduce(0, +) / Double(iterations),
            minTime: times.min() ?? 0,
            maxTime: times.max() ?? 0
        )
    }
}

// MARK: - Benchmarks

func benchmarkDirectExecution() async throws {
    print("\n=== Direct FastPath Execution (0 middleware) ===")
    
    let benchmark = FastPathBenchmark()
    let handler = BenchmarkHandler()
    let optimizer = MiddlewareChainOptimizer()
    
    // Setup optimized pipeline
    let optimizedChain = await optimizer.optimize(
        middleware: [],
        handler: handler
    )
    
    let standardPipeline = StandardPipeline(handler: handler)
    let optimizedPipeline = StandardPipeline(handler: handler)
    await optimizedPipeline.setOptimization(optimizedChain)
    
    // Benchmark standard execution
    let standardResult = try await benchmark.runBenchmark(name: "Standard Execution") {
        let command = BenchmarkCommand()
        let context = CommandContext()
        _ = try await standardPipeline.execute(command, context: context)
    }
    
    // Benchmark fast path execution
    let fastPathResult = try await benchmark.runBenchmark(name: "FastPath Execution") {
        let command = BenchmarkCommand()
        let context = CommandContext()
        _ = try await optimizedPipeline.execute(command, context: context)
    }
    
    print(standardResult.formattedReport)
    print(fastPathResult.formattedReport)
    
    let improvement = ((standardResult.averageTime - fastPathResult.averageTime) / standardResult.averageTime) * 100
    print("Improvement: \(String(format: "%.1f", improvement))%")
}

func benchmarkSingleMiddleware() async throws {
    print("\n=== Single Middleware FastPath ===")
    
    let benchmark = FastPathBenchmark()
    let handler = BenchmarkHandler()
    let optimizer = MiddlewareChainOptimizer()
    let middleware = [LightweightMiddleware(name: "MW1")]
    
    // Setup pipelines
    let standardPipeline = StandardPipeline(handler: handler)
    for mw in middleware {
        try await standardPipeline.addMiddleware(mw)
    }
    
    let optimizedChain = await optimizer.optimize(
        middleware: middleware,
        handler: handler
    )
    
    let optimizedPipeline = StandardPipeline(handler: handler)
    await optimizedPipeline.setOptimization(optimizedChain)
    for mw in middleware {
        try await optimizedPipeline.addMiddleware(mw)
    }
    
    // Benchmark
    let standardResult = try await benchmark.runBenchmark(name: "Standard Single MW") {
        let command = BenchmarkCommand()
        let context = CommandContext()
        _ = try await standardPipeline.execute(command, context: context)
    }
    
    let fastPathResult = try await benchmark.runBenchmark(name: "FastPath Single MW") {
        let command = BenchmarkCommand()
        let context = CommandContext()
        _ = try await optimizedPipeline.execute(command, context: context)
    }
    
    print(standardResult.formattedReport)
    print(fastPathResult.formattedReport)
    
    let improvement = ((standardResult.averageTime - fastPathResult.averageTime) / standardResult.averageTime) * 100
    print("Improvement: \(String(format: "%.1f", improvement))%")
}

func benchmarkTripleMiddleware() async throws {
    print("\n=== Triple Middleware FastPath ===")
    
    let benchmark = FastPathBenchmark()
    let handler = BenchmarkHandler()
    let optimizer = MiddlewareChainOptimizer()
    let middleware = [
        LightweightMiddleware(name: "MW1"),
        ProcessingMiddleware(name: "MW2"),
        LightweightMiddleware(name: "MW3")
    ]
    
    // Setup pipelines
    let standardPipeline = StandardPipeline(handler: handler)
    for mw in middleware {
        try await standardPipeline.addMiddleware(mw)
    }
    
    let optimizedChain = await optimizer.optimize(
        middleware: middleware,
        handler: handler
    )
    
    let optimizedPipeline = StandardPipeline(handler: handler)
    await optimizedPipeline.setOptimization(optimizedChain)
    for mw in middleware {
        try await optimizedPipeline.addMiddleware(mw)
    }
    
    // Benchmark
    let standardResult = try await benchmark.runBenchmark(name: "Standard Triple MW") {
        let command = BenchmarkCommand()
        let context = CommandContext()
        _ = try await standardPipeline.execute(command, context: context)
    }
    
    let fastPathResult = try await benchmark.runBenchmark(name: "FastPath Triple MW") {
        let command = BenchmarkCommand()
        let context = CommandContext()
        _ = try await optimizedPipeline.execute(command, context: context)
    }
    
    print(standardResult.formattedReport)
    print(fastPathResult.formattedReport)
    
    let improvement = ((standardResult.averageTime - fastPathResult.averageTime) / standardResult.averageTime) * 100
    print("Improvement: \(String(format: "%.1f", improvement))%")
}

func benchmarkTypeErasureOverhead() async throws {
    print("\n=== Type Erasure Overhead Analysis ===")
    
    let benchmark = FastPathBenchmark(iterations: 100000, warmupIterations: 10000)
    
    // Direct execution without type erasure
    let directResult = try await benchmark.runBenchmark(name: "Direct Type") {
        let command = BenchmarkCommand()
        let handler = BenchmarkHandler()
        _ = try await handler.handle(command)
    }
    
    // With type erasure (simulating FastPathExecutor approach)
    let typeErasedResult = try await benchmark.runBenchmark(name: "Type Erased") {
        struct TypeErasedCommand: Command {
            typealias Result = Any
            let wrapped: Any
        }
        
        let command = BenchmarkCommand()
        let wrapped = TypeErasedCommand(wrapped: command)
        let handler = BenchmarkHandler()
        
        // Simulate the type erasure overhead
        guard let unwrapped = wrapped.wrapped as? BenchmarkCommand else {
            fatalError("Type mismatch")
        }
        let result = try await handler.handle(unwrapped)
        _ = result as Any
    }
    
    print(directResult.formattedReport)
    print(typeErasedResult.formattedReport)
    
    let overhead = ((typeErasedResult.averageTime - directResult.averageTime) / directResult.averageTime) * 100
    print("Type Erasure Overhead: \(String(format: "%.1f", overhead))%")
}

// MARK: - Main

@main
struct FastPathBenchmarkRunner {
    static func main() async throws {
        print("FastPathExecutor Performance Benchmark")
        print("=====================================")
        
        try await benchmarkDirectExecution()
        try await benchmarkSingleMiddleware()
        try await benchmarkTripleMiddleware()
        try await benchmarkTypeErasureOverhead()
        
        print("\n✅ Benchmark Complete")
    }
}