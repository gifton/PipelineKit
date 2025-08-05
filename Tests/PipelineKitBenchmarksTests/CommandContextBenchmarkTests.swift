import XCTest
@testable import PipelineKit

/// Comprehensive benchmarks to measure CommandContext performance
final class CommandContextBenchmarkTests: XCTestCase {
    // MARK: - Test Infrastructure
    
    private struct StringKey: ContextKey {
        typealias Value = String
    }
    
    private struct IntKey: ContextKey {
        typealias Value = Int
    }
    
    private struct DataKey: ContextKey {
        typealias Value = Data
    }
    
    private struct ComplexKey: ContextKey {
        typealias Value = ComplexValue
    }
    
    private struct ComplexValue: Sendable {
        let id: String
        let timestamp: Date
        let values: [Int]
        let metadata: [String: String]
    }
    
    // MARK: - Current Implementation Benchmarks
    
    func testCurrentImplementationSingleThreaded() async throws {
        let iterations = 100_000
        let context = CommandContext()
        
        // Warm up
        for i in 0..<1000 {
            context.set("value-\(i)", for: StringKey.self)
            _ = context.get(StringKey.self)
        }
        
        // Benchmark set operations
        let setStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            context.set("value-\(i)", for: StringKey.self)
        }
        let setDuration = CFAbsoluteTimeGetCurrent() - setStart
        
