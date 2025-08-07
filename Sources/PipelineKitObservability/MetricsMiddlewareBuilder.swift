import Foundation
import PipelineKitCore

/// Builder pattern for creating specialized MetricsMiddleware configurations.
///
/// This builder provides a fluent interface for creating metrics middleware
/// with specific configurations for different use cases.
public struct MetricsMiddlewareBuilder {
    private var collector: (any MetricsCollector)?
    private var namespace: String?
    private var includeCommandType: Bool = true
    private var trackErrors: Bool = true
    private var trackContextMetrics: Bool = true
    private var customTags: [String: String] = [:]
    private var recordDurationHistogram: Bool = true
    private var recordExecutionCounter: Bool = true
    private var metricNames: MetricsMiddleware.MetricNames = .default
    
    /// Creates a new builder
    public init() {}
    
    /// Creates a builder starting with a collector
    public static func with(collector: any MetricsCollector) -> MetricsMiddlewareBuilder {
        var builder = MetricsMiddlewareBuilder()
        builder.collector = collector
        return builder
    }
    
    // MARK: - Configuration Methods
    
    /// Sets the metrics collector
    public func withCollector(_ collector: any MetricsCollector) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.collector = collector
        return builder
    }
    
    /// Sets the namespace prefix for all metrics
    public func withNamespace(_ namespace: String) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.namespace = namespace
        return builder
    }
    
    /// Configures whether to include command type as a tag
    public func includeCommandType(_ include: Bool) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.includeCommandType = include
        return builder
    }
    
    /// Configures whether to track error metrics
    public func trackErrors(_ track: Bool) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.trackErrors = track
        return builder
    }
    
    /// Configures whether to track context metrics
    public func trackContextMetrics(_ track: Bool) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.trackContextMetrics = track
        return builder
    }
    
    /// Adds custom tags to all metrics
    public func withTags(_ tags: [String: String]) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.customTags.merge(tags) { _, new in new }
        return builder
    }
    
    /// Adds a single custom tag
    public func withTag(_ key: String, value: String) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.customTags[key] = value
        return builder
    }
    
    /// Configures whether to record duration histograms
    public func recordDurationHistogram(_ record: Bool) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.recordDurationHistogram = record
        return builder
    }
    
    /// Configures whether to record execution counters
    public func recordExecutionCounter(_ record: Bool) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.recordExecutionCounter = record
        return builder
    }
    
    /// Sets custom metric names
    public func withMetricNames(_ names: MetricsMiddleware.MetricNames) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.metricNames = names
        return builder
    }
    
    // MARK: - Preset Configurations
    
    /// Configures for minimal metrics (only duration)
    public func minimal() -> MetricsMiddlewareBuilder {
        var builder = self
        builder.trackErrors = false
        builder.trackContextMetrics = false
        builder.recordDurationHistogram = false
        builder.recordExecutionCounter = false
        return builder
    }
    
    /// Configures for basic metrics (duration + counters)
    public func basic() -> MetricsMiddlewareBuilder {
        var builder = self
        builder.trackContextMetrics = false
        builder.recordDurationHistogram = false
        return builder
    }
    
    /// Configures for standard metrics (recommended defaults)
    public func standard() -> MetricsMiddlewareBuilder {
        // Already using standard defaults
        return self
    }
    
    /// Configures for comprehensive metrics (all features)
    public func comprehensive() -> MetricsMiddlewareBuilder {
        var builder = self
        builder.trackErrors = true
        builder.trackContextMetrics = true
        builder.recordDurationHistogram = true
        builder.recordExecutionCounter = true
        return builder
    }
    
    // MARK: - Domain-Specific Configurations
    
    /// Configures for API endpoint monitoring
    public func forAPI(service: String, version: String = "1.0") -> MetricsMiddlewareBuilder {
        var builder = self
        builder.namespace = "api"
        builder.customTags["service"] = service
        builder.customTags["version"] = version
        builder.trackContextMetrics = true
        return builder
    }
    
    /// Configures for background job monitoring
    public func forBackgroundJob(jobType: String) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.namespace = "jobs"
        builder.customTags["job_type"] = jobType
        builder.metricNames = MetricsMiddleware.MetricNames(
            commandDuration: "job.duration",
            commandCounter: "job.total",
            commandSuccess: "job.success",
            commandFailure: "job.failure",
            commandError: "job.error"
        )
        return builder
    }
    
    /// Configures for event processing
    public func forEventProcessing(eventType: String) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.namespace = "events"
        builder.customTags["event_type"] = eventType
        builder.metricNames = MetricsMiddleware.MetricNames(
            commandDuration: "event.processing_time",
            commandCounter: "event.received",
            commandSuccess: "event.processed",
            commandFailure: "event.failed",
            commandError: "event.error"
        )
        return builder
    }
    
    /// Configures for microservice communication
    public func forMicroservice(service: String, endpoint: String? = nil) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.namespace = "microservice"
        builder.customTags["service"] = service
        if let endpoint = endpoint {
            builder.customTags["endpoint"] = endpoint
        }
        builder.trackContextMetrics = true
        return builder
    }
    
    /// Configures for database operations
    public func forDatabase(database: String, operation: String? = nil) -> MetricsMiddlewareBuilder {
        var builder = self
        builder.namespace = "db"
        builder.customTags["database"] = database
        if let operation = operation {
            builder.customTags["operation"] = operation
        }
        builder.metricNames = MetricsMiddleware.MetricNames(
            commandDuration: "query.duration",
            commandCounter: "query.total",
            commandSuccess: "query.success",
            commandFailure: "query.failure",
            commandError: "query.error"
        )
        return builder
    }
    
    // MARK: - Building
    
    /// Builds the MetricsMiddleware with the configured settings
    public func build() -> MetricsMiddleware? {
        guard let collector = collector else {
            print("Warning: MetricsMiddlewareBuilder requires a collector to be set")
            return nil
        }
        
        let configuration = MetricsMiddleware.Configuration(
            namespace: namespace,
            includeCommandType: includeCommandType,
            trackErrors: trackErrors,
            trackContextMetrics: trackContextMetrics,
            customTags: customTags,
            recordDurationHistogram: recordDurationHistogram,
            recordExecutionCounter: recordExecutionCounter,
            metricNames: metricNames
        )
        
        return MetricsMiddleware(collector: collector, configuration: configuration)
    }
}

