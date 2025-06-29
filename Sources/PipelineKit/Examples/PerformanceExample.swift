import Foundation

/// Example demonstrating performance monitoring middleware usage.
public struct PerformanceExample {
    
    // MARK: - Example Commands
    
    struct FastCommand: Command {
        typealias Result = String
        let value: String
    }
    
    struct SlowCommand: Command {
        typealias Result = Int
        let processingTime: TimeInterval
    }
    
    struct FailingCommand: Command {
        typealias Result = Void
        let shouldFail: Bool
    }
    
    // MARK: - Custom Collectors
    
    /// In-memory performance collector for demonstration
    actor InMemoryPerformanceCollector: PerformanceCollector {
        private var measurements: [PerformanceMeasurement] = []
        
        func record(_ measurement: PerformanceMeasurement) async {
            measurements.append(measurement)
        }
        
        func getAllMeasurements() -> [PerformanceMeasurement] {
            return measurements
        }
        
        func clearMeasurements() {
            measurements.removeAll()
        }
    }
    
    /// Context-aware performance collector that demonstrates context access
    actor ContextAwarePerformanceCollector: PerformanceCollector {
        private var lastMeasurement: PerformanceMeasurement?
        
        func record(_ measurement: PerformanceMeasurement) async {
            lastMeasurement = measurement
        }
        
        func printAnalysis() async {
            guard let measurement = lastMeasurement else {
                print("No measurements recorded yet.")
                return
            }
            
            print("Latest Performance Analysis:")
            print("- Command: \(measurement.commandName)")
            print("- Execution Time: \(String(format: "%.3f", measurement.executionTime))s")
            print("- Status: \(measurement.isSuccess ? "Success" : "Failed")")
            
            if !measurement.metrics.isEmpty {
                print("- Additional Metrics:")
                for (key, value) in measurement.metrics {
                    print("  • \(key): \(value)")
                }
            }
            
            // Performance assessment
            if measurement.executionTime < 0.01 {
                print("- Assessment: ⚡ Excellent performance")
            } else if measurement.executionTime < 0.1 {
                print("- Assessment: ✅ Good performance")
            } else if measurement.executionTime < 1.0 {
                print("- Assessment: ⚠️ Moderate performance")
            } else {
                print("- Assessment: 🐌 Slow performance - consider optimization")
            }
        }
    }
    
    // MARK: - Example Handlers
    
    struct FastCommandHandler: CommandHandler {
        func handle(_ command: FastCommand) async throws -> String {
            return "Processed: \(command.value)"
        }
    }
    
    struct SlowCommandHandler: CommandHandler {
        func handle(_ command: SlowCommand) async throws -> Int {
            try await Task.sleep(nanoseconds: UInt64(command.processingTime * 1_000_000_000))
            return Int(command.processingTime * 1000)
        }
    }
    
