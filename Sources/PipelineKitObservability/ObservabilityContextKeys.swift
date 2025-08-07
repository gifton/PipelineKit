import Foundation
import PipelineKitCore

/// Type-safe keys for observability data in CommandContext
public enum ObservabilityContextKeys {
    // MARK: - Core Observability
    
    /// Distributed tracing span context
    public static let spanContext = ContextKey<SpanContext>("observability.spanContext")
    
    /// Performance measurement context
    public static let performanceContext = ContextKey<PerformanceContext>("observability.performanceContext")
    
    /// Generic observability data storage
    public static let observabilityData = ContextKey<[String: any Sendable]>("observability.data")
    
    /// Observer registry for pipeline observers
    public static let observerRegistry = ContextKey<ObserverRegistry>("observability.registry")
    
    // MARK: - Event System
    
    /// Custom events emitted during execution
    public static let customEvents = ContextKey<[ObservabilityEvent]>("observability.events")
    
    /// Event buffer for batching
    public static let eventBuffer = ContextKey<EventBuffer>("observability.eventBuffer")
    
    // MARK: - Performance Tracking
    
    /// Active performance measurements
    public static let activeMeasurements = ContextKey<[String: PerformanceMeasurement]>("observability.measurements")
    
    /// Performance thresholds for alerting
    public static let performanceThresholds = ContextKey<PerformanceThresholds>("observability.thresholds")
    
    // MARK: - Metrics
    
    // Note: StandardMetricsCollector is internal, so we can't expose it publicly
    // Users should use the metrics methods on CommandContext instead
    
    /// Current metric values
    public static let currentMetrics = ContextKey<[String: Double]>("observability.currentMetrics")
}

// MARK: - Event System Types

/// Represents an observability event
public struct ObservabilityEvent: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let timestamp: Date
    public let properties: [String: any Sendable]
    public let severity: EventSeverity
    
    public init(
        id: UUID = UUID(),
        name: String,
        timestamp: Date = Date(),
        properties: [String: any Sendable] = [:],
        severity: EventSeverity = .info
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.properties = properties
        self.severity = severity
    }
    
    public static func == (lhs: ObservabilityEvent, rhs: ObservabilityEvent) -> Bool {
        lhs.id == rhs.id
    }
}

/// Event severity levels
public enum EventSeverity: String, Sendable {
    case debug
    case info
    case warning
    case error
    case critical
}

/// Event buffer for batching events
public struct EventBuffer: Sendable {
    public var events: [ObservabilityEvent]
    public let maxSize: Int
    public let flushInterval: TimeInterval
    public var lastFlush: Date
    
    public init(
        maxSize: Int = 1000,
        flushInterval: TimeInterval = 30.0
    ) {
        self.events = []
        self.maxSize = maxSize
        self.flushInterval = flushInterval
        self.lastFlush = Date()
    }
    
    public mutating func append(_ event: ObservabilityEvent) {
        events.append(event)
        if events.count > maxSize {
            events.removeFirst()
        }
    }
    
    public mutating func flush() -> [ObservabilityEvent] {
        let flushed = events
        events.removeAll(keepingCapacity: true)
        lastFlush = Date()
        return flushed
    }
    
    public var shouldFlush: Bool {
        events.count >= maxSize || 
        Date().timeIntervalSince(lastFlush) > flushInterval
    }
}