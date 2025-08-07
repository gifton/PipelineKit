import Foundation
import PipelineKitCore

/// Unified metrics middleware that provides comprehensive metrics collection for pipeline execution.
///
/// This middleware replaces both SimpleMetricsMiddleware and the previous MetricsMiddleware,
/// providing a single solution that can be configured for different use cases.
///
/// ## Features
/// - Automatic command duration tracking
/// - Success/failure rate monitoring
/// - Custom metric injection
/// - Tag enrichment from context
/// - Support for both simple and advanced configurations
///
/// ## Usage Examples
///
/// ### Simple Usage (Closure-based)
/// ```swift
/// let middleware = MetricsMiddleware.simple { name, duration in
///     print("Command \(name) took \(duration)s")
/// }
/// ```
///
/// ### Standard Usage (Collector-based)
/// ```swift
/// let collector = StandardMetricsCollector()
/// let middleware = MetricsMiddleware(collector: collector)
/// ```
///
/// ### Advanced Usage (Full Configuration)
/// ```swift
/// let middleware = MetricsMiddleware(
///     collector: collector,
///     configuration: MetricsMiddleware.Configuration(
///         namespace: "api",
///         includeCommandType: true,
///         trackErrors: true,
///         customTags: ["service": "user-api", "version": "2.0"]
///     )
/// )
/// ```
public struct MetricsMiddleware: Middleware {
    public let priority: ExecutionPriority = .postProcessing
    
    // MARK: - Configuration
    
    public struct Configuration: Sendable {
        /// Namespace prefix for all metric names
        public let namespace: String?
        
        /// Whether to include command type as a tag
        public let includeCommandType: Bool
        
        /// Whether to track error metrics separately
        public let trackErrors: Bool
        
        /// Whether to track custom context metrics
        public let trackContextMetrics: Bool
        
        /// Custom tags to add to all metrics
        public let customTags: [String: String]
        
        /// Whether to record histograms for command duration
        public let recordDurationHistogram: Bool
        
        /// Whether to increment counters for command execution
        public let recordExecutionCounter: Bool
        
        /// Metric name patterns
        public let metricNames: MetricNames
        
        public init(
            namespace: String? = nil,
            includeCommandType: Bool = true,
            trackErrors: Bool = true,
            trackContextMetrics: Bool = true,
            customTags: [String: String] = [:],
            recordDurationHistogram: Bool = true,
            recordExecutionCounter: Bool = true,
            metricNames: MetricNames = .default
        ) {
            self.namespace = namespace
            self.includeCommandType = includeCommandType
            self.trackErrors = trackErrors
            self.trackContextMetrics = trackContextMetrics
            self.customTags = customTags
            self.recordDurationHistogram = recordDurationHistogram
            self.recordExecutionCounter = recordExecutionCounter
            self.metricNames = metricNames
        }
        
        /// Simple configuration for basic metrics
        public static let simple = Configuration(
            trackContextMetrics: false,
            recordDurationHistogram: false,
            recordExecutionCounter: true
        )
        
        /// Standard configuration with reasonable defaults
        public static let standard = Configuration()
        
        /// Advanced configuration with all features enabled
        public static let advanced = Configuration(
            trackContextMetrics: true,
            recordDurationHistogram: true,
            recordExecutionCounter: true
        )
    }
    
    public struct MetricNames: Sendable {
        public let commandDuration: String
        public let commandCounter: String
        public let commandSuccess: String
        public let commandFailure: String
        public let commandError: String
        
        public init(
            commandDuration: String = "command.duration",
            commandCounter: String = "command.total",
            commandSuccess: String = "command.success",
            commandFailure: String = "command.failure",
            commandError: String = "command.error"
        ) {
            self.commandDuration = commandDuration
            self.commandCounter = commandCounter
            self.commandSuccess = commandSuccess
            self.commandFailure = commandFailure
            self.commandError = commandError
        }
        
        public static let `default` = MetricNames()
    }
    
    // MARK: - Properties
    
    private let mode: Mode
    private let configuration: Configuration
    
    // MARK: - Mode
    
    private enum Mode {
        case simple(recorder: @Sendable (String, TimeInterval) async -> Void)
        case collector(collector: any MetricsCollector)
    }
    
