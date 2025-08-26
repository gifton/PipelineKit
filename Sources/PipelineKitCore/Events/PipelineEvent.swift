//
//  PipelineEvent.swift
//  PipelineKit
//
//  Core event types for pipeline observability
//

import Foundation

/// Represents an event in the pipeline execution.
///
/// Events provide observability into the pipeline's execution flow,
/// allowing monitoring, debugging, and metrics collection.
public struct PipelineEvent: Sendable, Equatable {
    /// The name/type of the event (e.g., "command.started", "middleware.timeout")
    public let name: String
    
    /// Additional properties specific to this event
    public let properties: [String: AnySendable]
    
    /// Correlation ID for tracing related events
    public let correlationID: String
    
    /// Monotonically increasing sequence number for ordering
    public let sequenceID: UInt64
    
    /// Event timestamp
    public let timestamp: Date
    
    /// Creates a new pipeline event.
    ///
    /// - Parameters:
    ///   - name: Event name/type
    ///   - properties: Additional event properties
    ///   - correlationID: ID for correlating related events
    ///   - sequenceID: Sequence number for ordering (auto-generated if not provided)
    ///   - timestamp: Event timestamp (defaults to now)
    public init(
        name: String,
        properties: [String: any Sendable] = [:],
        correlationID: String,
        sequenceID: UInt64? = nil,
        timestamp: Date = Date()
    ) {
        self.name = name
        self.properties = properties.mapValues { AnySendable($0) }
        self.correlationID = correlationID
        self.sequenceID = sequenceID ?? Self.nextSequenceID()
        self.timestamp = timestamp
    }
    
    /// Convenience initializer with source property
    public init(
        name: String,
        source: String,
        properties: [String: any Sendable] = [:],
        correlationID: String? = nil
    ) {
        var allProperties = properties
        allProperties["source"] = source
        
        self.init(
            name: name,
            properties: allProperties,
            correlationID: correlationID ?? UUID().uuidString
        )
    }
    
    // Thread-safe sequence counter actor
    private actor SequenceCounter {
        private var value: UInt64 = 0
        
        func next() -> UInt64 {
            value += 1
            return value
        }
    }
    
    private static let sequenceCounter = SequenceCounter()
    
    private static func nextSequenceID() -> UInt64 {
        // This is a synchronous context, so we can't use async/await
        // For now, just use a random ID
        return UInt64.random(in: 1...UInt64.max)
    }
}

// MARK: - Event Categories and Names

public extension PipelineEvent {
    /// Standard event name prefixes for categorization
    enum Category {
        public static let command = "command"
        public static let middleware = "middleware"
        public static let pipeline = "pipeline"
        public static let metrics = "metrics"
        public static let security = "security"
        public static let performance = "performance"
    }
    
    /// Common event names
    enum Name {
        // Command events
        public static let commandStarted = "command.started"
        public static let commandCompleted = "command.completed"
        public static let commandFailed = "command.failed"
        
        // Middleware events
        public static let middlewareExecuting = "middleware.executing"
        public static let middlewareCompleted = "middleware.completed"
        public static let middlewareFailed = "middleware.failed"
        public static let middlewareTimeout = "middleware.timeout"
        public static let middlewareRetry = "middleware.retry"
        public static let middlewareRetryDelay = "middleware.retry_delay"
        public static let middlewareRetrySuccess = "middleware.retry_success"
        public static let middlewareRetryFailed = "middleware.retry_failed"
        public static let middlewareRetryExhausted = "middleware.retry_exhausted"
        public static let middlewareRateLimited = "middleware.rate_limited"
        public static let middlewareCircuitOpen = "middleware.circuit_open"
        public static let middlewareBackpressure = "middleware.backpressure"
        
        // Timeout events
        public static let middlewareTimeoutWarning = "middleware.timeout_warning"
        public static let middlewareTimeoutRecovered = "middleware.timeout_recovered"
        
        // Circuit breaker events
        public static let circuitOpened = "middleware.circuit_opened"
        public static let circuitClosed = "middleware.circuit_closed"
        public static let circuitHalfOpen = "middleware.circuit_half_open"
        
        // Bulkhead events
        public static let bulkheadRejected = "middleware.bulkhead_rejected"
        public static let bulkheadAccepted = "middleware.bulkhead_accepted"
        
        // Health check events
        public static let healthCheckSuccess = "middleware.health_check_success"
        public static let healthCheckFailed = "middleware.health_check_failed"
        
        // Cache events
        public static let cacheHit = "middleware.cache_hit"
        public static let cacheMiss = "middleware.cache_miss"
        public static let cacheEvicted = "middleware.cache_evicted"
        
        // Resilient middleware events
        public static let resilienceRetryAttempt = "middleware.resilience_retry_attempt"
        public static let resilienceRecovered = "middleware.resilience_recovered"
        public static let resilienceFailed = "middleware.resilience_failed"
        
        // Pipeline events
        public static let pipelineStarted = "pipeline.started"
        public static let pipelineCompleted = "pipeline.completed"
        public static let pipelineFailed = "pipeline.failed"
    }
}

// MARK: - Event Emission Protocols

/// Protocol for components that can emit observability events.
///
/// Implementations can choose to process events synchronously or
/// asynchronously based on their requirements.
public protocol EventEmitter: Sendable {
    /// Emits an event to the observability system.
    ///
    /// - Parameter event: The event to emit
    func emit(_ event: PipelineEvent) async
}

/// Protocol for components that can observe pipeline events.
public protocol PipelineObserver: Sendable {
    /// Handles an emitted event.
    ///
    /// - Parameter event: The event to handle
    func handleEvent(_ event: PipelineEvent) async
}
