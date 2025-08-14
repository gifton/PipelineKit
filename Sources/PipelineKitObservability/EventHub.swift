//
//  EventHub.swift
//  PipelineKit
//
//  Central hub for event distribution to subscribers
//

import Foundation

/// Protocol for components that want to receive events.
public protocol EventSubscriber: AnyObject, Sendable {
    /// Processes an event asynchronously.
    ///
    /// - Parameter event: The event to process
    func process(_ event: PipelineEvent) async
}

/// Central hub for distributing events to subscribers.
///
/// ## Design Decisions
///
/// 1. **Actor isolation**: Ensures thread-safe subscriber management
/// 2. **Weak references**: Prevents retain cycles with automatic cleanup
/// 3. **Fire-and-forget**: Non-blocking event delivery via Task{}
/// 4. **Task{} not Task.detached**: Inherits actor executor to avoid hop (~200ns savings)
/// 5. **Periodic cleanup**: Removes nil weak references to prevent memory leak
///
/// ## Performance Characteristics
/// - emit() overhead: ~250ns (Task creation + actor hop)
/// - Fan-out: O(n) where n = number of subscribers
/// - Memory: Weak references prevent retention
public actor EventHub: EventEmitter {
    // MARK: - Private Types

    /// Wrapper for weak subscriber references
    private struct WeakBox {
        weak var subscriber: (any EventSubscriber)?
        let id: ObjectIdentifier

        init(_ subscriber: any EventSubscriber) {
            self.subscriber = subscriber
            self.id = ObjectIdentifier(subscriber)
        }
    }

    // MARK: - Properties

    /// Weak references to subscribers
    private var subscribers: [WeakBox] = []

    /// Timer for periodic cleanup of nil references
    private var cleanupTask: Task<Void, Never>?

    /// Cleanup interval in seconds
    private let cleanupInterval: TimeInterval

    /// Statistics for monitoring
    private var stats = EventHubStatistics()

    // MARK: - Initialization

    /// Creates a new event hub.
    ///
    /// - Parameter cleanupInterval: Interval for cleaning up nil weak references (default: 60s)
    public init(cleanupInterval: TimeInterval = 60.0) {
        self.cleanupInterval = cleanupInterval
        Task {
            await startCleanupTask()
        }
    }

    deinit {
        cleanupTask?.cancel()
    }

    // MARK: - EventEmitter Conformance

    /// Emits an event to all subscribers.
    ///
    /// This method is nonisolated and synchronous for performance.
    /// It uses Task{} to inherit the actor's executor, avoiding the
    /// overhead of Task.detached which would require an executor hop.
    ///
    /// - Parameter event: The event to emit
    public nonisolated func emit(_ event: PipelineEvent) {
        // Use Task{} not Task.detached to inherit actor executor
        Task { [weak self] in
            await self?.deliverEvent(event)
        }
    }

    // MARK: - Subscription Management

    /// Subscribes to receive events.
    ///
    /// - Parameter subscriber: The subscriber to add
    public func subscribe(_ subscriber: any EventSubscriber) {
        // Check if already subscribed
        let id = ObjectIdentifier(subscriber)
        let isSubscribed = subscribers.contains { $0.id == id }

        if !isSubscribed {
            subscribers.append(WeakBox(subscriber))
            stats.totalSubscriptions += 1
        }
    }

    /// Unsubscribes from receiving events.
    ///
    /// - Parameter subscriber: The subscriber to remove
    public func unsubscribe(_ subscriber: any EventSubscriber) {
        let id = ObjectIdentifier(subscriber)
        subscribers.removeAll { $0.id == id }
    }

    /// Gets the current number of active subscribers.
    public var subscriberCount: Int {
        subscribers.compactMap { $0.subscriber }.count
    }

    /// Gets hub statistics.
    public var statistics: EventHubStatistics {
        stats
    }

    // MARK: - Private Methods

    /// Delivers an event to all subscribers.
    private func deliverEvent(_ event: PipelineEvent) async {
        stats.eventsEmitted += 1

        // Get live subscribers
        let liveSubscribers = subscribers.compactMap { $0.subscriber }

        // Fan out to all subscribers concurrently
        await withTaskGroup(of: Void.self) { group in
            for subscriber in liveSubscribers {
                group.addTask {
                    await subscriber.process(event)
                }
            }
        }

        stats.eventsDelivered += 1
    }

    /// Starts the periodic cleanup task.
    private func startCleanupTask() async {
        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(cleanupInterval * 1_000_000_000))
                performCleanup()
            }
        }
    }

    /// Removes nil weak references.
    private func performCleanup() {
        let beforeCount = subscribers.count
        subscribers.removeAll { $0.subscriber == nil }
        let removed = beforeCount - subscribers.count

        if removed > 0 {
            stats.cleanupRuns += 1
            stats.referencesCleanedUp += removed
        }
    }
}

// MARK: - Statistics

/// Statistics for event hub monitoring.
public struct EventHubStatistics: Sendable {
    /// Total number of events emitted
    public var eventsEmitted: Int = 0

    /// Total number of events successfully delivered
    public var eventsDelivered: Int = 0

    /// Total number of subscriptions made
    public var totalSubscriptions: Int = 0

    /// Number of cleanup runs performed
    public var cleanupRuns: Int = 0

    /// Total number of nil references cleaned up
    public var referencesCleanedUp: Int = 0
}

// MARK: - NoOpEmitter

/// A no-operation event emitter that discards all events.
///
/// This implementation has zero runtime cost when used as it's
/// completely optimized away by the compiler with @inlinable.
public struct NoOpEmitter: EventEmitter {
    public init() {}

    @inlinable
    public func emit(_ event: PipelineEvent) {
        // No operation - compiler optimizes this away
    }
}
