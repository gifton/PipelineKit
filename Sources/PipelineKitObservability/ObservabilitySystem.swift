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
    
    /// System-wide configuration: which of events, metrics, and logging are
    /// active, and how events are converted into metrics.
    public struct Configuration: Sendable {
        /// Whether `emit(_:)` forwards events to `eventHub`; when `false`,
        /// `emit(_:)` is a no-op. This gates only that one method — it does not
        /// control whether the metrics/logging bridges are installed (see
        /// `enableMetrics`/`logEvents`) and has no effect on events delivered to
        /// `eventHub` through any other path (see the caveat on `emit(_:)`).
        public let enableEvents: Bool

        /// Whether `init(configuration:)` subscribes a `MetricsEventBridge` to
        /// `eventHub` during setup, and whether `recordCounter`/`recordGauge`/
        /// `recordTimer` record into `metricsStorage` (and forward to StatsD, if
        /// configured) or return immediately without recording.
        public let enableMetrics: Bool

        /// Controls which events the automatic event-to-metric bridge converts,
        /// and which of duration, count, and error metrics it generates. Only
        /// consulted when `enableMetrics` is `true`.
        public let metricsGeneration: MetricsGenerationConfig

        /// Whether `init(configuration:)` subscribes a logging bridge to
        /// `eventHub` during setup, so that emitted events are also logged via a
        /// `LoggingEmitter`.
        public let logEvents: Bool

        /// The minimum level the logging bridge's `LoggingEmitter` logs at.
        /// Only consulted when `logEvents` is `true`.
        public let logLevel: LoggingEmitter.Level

        /// Creates a system-wide configuration.
        ///
        /// - Parameters:
        ///   - enableEvents: Whether calls to `emit(_:)` are forwarded to
        ///     `eventHub` (see that method's caveat about other paths into the
        ///     hub). Defaults to `true`.
        ///   - enableMetrics: Whether the automatic event-to-metric bridge is
        ///     installed and whether the `recordCounter`/`recordGauge`/
        ///     `recordTimer` methods record anything. Defaults to `true`.
        ///   - metricsGeneration: Which events generate metrics, and which kinds.
        ///     Defaults to `.default`.
        ///   - logEvents: Whether a logging bridge is installed so events are
        ///     also logged. Defaults to `true`.
        ///   - logLevel: The minimum level the logging bridge logs at. Defaults
        ///     to `.info`.
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
    
    /// Creates a new observability system: a fresh `eventHub` and
    /// `metricsStorage`, with itself registered as the hub's parent system (so
    /// `CommandContext.observability` can find it back from the hub), and — per
    /// `configuration` — the automatic event-to-metric bridge and/or logging
    /// bridge already subscribed to `eventHub`.
    ///
    /// - Parameter configuration: Which of events, metrics, and logging are
    ///   active. Defaults to `.development`.
    public init(configuration: Configuration = .development) async {
        self.config = configuration
        self.eventHub = EventHub()
        self.metricsStorage = MetricsStorage()

        // Set this system as the parent of the event hub
        await eventHub.setParentSystem(self)

        // Set up natural integration
        await setupIntegration()
    }

    /// Creates a system using `Configuration.production` and immediately calls
    /// `enableStatsD(host:port:prefix:globalTags:)` with the given StatsD
    /// settings.
    ///
    /// - Parameters:
    ///   - statsdHost: The StatsD server host. Defaults to `"localhost"`.
    ///   - statsdPort: The StatsD server port. Defaults to `8125`.
    ///   - prefix: An optional prefix prepended to every exported metric name.
    ///     Defaults to `nil`.
    ///   - globalTags: Tags attached to every metric sent to StatsD. Defaults to
    ///     empty.
    /// - Returns: The configured, StatsD-enabled system.
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
    
    /// Creates a `StatsDExporter` for `host`/`port` and subscribes a dedicated
    /// `MetricsEventBridge` (using `Configuration.metricsGeneration`) to
    /// `eventHub` that forwards converted metrics to it. This is independent of
    /// `Configuration.enableMetrics`: it subscribes the bridge unconditionally,
    /// so events reaching `eventHub` generate StatsD metrics even if the
    /// system's own local `metricsStorage` bridge was never installed.
    /// `recordCounter`/`recordGauge`/`recordTimer`, however, still forward
    /// directly to the exporter only when `Configuration.enableMetrics` is
    /// `true` (they return early before reaching it otherwise).
    ///
    /// - Parameters:
    ///   - host: The StatsD server host. Defaults to `"localhost"`.
    ///   - port: The StatsD server port. Defaults to `8125`.
    ///   - prefix: An optional prefix prepended to every exported metric name.
    ///     Defaults to `nil`.
    ///   - globalTags: Tags attached to every metric sent to StatsD. Defaults to
    ///     empty.
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
    
    /// Records a counter metric directly into `metricsStorage`, and forwards it
    /// to StatsD if `enableStatsD(host:port:prefix:globalTags:)` was called.
    /// No-op if `Configuration.enableMetrics` is `false`.
    ///
    /// - Parameters:
    ///   - name: The metric name.
    ///   - value: The amount to record. Defaults to `1.0`.
    ///   - tags: Tags attached to the recorded snapshot. Defaults to empty.
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

    /// Records a gauge metric directly into `metricsStorage`, and forwards it to
    /// StatsD if `enableStatsD(host:port:prefix:globalTags:)` was called. No-op
    /// if `Configuration.enableMetrics` is `false`.
    ///
    /// - Parameters:
    ///   - name: The metric name.
    ///   - value: The gauge's current value.
    ///   - tags: Tags attached to the recorded snapshot. Defaults to empty.
    ///   - unit: An optional unit label for the value. Defaults to `nil`.
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

    /// Records a timer metric directly into `metricsStorage`, and forwards it to
    /// StatsD if `enableStatsD(host:port:prefix:globalTags:)` was called. No-op
    /// if `Configuration.enableMetrics` is `false`.
    ///
    /// - Parameters:
    ///   - name: The metric name.
    ///   - duration: The measured duration, in seconds.
    ///   - tags: Tags attached to the recorded snapshot. Defaults to empty.
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


    /// Forwards `event` to `eventHub`, which fans it out to any subscribed
    /// bridges (metrics, logging, StatsD) and to `CommandContext.observability`
    /// consumers. No-op if `Configuration.enableEvents` is `false`. Note that
    /// this is not the only path events can reach `eventHub`: code holding the
    /// hub directly (for example via `CommandContext.eventEmitter`, as set up by
    /// `setupObservability(_:)`) can emit to it without going through this
    /// method, bypassing this `enableEvents` check.
    ///
    /// - Parameter event: The event to emit.
    public func emit(_ event: PipelineEvent) {
        guard config.enableEvents else { return }
        eventHub.emit(event)
    }
    
    /// Returns every metric snapshot currently held in `metricsStorage`, without
    /// removing them — a later call to `getMetrics()` or `drainMetrics()` will
    /// still see them.
    ///
    /// - Returns: All stored snapshots.
    public func getMetrics() async -> [MetricSnapshot] {
        await metricsStorage.getAll()
    }

    /// Returns every metric snapshot currently held in `metricsStorage` and
    /// removes them from storage as part of the same call — unlike
    /// `getMetrics()`, a subsequent call will not see snapshots already
    /// returned by this one.
    ///
    /// - Returns: All snapshots that were stored at the time of the call.
    public func drainMetrics() async -> [MetricSnapshot] {
        await metricsStorage.drain()
    }

    /// Returns a snapshot of `eventHub`'s counters (events emitted/delivered,
    /// subscriptions, cleanup activity) as of the call.
    ///
    /// - Returns: The hub's current statistics.
    public func getEventStatistics() async -> EventHubStatistics {
        await eventHub.statistics
    }

    /// Returns `eventHub`, e.g. to assign as a `CommandContext.eventEmitter`
    /// when setting up a context manually instead of via
    /// `setupObservability(_:)`.
    ///
    /// - Returns: This system's event hub.
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
    
    /// Configures observability for this context: creates an
    /// `ObservabilitySystem` from `config`, assigns its event hub as this
    /// context's `eventEmitter`, and retains the system on the context (under
    /// `ContextKey<ObservabilitySystem>.observabilitySystem`) so it stays alive
    /// even though the hub only holds it weakly.
    ///
    /// This is the most natural way to add observability:
    /// ```swift
    /// let context = CommandContext()
    /// await context.setupObservability(.production)
    ///
    /// // Now events automatically generate metrics!
    /// await context.emitCommandStarted(type: "CreateUser")
    ///
    /// // And you can access the full system:
    /// let metrics = await context.observability?.getMetrics()
    /// ```
    ///
    /// - Parameter config: Which of events, metrics, and logging are active on
    ///   the created system. Defaults to `.development`.
    func setupObservability(
        _ config: ObservabilitySystem.Configuration = .development
    ) async {
        let system = await ObservabilitySystem(configuration: config)
        let hub = await system.getEventHub()
        self.eventEmitter = hub

        // Store the system in the context to keep it alive
        // The hub has only a weak reference to prevent cycles
        self[.observabilitySystem] = system
    }
    
    /// Emits a `"metric.counter.recorded"` event carrying `name`/`value`/`tags`
    /// to `eventEmitter`; a no-op if the emitter is not an `EventHub` (e.g.
    /// `setupObservability(_:)` was never called on this context).
    ///
    /// - Note: `MetricsEventBridge` records this as a counter snapshot with
    ///   this method's `name`, `value`, and `tags`. As direct user intent it
    ///   bypasses the derived-metric configuration gates
    ///   (`includePatterns`/`excludePatterns`/`recordCounts`), so it works
    ///   under `.production`. It is disabled when either
    ///   `ObservabilitySystem.Configuration.enableMetrics` is `false` (then
    ///   `setupIntegration()` never subscribes a `MetricsEventBridge`, so no
    ///   bridge exists to convert the event) or
    ///   `MetricsGenerationConfig.enabled` is `false` (the subscribed
    ///   bridge's `process(_:)` returns immediately). However,
    ///   `enableStatsD(host:port:prefix:globalTags:)` is independent of
    ///   `enableMetrics` and subscribes a separate bridge unconditionally, so
    ///   metrics reach StatsD even if the local `metricsStorage` bridge is not
    ///   installed.
    ///
    /// - Parameters:
    ///   - name: The metric name to record.
    ///   - value: The counter increment. Defaults to `1.0`.
    ///   - tags: Dimensional tags for the metric. Defaults to empty.
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
    
    /// Emits a `"metric.gauge.recorded"` event carrying `name`/`value`/`tags`/
    /// `unit` to `eventEmitter`; a no-op if the emitter is not an `EventHub`
    /// (e.g. `setupObservability(_:)` was never called on this context).
    ///
    /// - Note: `MetricsEventBridge` records this as a gauge snapshot with this
    ///   method's `name`, `value`, `tags`, and `unit`. As direct user intent it
    ///   bypasses the derived-metric configuration gates
    ///   (`includePatterns`/`excludePatterns`/`recordCounts`), so it works
    ///   under `.production`. It is disabled when either
    ///   `ObservabilitySystem.Configuration.enableMetrics` is `false` (then
    ///   `setupIntegration()` never subscribes a `MetricsEventBridge`, so no
    ///   bridge exists to convert the event) or
    ///   `MetricsGenerationConfig.enabled` is `false` (the subscribed
    ///   bridge's `process(_:)` returns immediately). However,
    ///   `enableStatsD(host:port:prefix:globalTags:)` is independent of
    ///   `enableMetrics` and subscribes a separate bridge unconditionally, so
    ///   metrics reach StatsD even if the local `metricsStorage` bridge is not
    ///   installed.
    ///
    /// - Parameters:
    ///   - name: The metric name to record.
    ///   - value: The gauge's current value.
    ///   - tags: Dimensional tags for the metric. Defaults to empty.
    ///   - unit: An optional unit label for the value, propagated to the
    ///     recorded snapshot. Defaults to `nil`.
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
    
    /// Emits a `"metric.timer.recorded"` event carrying `name`/`duration`/
    /// `tags` to `eventEmitter`; a no-op if the emitter is not an `EventHub`
    /// (e.g. `setupObservability(_:)` was never called on this context).
    ///
    /// - Note: `MetricsEventBridge` records this as a timer snapshot with this
    ///   method's `name` and `tags`. `duration` is converted to milliseconds
    ///   before being packed into the event and is recorded as-is (unit
    ///   `"ms"`) — the bridge does not re-convert it. As direct user intent it
    ///   bypasses the derived-metric configuration gates
    ///   (`includePatterns`/`excludePatterns`/`recordCounts`), so it works
    ///   under `.production`. It is disabled when either
    ///   `ObservabilitySystem.Configuration.enableMetrics` is `false` (then
    ///   `setupIntegration()` never subscribes a `MetricsEventBridge`, so no
    ///   bridge exists to convert the event) or
    ///   `MetricsGenerationConfig.enabled` is `false` (the subscribed
    ///   bridge's `process(_:)` returns immediately). However,
    ///   `enableStatsD(host:port:prefix:globalTags:)` is independent of
    ///   `enableMetrics` and subscribes a separate bridge unconditionally, so
    ///   metrics reach StatsD even if the local `metricsStorage` bridge is not
    ///   installed.
    ///
    /// - Parameters:
    ///   - name: The metric name to record.
    ///   - duration: The measured duration, in seconds; recorded in
    ///     milliseconds with unit `"ms"`.
    ///   - tags: Dimensional tags for the metric. Defaults to empty.
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
    /// Creates a system with events and metrics enabled, `.default`
    /// `metricsGeneration`, and logging disabled — a quieter alternative to
    /// `Configuration.development` for use in tests.
    ///
    /// - Returns: The configured system.
    static func test() async -> ObservabilitySystem {
        await ObservabilitySystem(configuration: Configuration(
            enableEvents: true,
            enableMetrics: true,
            metricsGeneration: .default,
            logEvents: false,
            logLevel: .error
        ))
    }

    /// Subscribes `subscriber` to `eventHub` directly, alongside any bridges
    /// installed by `init(configuration:)` or `enableStatsD(host:port:prefix:
    /// globalTags:)`. Unlike those bridges, `subscriber` is not retained by
    /// this system — the caller is responsible for keeping it alive, since
    /// `eventHub` itself only holds subscribers weakly.
    ///
    /// - Parameter subscriber: The subscriber to add.
    func subscribe(_ subscriber: any EventSubscriber) async {
        await eventHub.subscribe(subscriber)
    }

    /// Removes `subscriber` from `eventHub`.
    ///
    /// - Parameter subscriber: The subscriber to remove.
    func unsubscribe(_ subscriber: any EventSubscriber) async {
        await eventHub.unsubscribe(subscriber)
    }
}