    struct FailingCommandHandler: CommandHandler {
        func handle(_ command: FailingCommand) async throws {
            if command.shouldFail {
                throw NSError(domain: "ExampleError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Command intentionally failed"])
            }
        }
    }
    
    public static func runConsoleLoggingExample() async {
        print("=== Console Performance Logging Example ===")
        
        // Create performance middleware with console collector
        let performanceMiddleware = PerformanceMiddleware(
            collector: ConsolePerformanceCollector(
                formatter: DefaultPerformanceFormatter(includeTimestamp: true, includeMetrics: true),
                logLevel: .info
            ),
            includeDetailedMetrics: true
        )
        
        // Build pipeline with performance middleware using new API
        let pipeline = try! await PipelineBuilder(handler: FastCommandHandler())
            .with(performanceMiddleware)
            .build()
        
        print("\n--- Executing Fast Command ---")
        _ = try! await pipeline.execute(FastCommand(value: "Hello World"), metadata: StandardCommandMetadata())
        
        print("\n--- Executing Slow Command ---") 
        let slowPipeline = try! await PipelineBuilder(handler: SlowCommandHandler())
            .with(performanceMiddleware)
            .build()
        _ = try! await slowPipeline.execute(SlowCommand(processingTime: 0.1), metadata: StandardCommandMetadata())
        
        print("\n--- Executing Failing Command ---")
        let failingPipeline = try! await PipelineBuilder(handler: FailingCommandHandler())
            .with(performanceMiddleware)
            .build()
        do {
            try await failingPipeline.execute(FailingCommand(shouldFail: true), metadata: StandardCommandMetadata())
        } catch {
            print("Expected failure occurred")
        }
        
        print("\n--- Executing Successful Command ---")
        try! await failingPipeline.execute(FailingCommand(shouldFail: false), metadata: StandardCommandMetadata())
    }
    
    public static func runAggregatingCollectorExample() async {
        print("\n=== Aggregating Performance Collector Example ===")
        
        // Create aggregating collector
        let aggregatingCollector = AggregatingPerformanceCollector(maxMeasurementsPerCommand: 100)
        
        let performanceMiddleware = PerformanceMiddleware(
            collector: aggregatingCollector,
            includeDetailedMetrics: false
        )
        
        // Build pipelines for different command types
        let fastPipeline = try! await PipelineBuilder(handler: FastCommandHandler())
            .with(performanceMiddleware)
            .build()
            
        let slowPipeline = try! await PipelineBuilder(handler: SlowCommandHandler())
            .with(performanceMiddleware)
            .build()
            
        let failingPipeline = try! await PipelineBuilder(handler: FailingCommandHandler())
            .with(performanceMiddleware)
            .build()
        
        print("\n--- Running Multiple Commands ---")
        
        // Execute multiple fast commands
        for i in 1...10 {
            _ = try! await fastPipeline.execute(FastCommand(value: "Test \(i)"), metadata: StandardCommandMetadata())
        }
        
        // Execute slow commands with varying times
        for time in [0.05, 0.1, 0.15, 0.2, 0.25] {
            _ = try! await slowPipeline.execute(SlowCommand(processingTime: time), metadata: StandardCommandMetadata())
        }
        
        // Execute some failing commands
        for shouldFail in [true, false, true, false, false] {
            do {
                try await failingPipeline.execute(FailingCommand(shouldFail: shouldFail), metadata: StandardCommandMetadata())
            } catch {
                // Expected for failing commands
            }
        }
        
        print("\n--- Performance Statistics ---")
        
        // Get statistics for each command type
        let allStats = await aggregatingCollector.getAllStatistics()
        
        for (commandName, stats) in allStats {
            print("\n\(commandName):")
            print(stats.description)
        }
        
        print("\nTotal measurements collected: \(await aggregatingCollector.getTotalMeasurementCount())")
    }
    
    public static func runCustomCollectorExample() async {
        print("\n=== Custom Performance Collector Example ===")
        
        // Create a custom collector that tracks metrics in memory
        let customCollector = InMemoryPerformanceCollector()
        
        let performanceMiddleware = PerformanceMiddleware(
            collector: customCollector,
            includeDetailedMetrics: true
        )
        
        // Build pipelines for different scenarios
        let fastPipeline = try! await PipelineBuilder(handler: FastCommandHandler())
            .with(performanceMiddleware)
            .build()
            
        let slowPipeline = try! await PipelineBuilder(handler: SlowCommandHandler())
            .with(performanceMiddleware)
            .build()
        
        print("\n--- Executing Commands with Custom Collector ---")
        
        // Execute various commands
        _ = try! await fastPipeline.execute(FastCommand(value: "Custom Test 1"), metadata: StandardCommandMetadata())
        _ = try! await fastPipeline.execute(FastCommand(value: "Custom Test 2"), metadata: StandardCommandMetadata())
        _ = try! await slowPipeline.execute(SlowCommand(processingTime: 0.08), metadata: StandardCommandMetadata())
        _ = try! await slowPipeline.execute(SlowCommand(processingTime: 0.12), metadata: StandardCommandMetadata())
        
        print("\n--- Custom Collector Results ---")
        let measurements = await customCollector.getAllMeasurements()
        
        for measurement in measurements {
            print("Command: \(measurement.commandName)")
            print("  Duration: \(String(format: "%.3f", measurement.executionTime))s")
            print("  Success: \(measurement.isSuccess ? "✅" : "❌")")
            print("  Metrics: \(measurement.metrics)")
            print("")
        }
        
        print("Total measurements collected: \(measurements.count)")
    }
    
    public static func runContextAccessExample() async {
        print("\n=== Context Access Example ===")
        
        // Create a context-aware collector that can access performance data
        let contextCollector = ContextAwarePerformanceCollector()
        
        let performanceMiddleware = PerformanceMiddleware(
            collector: contextCollector,
            includeDetailedMetrics: true
        )
        
        let pipeline = try! await PipelineBuilder(handler: FastCommandHandler())
            .with(performanceMiddleware)
            .build()
        
        print("\n--- Executing Command with Context Access ---")
        
        // Execute command and access performance data through context
        let result = try! await pipeline.execute(FastCommand(value: "Context Test"), metadata: StandardCommandMetadata())
        
        print("Command executed successfully: \(result)")
        print("\n--- Context Collector Analysis ---")
        await contextCollector.printAnalysis()
    }
    
    /// Run all performance middleware examples.
    public static func runAll() async {
        await runConsoleLoggingExample()
        await runAggregatingCollectorExample()
        await runCustomCollectorExample()
        await runContextAccessExample()
        
        print("\n=== Performance Examples Complete ===")
    }
}
