import Foundation
import PipelineKitCore

// MARK: - Observability Context Storage Keys

// Import our typed keys
// Keys are now defined in ObservabilityContextKeys.swift

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
        if let existing = self[ObservabilityContextKeys.spanContext] {
            return existing
        }
        
        let newSpan = SpanContext(operation: operation)
        self[ObservabilityContextKeys.spanContext] = newSpan
        return newSpan
    }
    
    /// Creates a child span for the given operation
    func createChildSpan(operation: String, tags: [String: String] = [:]) -> SpanContext {
        let parentSpan = getOrCreateSpanContext(operation: "parent")
        let childSpan = parentSpan.createChildSpan(operation: operation, tags: tags)
        
        // Store the child span as current
        self[ObservabilityContextKeys.spanContext] = childSpan
        return childSpan
    }
    
    /// Gets or creates a performance context
    func getOrCreatePerformanceContext() -> PerformanceContext {
        if let existing = self[ObservabilityContextKeys.performanceContext] {
            return existing
        }
        
        let newContext = PerformanceContext()
        self[ObservabilityContextKeys.performanceContext] = newContext
        return newContext
    }
    
    /// Updates the performance context
    func updatePerformanceContext(_ context: PerformanceContext) {
        self[ObservabilityContextKeys.performanceContext] = context
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
    func recordPerformanceMetric(_ name: String, value: Double, unit: String = "") {
        var context = getOrCreatePerformanceContext()
        context.recordValue(name, value: value, unit: unit)
        updatePerformanceContext(context)
    }
    
    /// Gets or creates observability data dictionary
    func getOrCreateObservabilityData() -> [String: any Sendable] {
        if let existing = self[ObservabilityContextKeys.observabilityData] {
            return existing
        }
        
        let newData: [String: any Sendable] = [:]
        self[ObservabilityContextKeys.observabilityData] = newData
        return newData
    }
    
    /// Sets observability data
    func setObservabilityData(_ key: String, value: any Sendable) {
        var data = getOrCreateObservabilityData()
        data[key] = value
        self[ObservabilityContextKeys.observabilityData] = data
    }
    
    /// Gets observability data
    func getObservabilityData(_ key: String) -> (any Sendable)? {
        let data = getOrCreateObservabilityData()
        return data[key]
    }
    
    /// Gets the observer registry from context
    func getObserverRegistry() -> ObserverRegistry? {
        return self[ObservabilityContextKeys.observerRegistry]
    }
    
    /// Sets the observer registry in context
    func setObserverRegistry(_ registry: ObserverRegistry) {
        self[ObservabilityContextKeys.observerRegistry] = registry
    }
    
    /// Emits an observability event using the observer registry
    // MARK: - Event Emission
    
    /// Emits a custom event for observability
    func emitCustomEvent(
        _ name: String, 
        properties: [String: any Sendable] = [:],
        severity: EventSeverity = .info
    ) {
        let event = ObservabilityEvent(
            name: name,
            properties: properties,
            severity: severity
        )
        
        // Add to event buffer
        var buffer = self[ObservabilityContextKeys.eventBuffer] ?? EventBuffer()
        buffer.append(event)
        self[ObservabilityContextKeys.eventBuffer] = buffer
        
        // Also append to events array for immediate access
        var events = self[ObservabilityContextKeys.customEvents] ?? []
        events.append(event)
        self[ObservabilityContextKeys.customEvents] = events
        
        // Notify registry if available
        if let registry = getObserverRegistry() {
            let span = getOrCreateSpanContext(operation: "custom_event")
            Task {
                await registry.notifyCustomEvent(name, properties: properties, correlationId: span.traceId)
            }
        }
    }
    
    /// Gets all custom events
    func getCustomEvents() -> [ObservabilityEvent] {
        return self[ObservabilityContextKeys.customEvents] ?? []
    }
    
    /// Flushes the event buffer
    func flushEventBuffer() -> [ObservabilityEvent] {
        guard var buffer = self[ObservabilityContextKeys.eventBuffer] else {
            return []
        }
        
        let events = buffer.flush()
        self[ObservabilityContextKeys.eventBuffer] = buffer
        return events
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