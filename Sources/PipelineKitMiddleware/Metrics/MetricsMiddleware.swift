import Foundation
import PipelineKitCore

/// Simple metrics middleware using a closure-based approach.
/// For more advanced metrics collection, use AdvancedMetricsMiddleware.
public struct SimpleMetricsMiddleware: Middleware {
    public let priority: ExecutionPriority = .postProcessing // Metrics collection happens after processing
    private let recordMetric: @Sendable (String, TimeInterval) async -> Void

    public init(recordMetric: @escaping @Sendable (String, TimeInterval) async -> Void) {
        self.recordMetric = recordMetric
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = context[RequestStartTimeKey.self] ?? Date()

        do {
            let result = try await next(command, context)

            let duration = Date().timeIntervalSince(startTime)
            await recordMetric(String(describing: T.self), duration)

            return result
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            await recordMetric("\(String(describing: T.self)).error", duration)
            throw error
        }
    }
}

/// Advanced metrics middleware for comprehensive metrics collection.
///
/// This middleware tracks execution time, success/failure rates, and custom metrics
/// for commands passing through the pipeline. Unlike SimpleMetricsMiddleware,
/// this version provides full-featured metrics collection with tags and namespaces.
///
/// ## Example Usage
/// ```swift
/// let collector = StandardMetricsCollector()
/// let middleware = MetricsMiddleware(
///     collector: collector,
///     namespace: "api",
///     includeCommandType: true
/// )
/// ```
///
/// ## Design Decision: @unchecked Sendable for Existential Types
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Existential Type Limitation**: The stored property `collector: any AdvancedMetricsCollector`
///    uses an existential type. Swift currently cannot verify Sendable conformance through
///    existential types, even though the protocol requires Sendable.
///
/// 2. **All Properties Are Safe**:
///    - `collector`: Protocol requires Sendable conformance
///    - `namespace`: String? (inherently Sendable)
///    - `includeCommandType`: Bool (inherently Sendable)
///    - `customTags`: [String: String] (inherently Sendable)
///    - All closures are marked @Sendable
///
/// 3. **Guaranteed Thread Safety**: Since AdvancedMetricsCollector protocol explicitly
///    requires Sendable, any conforming type must be thread-safe, making this usage safe.
///
/// 4. **No Mutable State**: All properties are `let` constants, preventing any mutations
///    after initialization.
///
/// This is a Swift language limitation rather than a design choice. Once Swift improves
/// existential type handling, the @unchecked annotation can be removed.
public final class MetricsMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .postProcessing
    
    private let collector: any AdvancedMetricsCollector
    private let namespace: String?
    private let includeCommandType: Bool
    private let customTags: [String: String]
    
    /// Creates a metrics middleware with the specified configuration.
    ///
    /// - Parameters:
    ///   - collector: The metrics collector to use
    ///   - namespace: Optional namespace prefix for all metrics
    ///   - includeCommandType: Whether to include command type in metric tags
    ///   - customTags: Additional tags to include with all metrics
    public init(
        collector: any AdvancedMetricsCollector,
        namespace: String? = nil,
        includeCommandType: Bool = true,
        customTags: [String: String] = [:]
    ) {
        self.collector = collector
        self.namespace = namespace
        self.includeCommandType = includeCommandType
        self.customTags = customTags
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        let metricPrefix = namespace.map { "\($0)." } ?? ""
        
        // Build tags for this execution
        var tags = customTags
        if includeCommandType {
            tags["command"] = String(describing: type(of: command))
        }
        
        // Track active requests
        await collector.incrementCounter(
            "\(metricPrefix)requests.active",
            tags: tags
        )
        
        defer {
            // Decrement active requests
            let finalTags = tags
            Task {
                await collector.incrementCounter(
                    "\(metricPrefix)requests.active",
                    value: -1,
                    tags: finalTags
                )
            }
        }
        
        do {
            // Execute the command
            let result = try await next(command, context)
            
            // Record success metrics
            let duration = Date().timeIntervalSince(startTime)
            
            await collector.incrementCounter(
                "\(metricPrefix)requests.success",
                tags: tags
            )
            
            await collector.recordLatency(
                "\(metricPrefix)requests.duration",
                value: duration,
                tags: tags
            )
            
            // Record command-specific metrics if available
            if let metricsProvider = command as? MetricsProvider {
                let commandMetrics = metricsProvider.metrics
                for (key, value) in commandMetrics {
                    await collector.recordGauge(
                        "\(metricPrefix)command.\(key)",
                        value: value,
                        tags: tags
                    )
                }
            }
            
            return result
            
        } catch {
            // Record failure metrics
            let duration = Date().timeIntervalSince(startTime)
            
            var errorTags = tags
            errorTags["error"] = String(describing: type(of: error))
            
            await collector.incrementCounter(
                "\(metricPrefix)requests.failure",
                tags: errorTags
            )
            
            await collector.recordLatency(
                "\(metricPrefix)requests.duration",
                value: duration,
                tags: errorTags
            )
            
            throw error
        }
    }
}

