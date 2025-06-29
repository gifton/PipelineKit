import Foundation

// Note: DefaultPipeline is the standard pipeline implementation in PipelineKit

/// Examples demonstrating how to use the built-in observers
public struct ObserverExamples {
    
    /// Example: Using ConsoleObserver for development
    public static func consoleObserverExample() async throws {
        // Create a console observer with pretty formatting
        let consoleObserver = ConsoleObserver.development()
        
        // Create a pipeline with the observer
        let pipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ExampleHandler()),
            observers: [consoleObserver]
        )
        
        // Execute commands - output will be printed to console
        let command = ExampleCommand(value: "Hello")
        let result = try await pipeline.execute(command, metadata: StandardCommandMetadata())
        print("Result: \(result)")
    }
    
    /// Example: Using MemoryObserver for testing
    public static func memoryObserverExample() async throws {
        // Create a memory observer to capture events
        let memoryObserver = MemoryObserver(options: MemoryObserver.Options(
            maxEvents: 1000,
            captureMiddlewareEvents: true
        ))
        
        // Start cleanup if needed
        await memoryObserver.startCleanup()
        
        let pipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ExampleHandler()),
            observers: [memoryObserver]
        )
        
        // Execute some commands
        for i in 0..<5 {
            let command = ExampleCommand(value: "Test \(i)")
            _ = try await pipeline.execute(command, metadata: StandardCommandMetadata())
        }
        
        // Query the captured events
        let allEvents = await memoryObserver.allEvents()
        print("Captured \(allEvents.count) events")
        
        let stats = await memoryObserver.statistics()
        print("Executed \(stats.pipelineExecutions) pipelines")
        print("Success rate: \(Double(stats.successfulExecutions) / Double(stats.pipelineExecutions) * 100)%")
    }
    
    /// Example: Using MetricsObserver with console backend
    public static func metricsObserverExample() async throws {
        // Create a metrics observer with console backend for development
        let metricsBackend = ConsoleMetricsBackend()
        let metricsObserver = MetricsObserver(
            backend: metricsBackend,
            configuration: MetricsObserver.Configuration(
                metricPrefix: "myapp.pipeline",
                includeCommandType: true,
                trackMiddleware: true
            )
        )
        
        let pipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ExampleHandler()),
            observers: [metricsObserver]
        )
        
        // Execute commands - metrics will be printed to console
        let command = ExampleCommand(value: "Metrics Test")
        _ = try await pipeline.execute(command, metadata: StandardCommandMetadata())
    }
    
    /// Example: Using CompositeObserver to combine multiple observers
    public static func compositeObserverExample() async throws {
        // Combine console and memory observers
        let consoleObserver = ConsoleObserver(style: .simple, level: .info)
        let memoryObserver = MemoryObserver()
        let metricsObserver = MetricsObserver(
            backend: InMemoryMetricsBackend(),
            configuration: .init(metricPrefix: "app")
        )
        
        let compositeObserver = CompositeObserver(
            consoleObserver,
            memoryObserver,
            metricsObserver
        )
        
        let pipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ExampleHandler()),
            observers: [compositeObserver]
        )
        
        // All observers will receive events
        let command = ExampleCommand(value: "Composite Test")
        _ = try await pipeline.execute(command, metadata: StandardCommandMetadata())
    }
    
    /// Example: Using ConditionalObserver for selective observation
    public static func conditionalObserverExample() async throws {
        // Only observe specific command types
        let errorObserver = ConditionalObserver.onlyFailures(
            observer: ConsoleObserver(style: .pretty, level: .error)
        )
        
        // Only observe commands matching a pattern
        let importantObserver = ConditionalObserver.matching(
            pattern: "Important",
            observer: ConsoleObserver.development()
        )
        
        // Need separate pipelines for different command types
        let examplePipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ExampleHandler()),
            observers: [errorObserver]
        )
        
        let importantPipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ImportantHandler()),
            observers: [importantObserver]
        )
        
        // This will be observed by importantObserver
        let importantCommand = ImportantCommand(value: "Critical")
        _ = try await importantPipeline.execute(importantCommand, metadata: StandardCommandMetadata())
        
        // This won't be observed by importantObserver (unless it fails and errorObserver sees it)
        let regularCommand = ExampleCommand(value: "Regular")
        _ = try await examplePipeline.execute(regularCommand, metadata: StandardCommandMetadata())
    }
    
    /// Example: Production setup with multiple observers
    public static func productionSetupExample() async throws {
        // OS Log for Apple platforms
        let osLogObserver = OSLogObserver.production()
        
        // Metrics for monitoring
        let metricsObserver = MetricsObserver(
            backend: MyProductionMetricsBackend(), // Your real metrics backend
            configuration: MetricsObserver.Configuration(
                metricPrefix: "production.pipeline",
                includeCommandType: true,
                includePipelineType: true,
                globalTags: [
                    "environment": "production",
                    "service": "api",
                    "version": "1.0.0"
                ]
            )
        )
        
        // Memory observer for debugging (with limited retention)
        let debugObserver = MemoryObserver(options: MemoryObserver.Options(
            maxEvents: 100,
            captureMiddlewareEvents: false,
            cleanupInterval: 3600 // 1 hour
        ))
        await debugObserver.startCleanup()
        
        // Create your pipeline with all observers
        let pipeline = ObservablePipeline(
            wrapping: DefaultPipeline(handler: ProductionHandler()),
            observers: [
                osLogObserver,
                metricsObserver,
                debugObserver
            ]
        )
        
        // Use the pipeline
        let command = ProductionCommand()
        _ = try await pipeline.execute(command, metadata: StandardCommandMetadata())
    }
}

// MARK: - Example Commands and Handlers

private struct ExampleCommand: Command {
    let value: String
    typealias Result = String
}

private struct ImportantCommand: Command {
    let value: String
    typealias Result = String
}

private struct ProductionCommand: Command {
    typealias Result = Void
}

private struct ExampleHandler: CommandHandler {
    func handle(_ command: ExampleCommand) async throws -> String {
        return "Processed: \(command.value)"
    }
}

private struct ImportantHandler: CommandHandler {
    func handle(_ command: ImportantCommand) async throws -> String {
        return "Important: \(command.value)"
    }
}

private struct ProductionHandler: CommandHandler {
    func handle(_ command: ProductionCommand) async throws {
        // Production logic here
    }
}

// Placeholder for production metrics backend
private struct MyProductionMetricsBackend: MetricsBackend {
    func recordCounter(name: String, tags: [String: String]) async {
        // Send to your metrics service
    }
    
    func recordGauge(name: String, value: Double, tags: [String: String]) async {
        // Send to your metrics service
    }
    
    func recordHistogram(name: String, value: Double, tags: [String: String]) async {
        // Send to your metrics service
    }
}