//
//  ObservabilitySystem.swift
//  PipelineKit
//
//  Unified observability system combining events and metrics naturally
//

import Foundation
import PipelineKitCore

// MARK: - Context Key for ObservabilitySystem

extension ContextKey where Value == ObservabilitySystem {
    /// Key for storing the ObservabilitySystem in the context
    static var observabilitySystem: ContextKey<ObservabilitySystem> {
        ContextKey<ObservabilitySystem>("__observability_system")
    }
}

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
/// await context.emitCommandCompleted(type: "CreateUser", duration: 0.125)
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
    
    /// Strong references to event subscribers to prevent premature deallocation
    /// EventHub stores subscribers weakly to avoid retain cycles, so the system
    /// maintains strong references for the bridges it creates.
    private var retainedSubscribers: [any EventSubscriber] = []
    
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
        
        // Set this system as the parent of the event hub
        await eventHub.setParentSystem(self)
        
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
        
        // Using async init with transport
        statsdExporter = await StatsDExporter(configuration: config)
        
        if let exporter = statsdExporter {
            // Bridge metrics to StatsD
            let bridge = MetricsEventBridge(
                recorder: exporter,
                config: self.config.metricsGeneration
            )
            await eventHub.subscribe(bridge)
            // Retain the bridge to keep it alive
            retainedSubscribers.append(bridge)
        }
    }
    
    /// Records a counter metric.
    public func recordCounter(
        name: String,
        value: Double = 1.0,
        tags: [String: String] = [:]
    ) async {
        guard config.enableMetrics else { return }
        
        let snapshot = MetricSnapshot.counter(name, value: value, tags: tags)
        
        // Record locally
        await metricsStorage.record(snapshot)
        
        // Forward to StatsD if configured
        if let exporter = statsdExporter {
            await exporter.record(snapshot)
        }
    }
    
    /// Records a gauge metric.
    public func recordGauge(
        name: String,
        value: Double,
        tags: [String: String] = [:],
        unit: String? = nil
    ) async {
        guard config.enableMetrics else { return }
        
        let snapshot = MetricSnapshot.gauge(name, value: value, tags: tags, unit: unit)
        
        // Record locally
        await metricsStorage.record(snapshot)
        
        // Forward to StatsD if configured
        if let exporter = statsdExporter {
            await exporter.record(snapshot)
        }
    }
    
    /// Records a timer metric.
    public func recordTimer(
        name: String,
        duration: TimeInterval,
        tags: [String: String] = [:]
    ) async {
        guard config.enableMetrics else { return }
        
        let snapshot = MetricSnapshot.timer(name, duration: duration, tags: tags)
        
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
    
    /// Gets the event hub for this system.
    /// This is useful when setting up a CommandContext manually.
    public func getEventHub() -> EventHub {
        return eventHub
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
            // Retain the bridge to keep it alive
            retainedSubscribers.append(bridge)
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
            // Retain the bridge to keep it alive
            retainedSubscribers.append(loggingBridge)
        }
    }
}

// MARK: - CommandContext Extension for Natural Usage

public extension CommandContext {
    /// Gets the observability system for this context if one is configured.
    ///
    /// This provides the most natural integration - the context
    /// automatically has observability capabilities when an ObservabilitySystem
    /// has been set up with setupObservability().
    ///
    /// - Returns: The ObservabilitySystem if one is configured, nil otherwise
    var observability: ObservabilitySystem? {
        get async {
            // Check if we have an EventHub as the event emitter
            if let hub = self.eventEmitter as? EventHub {
                // Get the parent system from the hub
                return await hub.getParentSystem()
            }
            return nil
        }
    }
    
    /// Configures observability for this context.
    ///
    /// This is the most natural way to add observability:
    /// ```swift
    /// let context = CommandContext()
    /// context.setupObservability(.production)
    /// 
    /// // Now events automatically generate metrics!
    /// await context.emitCommandStarted(type: "CreateUser")
    /// 
    /// // And you can access the full system:
    /// let metrics = context.observability?.getMetrics()
    /// ```
    func setupObservability(
        _ config: ObservabilitySystem.Configuration = .development
    ) async {
        let system = await ObservabilitySystem(configuration: config)
        let hub = await system.getEventHub()
        self.setEventEmitter(hub)
        
        // Store the system in the context to keep it alive
        // The hub has only a weak reference to prevent cycles
        self.set(.observabilitySystem, value: system)
    }
    
    /// Records a counter metric through the context's observability system.
    func recordCounter(
        name: String,
        value: Double = 1.0,
        tags: [String: String] = [:]
    ) async {
        // If we have a metrics-capable event emitter, use it
        if let hub = eventEmitter as? EventHub {
            let event = PipelineEvent(
                name: "metric.counter.recorded",
                properties: [
                    "metric_name": name,
                    "metric_type": "counter",
                    "metric_value": value,
                    "metric_tags": tags
                ],
                correlationID: correlationID ?? commandMetadata.correlationID ?? UUID().uuidString
            )
            await hub.emit(event)
        }
    }
    
    /// Records a gauge metric through the context's observability system.
    func recordGauge(
        name: String,
        value: Double,
        tags: [String: String] = [:],
        unit: String? = nil
    ) async {
        // If we have a metrics-capable event emitter, use it
        if let hub = eventEmitter as? EventHub {
            var props: [String: any Sendable] = [
                "metric_name": name,
                "metric_type": "gauge",
                "metric_value": value,
                "metric_tags": tags
            ]
            if let unit = unit {
                props["metric_unit"] = unit
            }
            let event = PipelineEvent(
                name: "metric.gauge.recorded",
                properties: props,
                correlationID: correlationID ?? commandMetadata.correlationID ?? UUID().uuidString
            )
            await hub.emit(event)
        }
    }
    
    /// Records a timer metric through the context's observability system.
    func recordTimer(
        name: String,
        duration: TimeInterval,
        tags: [String: String] = [:]
    ) async {
        // If we have a metrics-capable event emitter, use it
        if let hub = eventEmitter as? EventHub {
            let event = PipelineEvent(
                name: "metric.timer.recorded",
                properties: [
                    "metric_name": name,
                    "metric_type": "timer",
                    "metric_value": duration * 1000, // Convert to milliseconds
                    "metric_tags": tags,
                    "metric_unit": "ms"
                ],
                correlationID: correlationID ?? commandMetadata.correlationID ?? UUID().uuidString
            )
            await hub.emit(event)
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
