//
//  ObservabilitySystem.swift
//  PipelineKit
//
//  Unified observability system combining events and metrics naturally
//

import Foundation
import PipelineKitCore

/// A complete observability system with natural event and metric integration.
///
/// This provides a single entry point for all observability needs,
/// automatically converting events to metrics and providing unified configuration.
///
/// ## Usage Example
/// ```swift
/// // Create unified system
/// let observability = await ObservabilitySystem.production(
///     statsdHost: "localhost",
///     statsdPort: 8125
/// )
///
/// // Use in context
/// context.eventEmitter = observability.eventHub
///
/// // Events automatically generate metrics!
/// context.emitCommandCompleted(type: "CreateUser", duration: 0.125)
/// // This generates:
/// // - Event: command.completed with properties
/// // - Metric: command.duration (timer) = 125ms
/// // - Metric: command.completed (counter) = 1
/// ```
public actor ObservabilitySystem {
    /// The event hub for routing events
    public let eventHub: EventHub
    
    /// The metrics storage for local aggregation
    public let metricsStorage: MetricsStorage
    
    /// Optional StatsD exporter
    private var statsdExporter: StatsDExporter?
    
    /// Configuration
    private let config: Configuration
    
    /// System-wide configuration
    public struct Configuration: Sendable {
        public let enableEvents: Bool
        public let enableMetrics: Bool
        public let metricsGeneration: MetricsGenerationConfig
        public let logEvents: Bool
        public let logLevel: LoggingEmitter.Level
        
        public init(
            enableEvents: Bool = true,
            enableMetrics: Bool = true,
            metricsGeneration: MetricsGenerationConfig = .default,
            logEvents: Bool = true,
            logLevel: LoggingEmitter.Level = .info
        ) {
            self.enableEvents = enableEvents
            self.enableMetrics = enableMetrics
            self.metricsGeneration = metricsGeneration
            self.logEvents = logEvents
            self.logLevel = logLevel
        }
        
        /// Development configuration with verbose logging
        public static let development = Configuration(
            enableEvents: true,
            enableMetrics: true,
            metricsGeneration: .default,
            logEvents: true,
            logLevel: .debug
        )
        
        /// Production configuration with optimized settings
        public static let production = Configuration(
            enableEvents: true,
            enableMetrics: true,
            metricsGeneration: .production,
            logEvents: false,
            logLevel: .warning
        )
    }
    
    /// Creates a new observability system.
    public init(configuration: Configuration = .development) async {
        self.config = configuration
        self.eventHub = EventHub()
        self.metricsStorage = MetricsStorage()
        
        // Set up natural integration
        await setupIntegration()
    }
    
    /// Creates a production-ready observability system.
    public static func production(
        statsdHost: String = "localhost",
        statsdPort: Int = 8125,
        prefix: String? = nil,
        globalTags: [String: String] = [:]
    ) async -> ObservabilitySystem {
        let system = await ObservabilitySystem(configuration: .production)
        
        // Configure StatsD
        await system.enableStatsD(
            host: statsdHost,
            port: statsdPort,
            prefix: prefix,
            globalTags: globalTags
        )
        
        return system
    }
    
    /// Enables StatsD export.
    public func enableStatsD(
        host: String = "localhost",
        port: Int = 8125,
        prefix: String? = nil,
        globalTags: [String: String] = [:]
    ) async {
        let config = StatsDExporter.Configuration(
            host: host,
            port: port,
            prefix: prefix,
            globalTags: globalTags
        )
        
        statsdExporter = StatsDExporter(configuration: config)
        
        if let exporter = statsdExporter {
            // Bridge metrics to StatsD
            let bridge = MetricsEventBridge(
                recorder: exporter,
                config: self.config.metricsGeneration
            )
            await eventHub.subscribe(bridge)
        }
    }
    
    /// Records a metric directly.
    ///
    /// While events automatically generate metrics, you can also
    /// record metrics directly when needed.
    public func recordMetric(_ snapshot: MetricSnapshot) async {
        guard config.enableMetrics else { return }
        
        // Record locally
        await metricsStorage.record(snapshot)
        
        // Forward to StatsD if configured
        if let exporter = statsdExporter {
            await exporter.record(snapshot)
        }
    }
    
    /// Emits an event directly.
    ///
    /// Events will automatically generate metrics based on configuration.
    public func emit(_ event: PipelineEvent) {
        guard config.enableEvents else { return }
        eventHub.emit(event)
    }
    
    /// Gets current metrics.
    public func getMetrics() async -> [MetricSnapshot] {
        await metricsStorage.getAll()
    }
    
    /// Drains and returns all metrics.
    public func drainMetrics() async -> [MetricSnapshot] {
        await metricsStorage.drain()
    }
    
    /// Gets event hub statistics.
    public func getEventStatistics() async -> EventHubStatistics {
        await eventHub.statistics
    }
    
    // MARK: - Private Methods
    
    private func setupIntegration() async {
        // Set up automatic event-to-metric conversion
        if config.enableMetrics {
            let bridge = MetricsEventBridge(
                recorder: metricsStorage,
                config: config.metricsGeneration
            )
            await eventHub.subscribe(bridge)
        }
        
        // Set up logging if enabled
        if config.logEvents {
            let logger = LoggingEmitter(
                category: "observability",
                minimumLevel: config.logLevel
            )
            // LoggingEmitter is an EventEmitter, not a subscriber
            // We need to create a bridge
            let loggingBridge = LoggingEventBridge(emitter: logger)
            await eventHub.subscribe(loggingBridge)
        }
    }
}