    // MARK: - Initialization
    
    /// Creates a metrics middleware with a collector and configuration
    public init(
        collector: any MetricsCollector,
        configuration: Configuration = .standard
    ) {
        self.mode = .collector(collector: collector)
        self.configuration = configuration
    }
    
    /// Creates a simple metrics middleware with a closure
    public static func simple(
        recordMetric: @escaping @Sendable (String, TimeInterval) async -> Void
    ) -> MetricsMiddleware {
        return MetricsMiddleware(
            mode: .simple(recorder: recordMetric),
            configuration: .simple
        )
    }
    
    /// Private initializer for mode
    private init(mode: Mode, configuration: Configuration) {
        self.mode = mode
        self.configuration = configuration
    }
    
    // MARK: - Middleware Implementation
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        let commandType = String(describing: type(of: command))
        
        // Build tags
        let tags = buildTags(for: command, context: context)
        
        // Record command start
        if configuration.recordExecutionCounter {
            await recordCounter(
                name: configuration.metricNames.commandCounter,
                tags: tags
            )
        }
        
        do {
            // Execute command
            let result = try await next(command, context)
            
            // Record success metrics
            let duration = Date().timeIntervalSince(startTime)
            await recordSuccessMetrics(
                commandType: commandType,
                duration: duration,
                tags: tags,
                context: context
            )
            
            return result
        } catch {
            // Record failure metrics
            let duration = Date().timeIntervalSince(startTime)
            await recordFailureMetrics(
                commandType: commandType,
                duration: duration,
                error: error,
                tags: tags,
                context: context
            )
            
            throw error
        }
    }
    
    // MARK: - Private Methods
    
    private func buildTags<T: Command>(
        for command: T,
        context: CommandContext
    ) -> [String: String] {
        var tags = configuration.customTags
        
        if configuration.includeCommandType {
            tags["command_type"] = String(describing: type(of: command))
        }
        
        // Add context tags if available
        if configuration.trackContextMetrics {
            if let userId = context.commandMetadata.userId {
                tags["user_id"] = userId
            }
            
            if let correlationId = context.commandMetadata.correlationId {
                tags["correlation_id"] = correlationId
            }
            
            // Add custom context tags
            if let contextTags = context.metadata["metrics.tags"] as? [String: String] {
                tags.merge(contextTags) { _, new in new }
            }
        }
        
        return tags
    }
    
    private func recordSuccessMetrics(
        commandType: String,
        duration: TimeInterval,
        tags: [String: String],
        context: CommandContext
    ) async {
        // Record duration
        await recordDuration(
            name: configuration.metricNames.commandDuration,
            duration: duration,
            tags: tags
        )
        
        // Record success counter
        if configuration.recordExecutionCounter {
            await recordCounter(
                name: configuration.metricNames.commandSuccess,
                tags: tags
            )
        }
        
        // Store metrics in context for downstream use
        if configuration.trackContextMetrics {
            context.metadata["metrics.duration"] = duration
            context.metadata["metrics.success"] = true
        }
    }
    
    private func recordFailureMetrics(
        commandType: String,
        duration: TimeInterval,
        error: Error,
        tags: [String: String],
        context: CommandContext
    ) async {
        // Add error information to tags
        var errorTags = tags
        if configuration.trackErrors {
            errorTags["error_type"] = String(describing: type(of: error))
            
            // Add specific error details for known error types
            if let pipelineError = error as? PipelineError {
                errorTags["error_code"] = pipelineError.errorCode
            }
        }
        
        // Record duration (even for failures)
        await recordDuration(
            name: configuration.metricNames.commandDuration,
            duration: duration,
            tags: errorTags
        )
        
        // Record failure counter
        if configuration.recordExecutionCounter {
            await recordCounter(
                name: configuration.metricNames.commandFailure,
                tags: errorTags
            )
            
            // Record specific error counter
            if configuration.trackErrors {
                await recordCounter(
                    name: configuration.metricNames.commandError,
                    tags: errorTags
                )
            }
        }
        
        // Store metrics in context
        if configuration.trackContextMetrics {
            context.metadata["metrics.duration"] = duration
            context.metadata["metrics.success"] = false
            context.metadata["metrics.error"] = String(describing: error)
        }
    }
    
    private func recordDuration(
        name: String,
        duration: TimeInterval,
        tags: [String: String]
    ) async {
        let metricName = prefixedName(name)
        
        switch mode {
        case .simple(let recorder):
            // For simple mode, just call the recorder with command type
            let commandType = tags["command_type"] ?? "unknown"
            await recorder(commandType, duration)
            
        case .collector(let collector):
            // Record as timer
            await collector.recordTimer(metricName, duration: duration, tags: tags)
            
            // Also record as histogram if configured
            if configuration.recordDurationHistogram {
                await collector.recordHistogram(metricName, value: duration, tags: tags)
            }
        }
    }
    
    private func recordCounter(
        name: String,
        value: Double = 1.0,
        tags: [String: String]
    ) async {
        let metricName = prefixedName(name)
        
        switch mode {
        case .simple:
            // Simple mode only tracks duration, not counters
            break
            
        case .collector(let collector):
            await collector.recordCounter(metricName, value: value, tags: tags)
        }
    }
    
    private func prefixedName(_ name: String) -> String {
        if let namespace = configuration.namespace {
            return "\(namespace).\(name)"
        }
        return name
    }
}