        // Benchmark get operations
        let getStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = context.get(StringKey.self)
        }
        let getDuration = CFAbsoluteTimeGetCurrent() - getStart
        
        // Benchmark mixed operations
        let mixedStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            context.set(i, for: IntKey.self)
            _ = context.get(StringKey.self)
            _ = context.get(IntKey.self)
        }
        let mixedDuration = CFAbsoluteTimeGetCurrent() - mixedStart
        
        print("\n=== Current Implementation (NSLock) - Single Threaded ===")
        print("Set operations: \(String(format: "%.3f", setDuration))s (\(String(format: "%.1f", Double(iterations) / setDuration / 1000))K ops/sec)")
        print("Get operations: \(String(format: "%.3f", getDuration))s (\(String(format: "%.1f", Double(iterations) / getDuration / 1000))K ops/sec)")
        print("Mixed operations: \(String(format: "%.3f", mixedDuration))s (\(String(format: "%.1f", Double(iterations * 3) / mixedDuration / 1000))K ops/sec)")
        print("Average per-operation time:")
        print("  Set: \(String(format: "%.1f", setDuration / Double(iterations) * 1_000_000))ns")
        print("  Get: \(String(format: "%.1f", getDuration / Double(iterations) * 1_000_000))ns")
    }
    
    func testCurrentImplementationConcurrent() async throws {
        let iterations = 10_000
        let concurrentTasks = 100
        let context = CommandContext()
        
        // Benchmark concurrent reads
        let readStart = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<concurrentTasks {
                group.addTask {
                    for i in 0..<iterations {
                        _ = context.get(StringKey.self)
                        _ = context.get(IntKey.self)
                    }
                }
            }
        }
        let readDuration = CFAbsoluteTimeGetCurrent() - readStart
        
        // Benchmark concurrent writes
        let writeStart = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<concurrentTasks {
                group.addTask {
                    for i in 0..<iterations {
                        context.set("task-\(taskId)-\(i)", for: StringKey.self)
                    }
                }
            }
        }
        let writeDuration = CFAbsoluteTimeGetCurrent() - writeStart
        
        // Benchmark concurrent mixed operations
        let mixedStart = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<concurrentTasks {
                group.addTask {
                    for i in 0..<iterations {
                        if i.isMultiple(of: 2) {
                            context.set("task-\(taskId)-\(i)", for: StringKey.self)
                        } else {
                            _ = context.get(StringKey.self)
                        }
                    }
                }
            }
        }
        let mixedDuration = CFAbsoluteTimeGetCurrent() - mixedStart
        
        let totalOps = iterations * concurrentTasks
        print("\n=== Current Implementation (NSLock) - Concurrent ===")
        print("Concurrent tasks: \(concurrentTasks)")
        print("Concurrent reads: \(String(format: "%.3f", readDuration))s (\(String(format: "%.1f", Double(totalOps * 2) / readDuration / 1000))K ops/sec)")
        print("Concurrent writes: \(String(format: "%.3f", writeDuration))s (\(String(format: "%.1f", Double(totalOps) / writeDuration / 1000))K ops/sec)")
        print("Concurrent mixed: \(String(format: "%.3f", mixedDuration))s (\(String(format: "%.1f", Double(totalOps) / mixedDuration / 1000))K ops/sec)")
    }
    
    func testCurrentImplementationContention() async throws {
        let iterations = 10_000
        let contexts = 10
        let tasksPerContext = 10
        
        // Create multiple contexts to simulate real-world usage
        let contextArray = (0..<contexts).map { _ in CommandContext() }
        
        let start = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { group in
            for (contextIndex, context) in contextArray.enumerated() {
                for taskId in 0..<tasksPerContext {
                    group.addTask {
                        for i in 0..<iterations {
                            // Simulate realistic access patterns
                            context.set("value-\(taskId)-\(i)", for: StringKey.self)
                            context.set(i, for: IntKey.self)
                            _ = context.get(StringKey.self)
                            _ = context.get(IntKey.self)
                            
                            // Occasionally access other contexts (cross-context contention)
                            if i.isMultiple(of: 100) {
                                let otherContext = contextArray[(contextIndex + 1) % contexts]
                                _ = otherContext.get(StringKey.self)
                            }
                        }
                    }
                }
            }
        }
        let duration = CFAbsoluteTimeGetCurrent() - start
        
        let totalOps = iterations * contexts * tasksPerContext * 4 // 4 ops per iteration
        print("\n=== Current Implementation (NSLock) - Contention Test ===")
        print("Contexts: \(contexts), Tasks per context: \(tasksPerContext)")
        print("Duration: \(String(format: "%.3f", duration))s")
        print("Total operations: \(String(format: "%.1f", Double(totalOps) / 1000))K")
        print("Throughput: \(String(format: "%.1f", Double(totalOps) / duration / 1000))K ops/sec")
    }
    
    func testCurrentImplementationMemoryPressure() async throws {
        let iterations = 50_000
        let context = CommandContext()
        
        // Generate large values to test memory pressure
        let largeData = Data(repeating: 0, count: 1024) // 1KB per entry
        
        let start = CFAbsoluteTimeGetCurrent()
        
        // Fill context with many keys
        for i in 0..<iterations {
            autoreleasepool {
                context.set(largeData, for: DataKey.self)
                context.set("string-\(i)", for: StringKey.self)
                context.set(i, for: IntKey.self)
                
                // Simulate churn by removing some values
                if i.isMultiple(of: 10) {
                    context.set(nil, for: DataKey.self)
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        
        print("\n=== Current Implementation (NSLock) - Memory Pressure ===")
        print("Operations: \(iterations)")
        print("Duration: \(String(format: "%.3f", duration))s")
        print("Throughput: \(String(format: "%.1f", Double(iterations * 3) / duration / 1000))K ops/sec")
    }
    
    func testCurrentImplementationComplexTypes() async throws {
        let iterations = 10_000
        let context = CommandContext()
        
        // Create complex values
        let complexValue = ComplexValue(
            id: UUID().uuidString,
            timestamp: Date(),
            values: Array(1...100),
            metadata: ["key1": "value1", "key2": "value2", "key3": "value3"]
        )
        
        // Benchmark complex type operations
        let start = CFAbsoluteTimeGetCurrent()
        
        for i in 0..<iterations {
            let value = ComplexValue(
                id: "id-\(i)",
                timestamp: Date(),
                values: [i, i + 1, i + 2],
                metadata: ["iteration": "\(i)"]
            )
            context.set(value, for: ComplexKey.self)
            _ = context.get(ComplexKey.self)
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        
        print("\n=== Current Implementation (NSLock) - Complex Types ===")
        print("Operations: \(iterations * 2)")
        print("Duration: \(String(format: "%.3f", duration))s")
        print("Throughput: \(String(format: "%.1f", Double(iterations * 2) / duration / 1000))K ops/sec")
        print("Average per-operation: \(String(format: "%.1f", duration / Double(iterations * 2) * 1_000_000))ns")
    }
    
    // MARK: - Helper Methods
    
    private func measureTime(iterations: Int = 1000, _ block: () async throws -> Void) async rethrows -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            try await block()
        }
        return CFAbsoluteTimeGetCurrent() - start
    }
    
    private func printComparison(name: String, oldTime: TimeInterval, newTime: TimeInterval) {
        let improvement = ((oldTime - newTime) / oldTime) * 100
        let speedup = oldTime / newTime
        
        print("\n\(name) Comparison:")
        print("  Old (NSLock): \(String(format: "%.3f", oldTime))s")
        print("  New (Actor): \(String(format: "%.3f", newTime))s")
        print("  Improvement: \(String(format: "%.1f", improvement))%")
        print("  Speedup: \(String(format: "%.2f", speedup))x")
    }
}
