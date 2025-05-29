import Foundation

/// Protocol for integrating with external metrics systems
public protocol MetricsBackend: Sendable {
    /// Record a counter metric (increments by 1)
    func recordCounter(name: String, tags: [String: String]) async
    
    /// Record a gauge metric (current value)
    func recordGauge(name: String, value: Double, tags: [String: String]) async
    
    /// Record a histogram metric (distribution of values)
    func recordHistogram(name: String, value: Double, tags: [String: String]) async
}

/// An observer that collects and reports metrics about pipeline execution
/// Can be integrated with various metrics backends like StatsD, Prometheus, etc.
public actor MetricsObserver: PipelineObserver {
    
    /// Configuration for the metrics observer
    public struct Configuration: Sendable {
        /// Prefix for all metric names
        public let metricPrefix: String
        
        /// Whether to include command type as a tag
        public let includeCommandType: Bool
        
        /// Whether to include pipeline type as a tag
        public let includePipelineType: Bool
        
        /// Whether to track middleware metrics
        public let trackMiddleware: Bool
        
        /// Whether to track handler metrics
        public let trackHandlers: Bool
        
        /// Custom tags to include with all metrics
        public let globalTags: [String: String]
        
        public init(
            metricPrefix: String = "pipeline",
            includeCommandType: Bool = true,
            includePipelineType: Bool = true,
            trackMiddleware: Bool = false,
            trackHandlers: Bool = false,
            globalTags: [String: String] = [:]
        ) {
            self.metricPrefix = metricPrefix
            self.includeCommandType = includeCommandType
            self.includePipelineType = includePipelineType
            self.trackMiddleware = trackMiddleware
            self.trackHandlers = trackHandlers
            self.globalTags = globalTags
        }
    }
    
    private let backend: MetricsBackend
    private let configuration: Configuration
    private var activePipelines: [String: Date] = [:] // correlationId -> start time
    private var activeMiddleware: [String: Date] = [:] // key -> start time
    private var activeHandlers: [String: Date] = [:] // key -> start time
    
    public init(backend: MetricsBackend, configuration: Configuration = Configuration()) {
        self.backend = backend
        self.configuration = configuration
    }
    
    // MARK: - Pipeline Events
    
    public func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        let correlationId = metadata.correlationId ?? UUID().uuidString
        activePipelines[correlationId] = Date()
        
        var tags = configuration.globalTags
        if configuration.includeCommandType {
            tags["command"] = String(describing: type(of: command))
        }
        if configuration.includePipelineType {
            tags["pipeline"] = pipelineType
        }
        
        await backend.recordCounter(
            name: "\(configuration.metricPrefix).started",
            tags: tags
        )
        
        // Record active pipelines gauge
        await backend.recordGauge(
            name: "\(configuration.metricPrefix).active",
            value: Double(activePipelines.count),
            tags: configuration.globalTags
        )
    }
    
    public func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        let correlationId = metadata.correlationId ?? UUID().uuidString
        activePipelines.removeValue(forKey: correlationId)
        
        var tags = configuration.globalTags
        tags["status"] = "success"
        if configuration.includeCommandType {
            tags["command"] = String(describing: type(of: command))
        }
        if configuration.includePipelineType {
            tags["pipeline"] = pipelineType
        }
        
        // Record completion
        await backend.recordCounter(
            name: "\(configuration.metricPrefix).completed",
            tags: tags
        )
        
        // Record duration
        await backend.recordHistogram(
            name: "\(configuration.metricPrefix).duration_ms",
            value: duration * 1000,
            tags: tags
        )
        
        // Update active gauge
        await backend.recordGauge(
            name: "\(configuration.metricPrefix).active",
            value: Double(activePipelines.count),
            tags: configuration.globalTags
        )
    }
    
    public func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        let correlationId = metadata.correlationId ?? UUID().uuidString
        activePipelines.removeValue(forKey: correlationId)
        
        var tags = configuration.globalTags
        tags["status"] = "failed"
        tags["error_type"] = String(describing: type(of: error))
        if configuration.includeCommandType {
            tags["command"] = String(describing: type(of: command))
        }
        if configuration.includePipelineType {
            tags["pipeline"] = pipelineType
        }
        
        // Record failure
        await backend.recordCounter(
            name: "\(configuration.metricPrefix).failed",
            tags: tags
        )
        
        // Record duration even for failures
        await backend.recordHistogram(
            name: "\(configuration.metricPrefix).duration_ms",
            value: duration * 1000,
            tags: tags
        )
        
        // Update active gauge
        await backend.recordGauge(
            name: "\(configuration.metricPrefix).active",
            value: Double(activePipelines.count),
            tags: configuration.globalTags
        )
    }
    
    // MARK: - Middleware Events
    
    public func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
        guard configuration.trackMiddleware else { return }
        
        let key = "\(correlationId):\(middlewareName)"
        activeMiddleware[key] = Date()
        
        var tags = configuration.globalTags
        tags["middleware"] = middlewareName
        tags["order"] = String(order)
        
        await backend.recordCounter(
            name: "\(configuration.metricPrefix).middleware.started",
            tags: tags
        )
    }
    
    public func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        guard configuration.trackMiddleware else { return }
        
        let key = "\(correlationId):\(middlewareName)"
        activeMiddleware.removeValue(forKey: key)
        
        var tags = configuration.globalTags
        tags["middleware"] = middlewareName
        tags["order"] = String(order)
        tags["status"] = "success"
        
        await backend.recordHistogram(
            name: "\(configuration.metricPrefix).middleware.duration_ms",
            value: duration * 1000,
            tags: tags
        )
    }
    
    public func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        guard configuration.trackMiddleware else { return }
        
        let key = "\(correlationId):\(middlewareName)"
        activeMiddleware.removeValue(forKey: key)
        
        var tags = configuration.globalTags
        tags["middleware"] = middlewareName
        tags["order"] = String(order)
        tags["status"] = "failed"
        tags["error_type"] = String(describing: type(of: error))
        
        await backend.recordCounter(
            name: "\(configuration.metricPrefix).middleware.failed",
            tags: tags
        )
        
        await backend.recordHistogram(
            name: "\(configuration.metricPrefix).middleware.duration_ms",
            value: duration * 1000,
            tags: tags
        )
    }
    
    // MARK: - Handler Events
    
    public func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
        guard configuration.trackHandlers else { return }
        
        let key = "\(correlationId):\(handlerType)"
        activeHandlers[key] = Date()
        
        var tags = configuration.globalTags
        tags["handler"] = handlerType
        tags["command"] = String(describing: type(of: command))
        
        await backend.recordCounter(
            name: "\(configuration.metricPrefix).handler.started",
            tags: tags
        )
    }
    
    public func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
        guard configuration.trackHandlers else { return }
        
        let key = "\(correlationId):\(handlerType)"
        activeHandlers.removeValue(forKey: key)
        
        var tags = configuration.globalTags
        tags["handler"] = handlerType
        tags["command"] = String(describing: type(of: command))
        tags["status"] = "success"
        
        await backend.recordHistogram(
            name: "\(configuration.metricPrefix).handler.duration_ms",
            value: duration * 1000,
            tags: tags
        )
    }
    
    public func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
        guard configuration.trackHandlers else { return }
        
        let key = "\(correlationId):\(handlerType)"
        activeHandlers.removeValue(forKey: key)
        
        var tags = configuration.globalTags
        tags["handler"] = handlerType
        tags["command"] = String(describing: type(of: command))
        tags["status"] = "failed"
        tags["error_type"] = String(describing: type(of: error))
        
        await backend.recordCounter(
            name: "\(configuration.metricPrefix).handler.failed",
            tags: tags
        )
        
        await backend.recordHistogram(
            name: "\(configuration.metricPrefix).handler.duration_ms",
            value: duration * 1000,
            tags: tags
        )
    }
    
    // MARK: - Custom Events
    
    public func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        var tags = configuration.globalTags
        tags["event"] = eventName
        
        // Add numeric properties as gauge metrics
        for (key, value) in properties {
            if let numericValue = value as? Double {
                await backend.recordGauge(
                    name: "\(configuration.metricPrefix).custom.\(eventName).\(key)",
                    value: numericValue,
                    tags: tags
                )
            } else if let numericValue = value as? Int {
                await backend.recordGauge(
                    name: "\(configuration.metricPrefix).custom.\(eventName).\(key)",
                    value: Double(numericValue),
                    tags: tags
                )
            }
        }
        
        // Record event occurrence
        await backend.recordCounter(
            name: "\(configuration.metricPrefix).custom.\(eventName)",
            tags: tags
        )
    }
}

