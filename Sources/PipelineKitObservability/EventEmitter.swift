//
//  EventEmitter.swift
//  PipelineKit
//
//  Core event emission protocol for observability
//

import Foundation
import Atomics

/// Protocol for components that can emit observability events.
///
/// ## Design Decisions
///
/// 1. **Synchronous emit()**: No async/await to avoid suspension point overhead (~20-50ns)
/// 2. **Fire-and-forget pattern**: Emitters handle async work internally if needed
/// 3. **Sendable constraint**: Ensures thread-safe usage across actor boundaries
/// 4. **No return value**: Emission failures are handled internally
///
/// ## Usage Example
/// ```swift
/// struct MyEmitter: EventEmitter {
///     func emit(_ event: PipelineEvent) {
///         // Process event without blocking
///         Task { await processAsync(event) }
///     }
/// }
/// ```
public protocol EventEmitter: Sendable {
    /// Emits an event to the observability system.
    ///
    /// This method is synchronous to avoid suspension point overhead.
    /// Implementations should use Task{} internally if async work is needed.
    ///
    /// - Parameter event: The event to emit
    func emit(_ event: PipelineEvent)
}

/// Represents an event in the pipeline execution.
///
/// ## Design Decisions
///
/// 1. **Lightweight**: No context snapshot to minimize allocation overhead
/// 2. **Immutable**: All properties are let-bound for thread safety
/// 3. **ContinuousClock**: Monotonic timestamps for accurate duration calculation
/// 4. **Flexible properties**: Dictionary allows arbitrary metadata without schema changes
/// 5. **Relaxed atomics**: Sequence counter uses relaxed ordering for performance
///
/// ## Performance Characteristics
/// - Allocation: ~200 bytes per event (varies with properties)
/// - Construction: ~50ns with pre-computed values
/// - Copying: Value semantics with efficient String/Dictionary COW
public struct PipelineEvent: Sendable, Equatable {
    /// The name/type of the event (e.g., "command.started", "middleware.timeout")
    public let name: String

    /// Additional properties specific to this event
    public let properties: [String: AnySendable]

    /// Correlation ID for tracing related events
    public let correlationID: String

    /// Monotonically increasing sequence number for ordering
    public let sequenceID: UInt64

    /// High-precision timestamp using monotonic clock
    public let timestamp: ContinuousClock.Instant

    /// Creates a new pipeline event.
    ///
    /// - Parameters:
    ///   - name: Event name/type
    ///   - properties: Additional event properties
    ///   - correlationID: ID for correlating related events
    ///   - sequenceID: Sequence number for ordering
    ///   - timestamp: Event timestamp (defaults to now)
    public init(
        name: String,
        properties: [String: any Sendable] = [:],
        correlationID: String,
        sequenceID: UInt64,
        timestamp: ContinuousClock.Instant = .now
    ) {
        self.name = name
        self.properties = properties.mapValues { AnySendable($0) }
        self.correlationID = correlationID
        self.sequenceID = sequenceID
        self.timestamp = timestamp
    }

    /// Convenience initializer with automatic sequence ID generation.
    ///
    /// - Parameters:
    ///   - name: Event name/type
    ///   - properties: Additional event properties
    ///   - correlationID: ID for correlating related events
    public init(
        name: String,
        properties: [String: any Sendable] = [:],
        correlationID: String
    ) {
        self.init(
            name: name,
            properties: properties,
            correlationID: correlationID,
            sequenceID: EventSequence.next(),
            timestamp: .now
        )
    }
}

// MARK: - Event Categories

public extension PipelineEvent {
    /// Standard event name prefixes for categorization
    enum Category {
        static let command = "command"
        static let middleware = "middleware"
        static let pipeline = "pipeline"
        static let metrics = "metrics"
        static let security = "security"
        static let performance = "performance"
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
        public static let middlewareRateLimited = "middleware.rate_limited"
        public static let middlewareCircuitOpen = "middleware.circuit_open"
        public static let middlewareBackpressure = "middleware.backpressure"

        // Pipeline events
        public static let pipelineStarted = "pipeline.started"
        public static let pipelineCompleted = "pipeline.completed"
        public static let pipelineFailed = "pipeline.failed"
    }
}

// MARK: - Sequence Counter

/// Global sequence counter for event ordering.
///
/// Uses relaxed memory ordering for performance since exact ordering
/// between threads is not critical - we only need monotonic increase.
internal enum EventSequence {
    private static let counter = ManagedAtomic<UInt64>(0)

    /// Gets the next sequence number.
    @inlinable
    static func next() -> UInt64 {
        counter.wrappingIncrementThenLoad(ordering: .relaxed) &- 1
    }

    /// Resets the counter (for testing only).
    static func reset() {
        #if DEBUG
        counter.store(0, ordering: .relaxed)
        #endif
    }
}
