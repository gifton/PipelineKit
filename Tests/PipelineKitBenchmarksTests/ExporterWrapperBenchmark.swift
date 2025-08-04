import XCTest
import PipelineKitCore
@testable import PipelineKitMiddleware

/// Benchmark for ExporterWrapper performance before and after actor refactoring
final class ExporterWrapperBenchmarkTests: XCTestCase {
    
    /// Mock exporter for benchmarking
    final class MockExporter: MetricExporter, @unchecked Sendable {
        var exportedMetrics: [MetricDataPoint] = []
        var batchExportCount = 0
        var flushCount = 0
        var isShutdown = false
        
        func export(_ metric: MetricDataPoint) async throws {
            // Simulate minimal work
            exportedMetrics.append(metric)
        }
        
        func exportBatch(_ metrics: [MetricDataPoint]) async throws {
            batchExportCount += 1
            // Simulate batch processing delay
            try await Task.sleep(nanoseconds: 1_000) // 1 microsecond
        }
        
        func exportAggregated(_ metrics: [AggregatedMetrics]) async throws {
            // Not used in benchmark
        }
        
        func flush() async throws {
            flushCount += 1
        }
        
        func shutdown() async {
            isShutdown = true
        }
        
        var status: ExporterStatus {
            ExporterStatus(
                isActive: !isShutdown,
                queueDepth: exportedMetrics.count,
                successCount: exportedMetrics.count,
                failureCount: 0,
                lastExportTime: Date(),
                lastError: nil
            )
        }
    }
    
    /// Benchmark concurrent enqueue operations
    func testConcurrentEnqueuePerformance() async throws {
        let manager = ExportManager()
        let mockExporter = MockExporter()
        await manager.register(mockExporter, name: "benchmark")
        
        let metricCount = 10_000
        let concurrentTasks = 100
        let metricsPerTask = metricCount / concurrentTasks
        
        let startTime = ProcessInfo.processInfo.systemUptime
        
        // Create concurrent tasks to enqueue metrics
        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<concurrentTasks {
                group.addTask {
                    for i in 0..<metricsPerTask {
                        let metric = MetricDataPoint(
                            timestamp: Date(),
                            name: "test.metric.\(taskIndex).\(i)",
                            value: Double(i),
                            type: .gauge,
                            tags: ["task": "\(taskIndex)"]
                        )
                        await manager.export(metric)
                    }
                }
            }
        }
        
        let endTime = ProcessInfo.processInfo.systemUptime
        let totalTime = endTime - startTime
        
        print("""
        Concurrent Enqueue Benchmark (Current Implementation):
        - Total metrics: \(metricCount)
        - Concurrent tasks: \(concurrentTasks)
        - Total time: \(String(format: "%.4f", totalTime)) seconds
        - Throughput: \(String(format: "%.0f", Double(metricCount) / totalTime)) metrics/second
        - Time per metric: \(String(format: "%.2f", (totalTime / Double(metricCount)) * 1_000_000)) microseconds
        """)
    }
    
    /// Benchmark mixed read/write operations
    func testMixedOperationsPerformance() async throws {
        let manager = ExportManager()
        let mockExporter = MockExporter()
        await manager.register(mockExporter, name: "benchmark")
        
        let operationCount = 5_000
        let startTime = ProcessInfo.processInfo.systemUptime
        
        // Mix of exports and status checks
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<operationCount {
                group.addTask {
                    let metric = MetricDataPoint(
                        timestamp: Date(),
                        name: "test.metric.\(i)",
                        value: Double(i),
                        type: .counter,
                        tags: [:]
                    )
                    await manager.export(metric)
                }
            }
            
            // Readers
            for _ in 0..<operationCount/10 {
                group.addTask {
                    _ = await manager.listExporters()
                }
            }
        }
        
        let endTime = ProcessInfo.processInfo.systemUptime
        let totalTime = endTime - startTime
        
        print("""
        
        Mixed Operations Benchmark (Current Implementation):
        - Write operations: \(operationCount)
        - Read operations: \(operationCount/10)
        - Total time: \(String(format: "%.4f", totalTime)) seconds
        - Operations/second: \(String(format: "%.0f", Double(operationCount + operationCount/10) / totalTime))
        """)
    }
    
    /// Benchmark circuit breaker overhead
    func testCircuitBreakerPerformance() async throws {
        let manager = ExportManager(
            configuration: .init(
                circuitBreakerThreshold: 5,
                circuitBreakerResetTime: 0.1
            )
        )
        
        // Create an exporter that fails
        final class FailingExporter: MetricExporter, @unchecked Sendable {
            var shouldFail = true
            
            func export(_ metric: MetricDataPoint) async throws {
                if shouldFail {
                    throw PipelineError.export(reason: .ioError("Simulated failure"))
                }
            }
            
            func exportBatch(_ metrics: [MetricDataPoint]) async throws {
                if shouldFail {
                    throw PipelineError.export(reason: .ioError("Simulated failure"))
                }
            }
            
            func exportAggregated(_ metrics: [AggregatedMetrics]) async throws {}
            func flush() async throws {}
            func shutdown() async {}
            var status: ExporterStatus {
                ExporterStatus(
                    isActive: true,
                    queueDepth: 0,
                    successCount: 0,
                    failureCount: 0,
                    lastExportTime: nil,
                    lastError: nil
                )
            }
        }
        
        let failingExporter = FailingExporter()
        await manager.register(failingExporter, name: "failing")
        
        let metricCount = 1_000
        let startTime = ProcessInfo.processInfo.systemUptime
        
        // Export metrics (should trigger circuit breaker)
        for i in 0..<metricCount {
            let metric = MetricDataPoint(
                timestamp: Date(),
                name: "test.metric.\(i)",
                value: Double(i),
                type: .gauge,
                tags: [:]
            )
            await manager.export(metric)
        }
        
        let endTime = ProcessInfo.processInfo.systemUptime
        let totalTime = endTime - startTime
        
        print("""
        
        Circuit Breaker Benchmark (Current Implementation):
        - Total metrics: \(metricCount)
        - Total time: \(String(format: "%.4f", totalTime)) seconds
        - Throughput with circuit breaker: \(String(format: "%.0f", Double(metricCount) / totalTime)) metrics/second
        """)
    }
    
    /// Run all benchmarks
    func testRunAllBenchmarks() async throws {
        print("\n=== ExporterWrapper Performance Benchmarks (BEFORE Actor Refactoring) ===\n")
        
        try await testConcurrentEnqueuePerformance()
        try await testMixedOperationsPerformance()
        try await testCircuitBreakerPerformance()
        
        print("\n=== Benchmark Complete ===\n")
    }
}