// MARK: - Protocol Extensions

/// Protocol for types that can be configured with metrics
public protocol MetricsConfigurable {
    /// Configures metrics collection with the provided middleware
    mutating func configureMetrics(_ middleware: MetricsMiddleware)
}

/// Protocol for types that can provide metric tags
public protocol MetricTagProvider {
    /// Provides custom tags for metrics
    var metricTags: [String: String] { get }
}

// MARK: - Command Extensions

public extension Command where Self: MetricTagProvider {
    /// Provides metric tags from the command itself
    func enrichMetricTags(_ tags: inout [String: String]) {
        tags.merge(metricTags) { _, new in new }
    }
}

// MARK: - Factory Methods

public struct MetricsMiddlewareFactory {
    /// Creates a metrics middleware optimized for high-throughput scenarios
    public static func highThroughput(
        collector: any MetricsCollector,
        namespace: String? = nil
    ) async -> MetricsMiddleware {
        // Use batched collector for better performance
        let batchedCollector = await BatchedMetricsCollector(
            underlying: collector,
            configuration: .highThroughput
        )
        
        return MetricsMiddlewareBuilder()
            .withCollector(batchedCollector)
            .withNamespace(namespace ?? "high_throughput")
            .basic() // Minimal overhead
            .build()!
    }
    
    /// Creates a metrics middleware for development/debugging
    public static func development(
        collector: any MetricsCollector
    ) -> MetricsMiddleware {
        return MetricsMiddlewareBuilder()
            .withCollector(collector)
            .withNamespace("dev")
            .comprehensive()
            .withTag("environment", value: "development")
            .build()!
    }
    
    /// Creates a metrics middleware for production environments
    public static func production(
        collector: any MetricsCollector,
        service: String,
        region: String? = nil
    ) -> MetricsMiddleware {
        var builder = MetricsMiddlewareBuilder()
            .withCollector(collector)
            .withNamespace("prod")
            .standard()
            .withTag("service", value: service)
            .withTag("environment", value: "production")
        
        if let region = region {
            builder = builder.withTag("region", value: region)
        }
        
        return builder.build()!
    }
    
    /// Creates a metrics middleware for testing
    public static func testing(
        collector: any MetricsCollector
    ) -> MetricsMiddleware {
        return MetricsMiddlewareBuilder()
            .withCollector(collector)
            .withNamespace("test")
            .minimal()
            .withTag("environment", value: "test")
            .build()!
    }
}

// MARK: - DSL Support

@resultBuilder
public struct MetricsConfigurationDSL {
    public static func buildBlock(_ components: MetricsConfigurationComponent...) -> [MetricsConfigurationComponent] {
        components
    }
}

public protocol MetricsConfigurationComponent {
    func apply(to builder: inout MetricsMiddlewareBuilder)
}

public struct NamespaceComponent: MetricsConfigurationComponent {
    let namespace: String
    
    public func apply(to builder: inout MetricsMiddlewareBuilder) {
        builder = builder.withNamespace(namespace)
    }
}

public struct TagsComponent: MetricsConfigurationComponent {
    let tags: [String: String]
    
    public func apply(to builder: inout MetricsMiddlewareBuilder) {
        builder = builder.withTags(tags)
    }
}

public struct PresetComponent: MetricsConfigurationComponent {
    let preset: (MetricsMiddlewareBuilder) -> MetricsMiddlewareBuilder
    
    public func apply(to builder: inout MetricsMiddlewareBuilder) {
        builder = preset(builder)
    }
}

// DSL convenience functions
public func namespace(_ value: String) -> MetricsConfigurationComponent {
    NamespaceComponent(namespace: value)
}

public func tags(_ tags: [String: String]) -> MetricsConfigurationComponent {
    TagsComponent(tags: tags)
}

public func tag(_ key: String, _ value: String) -> MetricsConfigurationComponent {
    TagsComponent(tags: [key: value])
}

public func minimal() -> MetricsConfigurationComponent {
    PresetComponent { $0.minimal() }
}

public func comprehensive() -> MetricsConfigurationComponent {
    PresetComponent { $0.comprehensive() }
}

// Example of DSL usage:
// let middleware = MetricsMiddleware {
//     namespace("api")
//     tag("service", "user-service")
//     tag("version", "2.0")
//     comprehensive()
// }