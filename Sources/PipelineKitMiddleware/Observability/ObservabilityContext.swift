import Foundation
import PipelineKitCore

// MARK: - Observability Context Keys

/// Context key for storing the current span/trace information
public struct SpanContextKey: ContextKey {
    public typealias Value = SpanContext
}

/// Context key for storing performance measurements
public struct PerformanceContextKey: ContextKey {
    public typealias Value = PerformanceContext
}

/// Context key for storing custom observability data
public struct ObservabilityDataKey: ContextKey {
    public typealias Value = [String: Sendable]
}

/// Context key for storing the observer registry
public struct ObserverRegistryKey: ContextKey {
    public typealias Value = ObserverRegistry
}

// MARK: - Span Context

/// Represents distributed tracing context information
public struct SpanContext: Sendable {
    public let traceId: String
    public let spanId: String
    public let parentSpanId: String?
    public let operation: String
    public let startTime: Date
    public var tags: [String: String]
    
    public init(
        traceId: String = UUID().uuidString,
        spanId: String = UUID().uuidString,
        parentSpanId: String? = nil,
        operation: String,
        startTime: Date = Date(),
        tags: [String: String] = [:]
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.operation = operation
        self.startTime = startTime
        self.tags = tags
    }
    
    /// Creates a child span from this span
    public func createChildSpan(operation: String, tags: [String: String] = [:]) -> SpanContext {
        return SpanContext(
            traceId: traceId,
            spanId: UUID().uuidString,
            parentSpanId: spanId,
            operation: operation,
            startTime: Date(),
            tags: tags
        )
    }
}

// MARK: - Performance Context

/// Tracks performance metrics during pipeline execution
public struct PerformanceContext: Sendable {
    public private(set) var metrics: [String: PerformanceMetric]
    public let startTime: Date
    
    public init(startTime: Date = Date()) {
        self.metrics = [:]
        self.startTime = startTime
    }
    
    public mutating func startTimer(_ name: String) {
        metrics[name] = PerformanceMetric(name: name, startTime: Date())
    }
    
    public mutating func endTimer(_ name: String) {
        guard var metric = metrics[name] else { return }
        metric.endTime = Date()
        metrics[name] = metric
    }
    
    public mutating func recordValue(_ name: String, value: Double, unit: String = "") {
        metrics[name] = PerformanceMetric(name: name, value: value, unit: unit)
    }
    
    public func getMetric(_ name: String) -> PerformanceMetric? {
        return metrics[name]
    }
    
    public func getAllMetrics() -> [PerformanceMetric] {
        return Array(metrics.values)
    }
}

public struct PerformanceMetric: Sendable {
    public let name: String
    public let startTime: Date?
    public var endTime: Date?
    public let value: Double?
    public let unit: String
    
    public init(name: String, startTime: Date? = nil, value: Double? = nil, unit: String = "") {
        self.name = name
        self.startTime = startTime
        self.value = value
        self.unit = unit
    }
    
    public var duration: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }
}

// MARK: - CommandContext Extensions

public extension CommandContext {
    /// Gets the current span context, creating one if it doesn't exist
    func getOrCreateSpanContext(operation: String) -> SpanContext {
        if let existing = self[SpanContextKey.self] {
            return existing
        }
        
        let newSpan = SpanContext(operation: operation)
        self.set(newSpan, for: SpanContextKey.self)
        return newSpan
    }
    
    /// Creates a child span for the given operation
    func createChildSpan(operation: String, tags: [String: String] = [:]) -> SpanContext {
        let parentSpan = getOrCreateSpanContext(operation: "parent")
        let childSpan = parentSpan.createChildSpan(operation: operation, tags: tags)
        
        // Store the child span as current
        self.set(childSpan, for: SpanContextKey.self)
        return childSpan
    }
    
    /// Gets or creates a performance context
    func getOrCreatePerformanceContext() -> PerformanceContext {
        if let existing = self[PerformanceContextKey.self] {
            return existing
        }
        
        let newContext = PerformanceContext()
        self.set(newContext, for: PerformanceContextKey.self)
        return newContext
    }
    
    /// Updates the performance context
    func updatePerformanceContext(_ context: PerformanceContext) {
        self.set(context, for: PerformanceContextKey.self)
    }
    