// MARK: - CommandContext Extension for Natural Usage

public extension CommandContext {
    /// Gets or creates an observability system for this context.
    ///
    /// This provides the most natural integration - the context
    /// automatically has observability capabilities.
    var observability: ObservabilitySystem? {
        get async {
            // Check if we already have one
            if let emitter = eventEmitter as? EventHub {
                // Try to find the associated system
                // For now, we'll need to store it separately
                return nil
            }
            return nil
        }
    }
    
    /// Configures observability for this context.
    ///
    /// This is the most natural way to add observability:
    /// ```swift
    /// let context = CommandContext()
    /// await context.setupObservability(.production)
    /// 
    /// // Now events automatically generate metrics!
    /// context.emitCommandStarted(type: "CreateUser")
    /// ```
    func setupObservability(
        _ config: ObservabilitySystem.Configuration = .development
    ) async {
        let system = await ObservabilitySystem(configuration: config)
        self.eventEmitter = system.eventHub
    }
    
    /// Records a metric through the context's observability system.
    ///
    /// This provides natural metric recording alongside events:
    /// ```swift
    /// context.recordMetric(.gauge("memory.usage", value: 67.5))
    /// ```
    func recordMetric(_ snapshot: MetricSnapshot) async {
        // If we have a metrics-capable event emitter, use it
        if let hub = eventEmitter as? EventHub {
            // The hub should have a metrics bridge subscribed
            // For now, we emit a synthetic event that will be converted
            let event = PipelineEvent(
                name: "metric.recorded",
                properties: [
                    "metric_name": snapshot.name,
                    "metric_type": snapshot.type,
                    "metric_value": snapshot.value ?? 0,
                    "metric_tags": snapshot.tags
                ],
                correlationID: correlationID ?? commandMetadata.correlationId ?? UUID().uuidString
            )
            hub.emit(event)
        }
    }
}

// MARK: - Convenience Extensions

public extension ObservabilitySystem {
    /// Creates a minimal system for testing.
    static func test() async -> ObservabilitySystem {
        await ObservabilitySystem(configuration: Configuration(
            enableEvents: true,
            enableMetrics: true,
            metricsGeneration: .default,
            logEvents: false,
            logLevel: .error
        ))
    }
    
    /// Subscribes a custom event subscriber.
    func subscribe(_ subscriber: any EventSubscriber) async {
        await eventHub.subscribe(subscriber)
    }
    
    /// Unsubscribes an event subscriber.
    func unsubscribe(_ subscriber: any EventSubscriber) async {
        await eventHub.unsubscribe(subscriber)
    }
}