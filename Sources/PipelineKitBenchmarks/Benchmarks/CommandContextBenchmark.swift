import Foundation
import PipelineKit

/// Benchmark for CommandContext access patterns.
struct CommandContextAccessBenchmark: Benchmark {
    let name = "CommandContext Access"
    let iterations = 10_000
    let warmupIterations = 1_000
    
    // Test keys
    private struct Key1: ContextKey { typealias Value = String }
    private struct Key2: ContextKey { typealias Value = Int }
    private struct Key3: ContextKey { typealias Value = Double }
    private struct Key4: ContextKey { typealias Value = Bool }
    private struct Key5: ContextKey { typealias Value = [String] }
    
    func run() async throws {
        let context = CommandContext()
        
        // Mixed read/write operations
        for i in 0..<100 {
            context.set("value-\(i)", for: Key1.self)
            context.set(i, for: Key2.self)
            context.set(Double(i) * 1.5, for: Key3.self)
            context.set(i % 2 == 0, for: Key4.self)
            context.set(["item-\(i)"], for: Key5.self)
            
            _ = context.get(Key1.self)
            _ = context.get(Key2.self)
            _ = context.get(Key3.self)
            _ = context.get(Key4.self)
            _ = context.get(Key5.self)
        }
    }
}

/// Benchmark for concurrent CommandContext access.
struct CommandContextConcurrentBenchmark: Benchmark {
    let name = "CommandContext Concurrent Access"
    let iterations = 1_000
    let warmupIterations = 100
    
    private struct TestKey: ContextKey { typealias Value = Int }
    
    func run() async throws {
        let context = CommandContext()
        
        // Concurrent reads and writes
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    for j in 0..<10 {
                        context.set(i * 10 + j, for: TestKey.self)
                        _ = context.get(TestKey.self)
                    }
                }
            }
        }
    }
}

/// Benchmark for CommandContext with pooling.
struct CommandContextPoolBenchmark: ParameterizedBenchmark {
    let name = "CommandContext Pool Efficiency"
    let iterations = 5_000
    let warmupIterations = 500
    
    typealias Input = CommandMetadata
    
    func makeInput() async throws -> CommandMetadata {
        // Create standard metadata for benchmarking
        return StandardCommandMetadata(
            userId: "benchmark-user",
            correlationId: "bench-\(UUID().uuidString)"
        )
    }
    
    func run(input: CommandMetadata) async throws {
        // Test pool borrow/return cycle
        let pooled = CommandContextPool.shared.borrow(metadata: input)
        
        // Simulate some work
        for i in 0..<10 {
            pooled.value.set(i, for: IntKey.self)
        }
        
        // Return happens automatically on deallocation
    }
    
    private struct IntKey: ContextKey { typealias Value = Int }
}

/// Benchmark suite for CommandContext.
public struct CommandContextBenchmarkSuite {
    public static func all() -> [any Benchmark] {
        [
            CommandContextAccessBenchmark(),
            CommandContextConcurrentBenchmark(),
            CommandContextPoolBenchmark()
        ]
    }
}