    /// Starts a performance timer
    func startTimer(_ name: String) {
        var context = getOrCreatePerformanceContext()
        context.startTimer(name)
        updatePerformanceContext(context)
    }
    
    /// Ends a performance timer
    func endTimer(_ name: String) {
        var context = getOrCreatePerformanceContext()
        context.endTimer(name)
        updatePerformanceContext(context)
    }
    
    /// Records a performance value
    func recordMetric(_ name: String, value: Double, unit: String = "") {
        var context = getOrCreatePerformanceContext()
        context.recordValue(name, value: value, unit: unit)
        updatePerformanceContext(context)
    }
    
    /// Gets or creates observability data dictionary
    func getOrCreateObservabilityData() -> [String: Sendable] {
        if let existing = self[ObservabilityDataKey.self] {
            return existing
        }
        
        let newData: [String: Sendable] = [:]
        self.set(newData, for: ObservabilityDataKey.self)
        return newData
    }
    
    /// Sets observability data
    func setObservabilityData(_ key: String, value: Sendable) {
        var data = getOrCreateObservabilityData()
        data[key] = value
        self.set(data, for: ObservabilityDataKey.self)
    }
    
    /// Gets observability data
    func getObservabilityData(_ key: String) -> Sendable? {
        let data = getOrCreateObservabilityData()
        return data[key]
    }
    
    /// Gets the observer registry from context
    func getObserverRegistry() -> ObserverRegistry? {
        return self[ObserverRegistryKey.self]
    }
    
    /// Sets the observer registry in context
    func setObserverRegistry(_ registry: ObserverRegistry) {
        self.set(registry, for: ObserverRegistryKey.self)
    }
    
    /// Emits a custom event using the observer registry
    func emitCustomEvent(_ eventName: String, properties: [String: Sendable] = [:]) async {
        guard let registry = getObserverRegistry() else { return }
        
        let span = getOrCreateSpanContext(operation: "custom_event")
        await registry.notifyCustomEvent(eventName, properties: properties, correlationId: span.traceId)
    }
}

// MARK: - Command Observability Extension

/// Extension for commands that want to emit custom observability events
public extension Command {
    /// Called when the command execution starts, allowing setup of observability context
    func setupObservability(context: CommandContext) async {
        // Default implementation does nothing
    }
    
    /// Called when the command execution completes successfully
    func observabilityDidComplete<Result>(context: CommandContext, result: Result) async {
        // Default implementation does nothing
    }
    
    /// Called when the command execution fails
    func observabilityDidFail(context: CommandContext, error: Error) async {
        // Default implementation does nothing
    }
}

// MARK: - Observability Utilities

/// Utility functions for working with observability
public enum ObservabilityUtils {
    /// Generates a correlation ID from metadata or creates a new one
    public static func extractCorrelationId(from metadata: CommandMetadata) -> String {
        return metadata.correlationId ?? UUID().uuidString
    }
    
    /// Extracts user ID from metadata for observability tagging
    public static func extractUserId(from metadata: CommandMetadata) -> String {
        return metadata.userId ?? "anonymous"
    }
    
    /// Creates observability tags from command metadata
    public static func createTagsFromMetadata(_ metadata: CommandMetadata) -> [String: String] {
        var tags: [String: String] = [:]
        
        if let userId = metadata.userId {
            tags["user_id"] = userId
        }
        if let correlationId = metadata.correlationId {
            tags["correlation_id"] = correlationId
        }
        tags["timestamp"] = ISO8601DateFormatter().string(from: metadata.timestamp)
        
        return tags
    }
    
    /// Sanitizes property values for safe logging
    public static func sanitizeProperties(_ properties: [String: Sendable]) -> [String: String] {
        return properties.compactMapValues { value in
            switch value {
            case let string as String:
                return string
            case let number as NSNumber:
                return number.stringValue
            case let bool as Bool:
                return bool.description
            default:
                return String(describing: value)
            }
        }
    }
}

// MARK: - Middleware Observability Extension

/// Extension for middleware that wants to participate in observability
public extension Middleware {
    /// The name used for observability tracking
    var observabilityName: String {
        return String(describing: type(of: self))
    }
    
    /// Custom tags to include in observability events
    var observabilityTags: [String: String] {
        return [:]
    }
}