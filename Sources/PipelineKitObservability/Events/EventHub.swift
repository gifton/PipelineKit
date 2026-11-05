//
//  EventHub.swift
//  PipelineKit
//
//  Central hub for event distribution to subscribers
//

import Foundation
import PipelineKitCore
import Synchronization

/// Invalidated before a newer configuration is submitted to the hub.
final class EventSubscriptionGeneration: Sendable {
    private let active = Mutex(true)
    var isActive: Bool { active.withLock { $0 } }
    func invalidate() { active.withLock { $0 = false } }
}

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
/// 2. **Subscription ownership**: Ordinary subscriptions are weak; metrics connections are owned
/// 3. **Fire-and-forget**: Non-blocking event delivery via Task{}
/// 4. **Delivery task**: Schedules subscriber delivery on the hub actor
/// 5. **Periodic cleanup**: Removes nil weak references to prevent memory leak
///
/// Synchronous `emit` schedules one task per event; it does not impose a queue
/// limit or backpressure. Subscriber fan-out visits each registered subscriber.
public actor EventHub: EventEmitter {
    // MARK: - Private Types

    /// Wrapper for weak subscriber references
    private struct WeakBox {
        weak var subscriber: (any EventSubscriber)?
        let id: ObjectIdentifier

        init(_ subscriber: any EventSubscriber, id: ObjectIdentifier) {
            self.subscriber = subscriber
            self.id = id
        }
    }

    // MARK: - Properties

    /// Weak references to subscribers
    private var subscribers: [WeakBox] = []
    private var replaceableSubscriptions: [UUID: ObjectIdentifier] = [:]
    private let subscriberIdentity: @Sendable (any EventSubscriber) -> ObjectIdentifier

    // testConnectionRecordsMetricAfterConnectReturns and
    // testConnectedRecorderLivesUntilHubDeallocates exercise this ownership.
    private var metricsConnections: [UUID: MetricsEventBridge] = [:]
    
    /// Weak reference to the parent ObservabilitySystem if this hub is part of one
    internal weak var parentSystem: ObservabilitySystem?

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
    /// - Precondition: A finite positive interval representable as at least one
    ///   nanosecond and fewer than 2^64 nanoseconds.
    public init(cleanupInterval: TimeInterval = 60.0) {
        self.init(cleanupInterval: cleanupInterval, subscriberIdentity: { ObjectIdentifier($0) })
    }

    init(
        cleanupInterval: TimeInterval,
        subscriberIdentity: @escaping @Sendable (any EventSubscriber) -> ObjectIdentifier
    ) {
        _ = NumericDuration.nanoseconds(cleanupInterval, positive: true)
        self.cleanupInterval = cleanupInterval
        self.subscriberIdentity = subscriberIdentity
        Task {
            await startCleanupTask()
        }
    }

    deinit { cleanupTask?.cancel() }

    // MARK: - EventEmitter Conformance

    /// Emits an event to all subscribers using fire-and-forget pattern.
    ///
    /// This method is nonisolated and synchronous for performance.
    /// Delivery runs asynchronously on the hub actor.
    ///
    /// ## Fire-and-Forget Design
    /// - Events are delivered asynchronously without waiting for completion
    /// - Weak self capture prevents retain cycles but may drop events if hub is deallocated
    /// - This is intentional: the hub should not block emitters or retain them
    /// - Lost events during deallocation are acceptable in this pattern
    ///
    /// ## Thread Safety
    /// - The nonisolated method is safe because it only creates a Task
    /// - All actual work happens inside the actor's isolation domain
    /// - No shared mutable state is accessed outside the actor
    ///
    /// - Parameter event: The event to emit
    public nonisolated func emit(_ event: PipelineEvent) {
        // Weak self prevents retain cycles and allows clean deallocation
        Task { [weak self] in
            await self?.deliverEvent(event)
        }
    }
    
    /// Async version of emit to conform to EventEmitter protocol
    public func emit(_ event: PipelineEvent) async {
        await deliverEvent(event)
    }

    // MARK: - Subscription Management

    /// Subscribes to receive events.
    ///
    /// - Parameter subscriber: The subscriber to add
    public func subscribe(_ subscriber: any EventSubscriber) {
        performCleanup()
        // Check if already subscribed
        let id = subscriberIdentity(subscriber)
        let isSubscribed = subscribers.contains { $0.id == id }

        if !isSubscribed {
            subscribers.append(WeakBox(subscriber, id: id))
            stats.totalSubscriptions += 1
        }
    }

    /// Unsubscribes from receiving events.
    ///
    /// - Parameter subscriber: The subscriber to remove
    public func unsubscribe(_ subscriber: any EventSubscriber) {
        let id = subscriberIdentity(subscriber)
        subscribers.removeAll { $0.id == id }
        replaceableSubscriptions = replaceableSubscriptions.filter { $0.value != id }
    }

    /// Connects a metric recorder with automatic event-to-metric conversion.
    ///
    /// The hub retains each connection independently until
    /// `disconnectMetrics(_:)` is called or the hub is released. The returned
    /// identifier may be ignored; it does not own the connection or the hub.
    /// Ordinary `subscribe(_:)` registrations remain weak.
    ///
    /// - Parameters:
    ///   - recorder: The metric recorder to receive converted events.
    ///   - config: Configuration for metric generation.
    /// - Returns: An identifier for disconnecting this connection.
    @discardableResult
    public func connectMetrics(
        _ recorder: any MetricRecorder,
        config: MetricsGenerationConfig = .default
    ) -> UUID {
        let connectionID = UUID()
        let bridge = MetricsEventBridge(recorder: recorder, config: config)
        metricsConnections[connectionID] = bridge
        subscribe(bridge)
        return connectionID
    }

    /// Removes a metrics connection from future event delivery.
    ///
    /// Delivery is admitted when the hub snapshots its subscribers. Events
    /// admitted before this call may finish after it returns and retain the
    /// recorder until they finish. This method does not wait for those events,
    /// so a recorder may disconnect its own connection from `record(_:)`.
    ///
    /// Repeated calls and identifiers from another hub have no effect. This
    /// method does not flush or close the recorder.
    ///
    /// - Parameter connectionID: The identifier returned by `connectMetrics(_:config:)`.
    public func disconnectMetrics(_ connectionID: UUID) {
        // Covered by testDisconnectReturnsBeforeAdmittedDeliverySettles and
        // testRecorderCanDisconnectItsOwnConnection; no delivery is joined here.
        guard let bridge = metricsConnections.removeValue(forKey: connectionID) else { return }
        unsubscribe(bridge)
    }

    /// One actor turn switches the owner slot and returns its actual displaced
    /// subscriber. A superseded submission must not retire the installed route.
    func replaceSubscription(
        owner: UUID,
        generation: EventSubscriptionGeneration,
        with subscriber: (any EventSubscriber)?
    ) -> (installed: Bool, retired: (any EventSubscriber)?) {
        guard generation.isActive else { return (false, nil) }
        performCleanup()
        var retired: (any EventSubscriber)?
        if let identifier = replaceableSubscriptions.removeValue(forKey: owner) {
            retired = subscribers.first { $0.id == identifier }?.subscriber
            subscribers.removeAll { $0.id == identifier }
        }
        if let subscriber {
            subscribe(subscriber)
            replaceableSubscriptions[owner] = subscriberIdentity(subscriber)
        }
        return (true, retired)
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

        // This snapshot is the admission boundary for disconnectMetrics.
        // Admitted deliveries retain their subscribers through the task group
        // (testDisconnectReturnsBeforeAdmittedDeliverySettles).
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
    ///
    /// The cleanup loop captures `self` weakly so that it does not keep the
    /// actor alive. The immutable `cleanupInterval` is copied into a local
    /// before the task is created, which means the sleep does not need to
    /// touch `self` and therefore does not retain it while the loop is idle.
    /// When all external references to the hub are dropped during the sleep,
    /// the actor deallocates and the next wake-up exits via the
    /// `guard let self else { break }` check.
    private func startCleanupTask() async {
        let interval = NumericDuration.nanoseconds(cleanupInterval, positive: true)
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard let self else { break }
                await self.performCleanup()
            }
        }
    }

    /// Removes nil weak references and owner mappings without a registered route.
    private func performCleanup() {
        // Registration also runs cleanup before a cached identity can be reused:
        // testReleasedSubscriptionIdentitiesDoNotBlockNewRegistrations and
        // testUnsubscribedReplacementOwnerCannotRemoveReadmittedSubscriber.
        let beforeCount = subscribers.count
        subscribers.removeAll { $0.subscriber == nil }
        let liveIDs = Set(subscribers.map(\.id))
        replaceableSubscriptions = replaceableSubscriptions.filter { liveIDs.contains($0.value) }
        let removed = beforeCount - subscribers.count

        if removed > 0 {
            stats.cleanupRuns += 1
            stats.referencesCleanedUp += removed
        }
    }
    
    // MARK: - Internal Methods
    
    /// Sets the parent ObservabilitySystem for this hub.
    /// This enables retrieving the system from a CommandContext.
    public func setParentSystem(_ system: ObservabilitySystem?) {
        self.parentSystem = system
    }
    
    /// Gets the parent ObservabilitySystem if one exists.
    public func getParentSystem() -> ObservabilitySystem? {
        return parentSystem
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