// MARK: - PipelineError Extension

private extension PipelineError {
    var errorCode: String {
        switch self {
        case .handlerNotFound:
            return "handler_not_found"
        case .executionFailed:
            return "execution_failed"
        case .middlewareError:
            return "middleware_error"
        case .maxDepthExceeded:
            return "max_depth_exceeded"
        case .timeout:
            return "timeout"
        case .retryExhausted:
            return "retry_exhausted"
        case .contextMissing:
            return "context_missing"
        case .pipelineNotConfigured:
            return "pipeline_not_configured"
        case .cancelled:
            return "cancelled"
        case .validation:
            return "validation_failed"
        case .authorization:
            return "authorization_failed"
        case .securityPolicy:
            return "security_policy_violation"
        case .encryption:
            return "encryption_error"
        case .rateLimitExceeded:
            return "rate_limit_exceeded"
        case .cache:
            return "cache_error"
        case .parallelExecutionFailed:
            return "parallel_execution_failed"
        case .context:
            return "context_error"
        case .circuitBreakerOpen:
            return "circuit_breaker_open"
        case .authentication:
            return "authentication_failed"
        case .resource:
            return "resource_error"
        case .resilience:
            return "resilience_error"
        case .observer:
            return "observer_error"
        case .optimization:
            return "optimization_error"
        case .export:
            return "export_error"
        case .test:
            return "test_error"
        case .backPressure:
            return "back_pressure"
        case .simulation:
            return "simulation_error"
        case .wrapped:
            return "wrapped_error"
        }
    }
}

// MARK: - Builder Extensions

public extension MetricsMiddleware {
    /// Creates a metrics middleware with a namespace
    static func withNamespace(
        _ namespace: String,
        collector: any MetricsCollector
    ) -> MetricsMiddleware {
        return MetricsMiddleware(
            collector: collector,
            configuration: Configuration(namespace: namespace)
        )
    }
    
    /// Creates a metrics middleware for API endpoints
    static func forAPI(
        collector: any MetricsCollector,
        serviceName: String,
        version: String = "1.0"
    ) -> MetricsMiddleware {
        return MetricsMiddleware(
            collector: collector,
            configuration: Configuration(
                namespace: "api",
                customTags: [
                    "service": serviceName,
                    "version": version
                ]
            )
        )
    }
    
    /// Creates a metrics middleware for background jobs
    static func forBackgroundJobs(
        collector: any MetricsCollector,
        jobType: String
    ) -> MetricsMiddleware {
        return MetricsMiddleware(
            collector: collector,
            configuration: Configuration(
                namespace: "jobs",
                customTags: ["job_type": jobType],
                metricNames: MetricNames(
                    commandDuration: "job.duration",
                    commandCounter: "job.total",
                    commandSuccess: "job.success",
                    commandFailure: "job.failure",
                    commandError: "job.error"
                )
            )
        )
    }
}