// MARK: - Advanced Metrics Collector Protocol

/// Protocol for advanced metrics collection backends.
public protocol AdvancedMetricsCollector: Sendable {
    /// Records a latency measurement (typically in seconds).
    func recordLatency(_ name: String, value: TimeInterval, tags: [String: String]) async
    
    /// Increments a counter by the specified value (default: 1).
    func incrementCounter(_ name: String, value: Double, tags: [String: String]) async
    
    /// Records a gauge value (point-in-time measurement).
    func recordGauge(_ name: String, value: Double, tags: [String: String]) async
}

// Default implementations with default parameter values
public extension AdvancedMetricsCollector {
    func recordLatency(_ name: String, value: TimeInterval, tags: [String: String] = [:]) async {
        await recordLatency(name, value: value, tags: tags)
    }
    
    func incrementCounter(_ name: String, tags: [String: String] = [:]) async {
        await incrementCounter(name, value: 1, tags: tags)
    }
    
    func incrementCounter(_ name: String, value: Double = 1, tags: [String: String] = [:]) async {
        await incrementCounter(name, value: value, tags: tags)
    }
    
    func recordGauge(_ name: String, value: Double, tags: [String: String] = [:]) async {
        await recordGauge(name, value: value, tags: tags)
    }
}

// MARK: - Standard Metrics Collector

/// Advanced in-memory metrics collector for development and testing.
actor StandardAdvancedMetricsCollector: AdvancedMetricsCollector {
    struct Metric: Sendable {
        let name: String
        let value: Double
        let type: MetricType
        let tags: [String: String]
        let timestamp: Date
    }
    
    enum MetricType: Sendable {
        case counter
        case gauge
        case latency
    }
    
    private var metrics: [Metric] = []
    private var counters: [String: Double] = [:]
    private let maxMetrics: Int
    
    init(maxMetrics: Int = 10000) {
        self.maxMetrics = maxMetrics
    }
    
    func recordLatency(_ name: String, value: TimeInterval, tags: [String: String]) {
        addMetric(Metric(
            name: name,
            value: value,
            type: .latency,
            tags: tags,
            timestamp: Date()
        ))
    }
    
    func incrementCounter(_ name: String, value: Double, tags: [String: String]) {
        let key = "\(name)-\(tags.sorted(by: { $0.key < $1.key }).description)"
        counters[key, default: 0] += value
        
        addMetric(Metric(
            name: name,
            value: counters[key]!,
            type: .counter,
            tags: tags,
            timestamp: Date()
        ))
    }
    
    func recordGauge(_ name: String, value: Double, tags: [String: String]) {
        addMetric(Metric(
            name: name,
            value: value,
            type: .gauge,
            tags: tags,
            timestamp: Date()
        ))
    }
    
    private func addMetric(_ metric: Metric) {
        metrics.append(metric)
        
        // Evict old metrics if we exceed the limit
        if metrics.count > maxMetrics {
            metrics.removeFirst(metrics.count - maxMetrics)
        }
    }
    
    /// Gets all recorded metrics.
    func getMetrics() -> [Metric] {
        metrics
    }
    
    /// Gets metrics filtered by name and/or type.
    func getMetrics(
        name: String? = nil,
        type: MetricType? = nil,
        since: Date? = nil
    ) -> [Metric] {
        metrics.filter { metric in
            if let name = name, !metric.name.contains(name) {
                return false
            }
            if let type = type, metric.type != type {
                return false
            }
            if let since = since, metric.timestamp < since {
                return false
            }
            return true
        }
    }
    
    /// Clears all recorded metrics.
    func clear() {
        metrics.removeAll()
        counters.removeAll()
    }
}

// MARK: - Metrics Provider Protocol

/// Protocol for commands that want to provide custom metrics.
public protocol MetricsProvider {
    /// Custom metrics to record for this command.
    var metrics: [String: Double] { get }
}

// MARK: - Convenience Extensions

public extension MetricsMiddleware {
    /// Creates a metrics middleware with a simple configuration.
    convenience init(collector: any AdvancedMetricsCollector) {
        self.init(
            collector: collector,
            namespace: nil,
            includeCommandType: true,
            customTags: [:]
        )
    }
    
    /// Creates a metrics middleware with a namespace.
    convenience init(
        collector: any AdvancedMetricsCollector,
        namespace: String
    ) {
        self.init(
            collector: collector,
            namespace: namespace,
            includeCommandType: true,
            customTags: [:]
        )
    }
}