// MARK: - Built-in Metrics Backends

/// A simple in-memory metrics backend for testing
public actor InMemoryMetricsBackend: MetricsBackend {
    public struct Metric: Sendable {
        public let name: String
        public let type: MetricType
        public let value: Double
        public let tags: [String: String]
        public let timestamp: Date
        
        public enum MetricType: Sendable {
            case counter
            case gauge
            case histogram
        }
    }
    
    private var metrics: [Metric] = []
    
    public init() {}
    
    public func recordCounter(name: String, tags: [String: String]) async {
        metrics.append(Metric(
            name: name,
            type: .counter,
            value: 1,
            tags: tags,
            timestamp: Date()
        ))
    }
    
    public func recordGauge(name: String, value: Double, tags: [String: String]) async {
        metrics.append(Metric(
            name: name,
            type: .gauge,
            value: value,
            tags: tags,
            timestamp: Date()
        ))
    }
    
    public func recordHistogram(name: String, value: Double, tags: [String: String]) async {
        metrics.append(Metric(
            name: name,
            type: .histogram,
            value: value,
            tags: tags,
            timestamp: Date()
        ))
    }
    
    public func allMetrics() -> [Metric] {
        return metrics
    }
    
    public func metrics(named: String) -> [Metric] {
        return metrics.filter { $0.name == named }
    }
    
    public func clear() {
        metrics.removeAll()
    }
}

/// A console logging metrics backend for development
public final class ConsoleMetricsBackend: MetricsBackend, @unchecked Sendable {
    private let dateFormatter: DateFormatter
    
    public init() {
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }
    
    public func recordCounter(name: String, tags: [String: String]) async {
        let tagsString = tags.isEmpty ? "" : " " + formatTags(tags)
        print("[\(dateFormatter.string(from: Date()))] METRIC counter \(name)\(tagsString) +1")
    }
    
    public func recordGauge(name: String, value: Double, tags: [String: String]) async {
        let tagsString = tags.isEmpty ? "" : " " + formatTags(tags)
        print("[\(dateFormatter.string(from: Date()))] METRIC gauge \(name)\(tagsString) = \(value)")
    }
    
    public func recordHistogram(name: String, value: Double, tags: [String: String]) async {
        let tagsString = tags.isEmpty ? "" : " " + formatTags(tags)
        print("[\(dateFormatter.string(from: Date()))] METRIC histogram \(name)\(tagsString) = \(value)")
    }
    
    private func formatTags(_ tags: [String: String]) -> String {
        return tags
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }
}