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
        
        // Build pipeline with performance middleware
        let pipeline = try! PipelineBuilder()
            .addMiddleware(performanceMiddleware)
            .addHandler(FastCommandHandler())
            .addHandler(SlowCommandHandler())
            .addHandler(FailingCommandHandler())
            .build()
        
        print("\n--- Executing Fast Command ---")
        try! await pipeline.execute(FastCommand(value: "Hello World"))
        
        print("\n--- Executing Slow Command ---")
        try! await pipeline.execute(SlowCommand(processingTime: 0.1))
        
        print("\n--- Executing Failing Command ---")
        do {
            try await pipeline.execute(FailingCommand(shouldFail: true))
        } catch {
            print("Expected failure occurred")
        }
        
        print("\n--- Executing Successful Command ---")
        try! await pipeline.execute(FailingCommand(shouldFail: false))
    }
    
    public static func runAggregatingCollectorExample() async {
        print("\n=== Aggregating Performance Collector Example ===")
        
        // Create aggregating collector
        let aggregatingCollector = AggregatingPerformanceCollector(maxMeasurementsPerCommand: 100)
        
        let performanceMiddleware = PerformanceMiddleware(
            collector: aggregatingCollector,
            includeDetailedMetrics: false
        )
        
        // Build pipeline
        let pipeline = try! PipelineBuilder()
            .addMiddleware(performanceMiddleware)
            .addHandler(FastCommandHandler())
            .addHandler(SlowCommandHandler())
            .addHandler(FailingCommandHandler())
            .build()
        
        print("\n--- Running Multiple Commands ---")
        
        // Execute multiple fast commands
        for i in 1...10 {
            try! await pipeline.execute(FastCommand(value: "Test \(i)"))
        }
        
        // Execute slow commands with varying times
        for time in [0.05, 0.1, 0.15, 0.2, 0.25] {
            try! await pipeline.execute(SlowCommand(processingTime: time))
        }
        
        // Execute some failing commands
        for shouldFail in [true, false, true, false, false] {
            do {
                try await pipeline.execute(FailingCommand(shouldFail: shouldFail))
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
        
        // Create custom collector using closure
        let performanceMiddleware = PerformanceMiddleware { measurement in
            let emoji = measurement.isSuccess ? "✅" : "❌"
            let duration = String(format: "%.3f", measurement.executionTime)
            
            if measurement.executionTime > 0.1 {
                print("🐌 SLOW: \(emoji) \(measurement.commandName) took \(duration)s")
            } else {
                print("⚡ FAST: \(emoji) \(measurement.commandName) took \(duration)s")
            }
            
            // Could send to external monitoring service here
            // await sendToMonitoringService(measurement)
        }
        
        // Build pipeline
        let pipeline = try! PipelineBuilder()
            .addMiddleware(performanceMiddleware)
            .addHandler(FastCommandHandler())
            .addHandler(SlowCommandHandler())
            .build()
        
        print("\n--- Executing Commands with Custom Collector ---")
        
        try! await pipeline.execute(FastCommand(value: "Quick task"))
        try! await pipeline.execute(SlowCommand(processingTime: 0.05))
        try! await pipeline.execute(SlowCommand(processingTime: 0.15))
        try! await pipeline.execute(FastCommand(value: "Another quick task"))
    }
    
    public static func runContextAccessExample() async {
        print("\n=== Context Access Example ===")
        
        // Custom middleware that accesses performance data
        struct PerformanceAnalysisMiddleware: ContextAwareMiddleware {
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                let result = try await next(command, context)
                
                // Access performance measurement from context
                if let measurement = await context[PerformanceMeasurementKey.self] {
                    if measurement.executionTime > 0.1 {
                        print("🔍 Analysis: \(measurement.commandName) execution exceeded threshold (>\(measurement.executionTime)s)")
                    }
                }
                
                return result
            }
        }
        
        let performanceMiddleware = PerformanceMiddleware(
            collector: ConsolePerformanceCollector(logLevel: .verbose)
        )
        
        // Build pipeline with both performance and analysis middleware
        let pipeline = try! PipelineBuilder()
            .addMiddleware(performanceMiddleware)
            .addMiddleware(PerformanceAnalysisMiddleware())
            .addHandler(SlowCommandHandler())
            .build()
        
        print("\n--- Executing Commands with Context Access ---")
        
        try! await pipeline.execute(SlowCommand(processingTime: 0.05))
        try! await pipeline.execute(SlowCommand(processingTime: 0.15))
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