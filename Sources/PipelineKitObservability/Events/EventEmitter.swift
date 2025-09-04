//
//  EventEmitter.swift
//  PipelineKit
//
//  Enhanced event emission with performance optimizations
//

import Foundation
import PipelineKitCore
import Atomics

/// High-performance synchronous event emitter.
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
/// struct MyEmitter: SyncEventEmitter {
///     func emit(_ event: PipelineEvent) {
///         // Process event without blocking
///         Task { await processAsync(event) }
///     }
/// }
/// ```
public protocol SyncEventEmitter: Sendable {
    /// Emits an event synchronously (no suspension point).
    ///
    /// This method is synchronous to avoid suspension point overhead.
    /// Implementations should use Task{} internally if async work is needed.
    ///
    /// - Parameter event: The event to emit
    func emit(_ event: PipelineEvent)
}

// MARK: - High-Performance Extensions

/// Extension for high-precision timing with ContinuousClock
public extension PipelineEvent {
    /// Creates an event with high-precision monotonic timing
    static func withPreciseTiming(
        name: String,
        properties: [String: any Sendable] = [:],
        correlationID: String
    ) -> (event: PipelineEvent, startTime: ContinuousClock.Instant) {
        let startTime = ContinuousClock.now
        let event = PipelineEvent(
            name: name,
            properties: properties,
            correlationID: correlationID
        )
        return (event, startTime)
    }
    
    /// Calculates duration from a start time to now
    static func duration(from startTime: ContinuousClock.Instant) -> Duration {
        ContinuousClock.now - startTime
    }
}

// MARK: - Atomic Sequence Counter

/// High-performance atomic sequence counter for event ordering.
///
/// Uses relaxed memory ordering for performance since exact ordering
/// between threads is not critical - we only need monotonic increase.
public enum AtomicEventSequence {
    @usableFromInline internal static let counter = ManagedAtomic<UInt64>(0)

    /// Gets the next sequence number atomically.
    @inlinable
    public static func next() -> UInt64 {
        counter.wrappingIncrementThenLoad(ordering: .relaxed) &- 1
    }

    /// Resets the counter (for testing only).
    public static func reset() {
        #if DEBUG
        counter.store(0, ordering: .relaxed)
        #endif
    }
}
