import Foundation

/// An in-memory audit logger for testing and development.
///
/// This logger stores all events in memory, making it ideal for unit tests
/// where you need to verify that specific events were logged. It's an actor
/// to ensure thread-safe access to the event storage.
///
/// Example:
/// ```swift
/// let logger = InMemoryAuditLogger()
/// await logger.log(someEvent)
/// let events = await logger.allEvents()
/// XCTAssertEqual(events.count, 1)
/// ```
public actor InMemoryAuditLogger: AuditLogger {
    /// Internal wrapper to capture metadata at log time
    private struct CapturedEvent {
        let event: any AuditEvent
        let metadata: [String: any Sendable]
        
        init(_ event: any AuditEvent) {
            self.event = event
            // Capture metadata while trace context is active
            self.metadata = event.metadata
        }
    }
    
    /// The stored audit events with captured metadata
    private var storage: [CapturedEvent] = []
    
    /// Maximum number of events to store (nil = unlimited)
    private let maxEvents: Int?
    
    /// Health events for monitoring
    private let (healthStream, healthContinuation): (AsyncStream<LoggerHealthEvent>, AsyncStream<LoggerHealthEvent>.Continuation)
    
    /// Number of events that have been dropped
    private var droppedCount: Int = 0
    
    /// Creates a new in-memory audit logger.
    ///
    /// - Parameter maxEvents: Maximum events to store. Older events are dropped when limit is reached.
    public init(maxEvents: Int? = nil) {
        self.maxEvents = maxEvents
        let (stream, continuation) = AsyncStream<LoggerHealthEvent>.makeStream()
        self.healthStream = stream
        self.healthContinuation = continuation
    }
    
    deinit {
        healthContinuation.finish()
    }
    
    // MARK: - AuditLogger Conformance
    
    public nonisolated func log(_ event: any AuditEvent) async {
        await addEvent(event)
    }
    
    public nonisolated var health: AsyncStream<LoggerHealthEvent> {
        healthStream
    }
    
    // MARK: - Storage Management
    
    private func addEvent(_ event: any AuditEvent) {
        if let maxEvents = maxEvents, storage.count >= maxEvents {
            // Drop oldest event
            storage.removeFirst()
            droppedCount += 1
            
            // Report health event every 10 drops
            if droppedCount % 10 == 0 {
                healthContinuation.yield(.dropped(
                    count: droppedCount,
                    reason: "Memory limit reached (\(maxEvents) events)"
                ))
            }
        }
        
        storage.append(CapturedEvent(event))
    }
    
    // MARK: - Query Methods
    
    /// Returns all stored events.
    public func allEvents() -> [any AuditEvent] {
        storage.map { $0.event }
    }
    
    /// Returns the most recent event, if any.
    public func lastEvent() -> (any AuditEvent)? {
        storage.last?.event
    }
    
    /// Returns events matching a predicate.
    public func events(matching predicate: (any AuditEvent) -> Bool) -> [any AuditEvent] {
        storage.compactMap { predicate($0.event) ? $0.event : nil }
    }
    
    /// Returns events of a specific type.
    public func events<T: AuditEvent>(ofType type: T.Type) -> [T] {
        storage.compactMap { $0.event as? T }
    }
    
    /// Returns events with a specific event type string.
    public func events(withType eventType: String) -> [any AuditEvent] {
        storage.compactMap { $0.event.eventType == eventType ? $0.event : nil }
    }
    
    /// Returns events within a time range.
    public func events(from startDate: Date, to endDate: Date) -> [any AuditEvent] {
        storage.compactMap { captured in
            let timestamp = captured.event.timestamp
            return timestamp >= startDate && timestamp <= endDate ? captured.event : nil
        }
    }
    
    /// Clears all stored events.
    public func clear() {
        storage.removeAll()
        droppedCount = 0
        healthContinuation.yield(.recovered)
    }
    
    /// Returns the count of stored events.
    public var count: Int {
        storage.count
    }
    
    /// Returns true if no events are stored.
    public var isEmpty: Bool {
        storage.isEmpty
    }
    
    /// Returns the total number of events dropped due to capacity.
    public var droppedEventsCount: Int {
        droppedCount
    }
}

// MARK: - Test Helpers

public extension InMemoryAuditLogger {
    /// Asserts that an event matching the predicate exists.
    func assertContains(
        matching predicate: (any AuditEvent) -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Bool {
        let matches = events(matching: predicate)
        return !matches.isEmpty
    }
    
    /// Asserts that exactly one event matches the predicate.
    func assertContainsOne(
        matching predicate: (any AuditEvent) -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Bool {
        let matches = events(matching: predicate)
        return matches.count == 1
    }
    
    /// Waits for a specific number of events to be logged.
    func waitForEvents(
        count expectedCount: Int,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        
        while count < expectedCount {
            if Date() > deadline {
                throw WaitError.timeout(expected: expectedCount, actual: count)
            }
            
            // Small delay to avoid busy waiting
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
    
    enum WaitError: Error {
        case timeout(expected: Int, actual: Int)
    }
}

// MARK: - Convenience Methods for Common Event Types

public extension InMemoryAuditLogger {
    /// Wrapper that provides access to captured metadata for testing
    struct TestableEvent<T: AuditEvent>: Sendable {
        public let event: T
        public let metadata: [String: any Sendable]
    }
    
    /// Returns all command lifecycle events with captured metadata.
    func commandEventsWithMetadata() -> [TestableEvent<CommandLifecycleEvent>] {
        storage.compactMap { captured in
            guard let event = captured.event as? CommandLifecycleEvent else { return nil }
            return TestableEvent(event: event, metadata: captured.metadata)
        }
    }
    
    /// Returns all command lifecycle events.
    func commandEvents() -> [CommandLifecycleEvent] {
        events(ofType: CommandLifecycleEvent.self)
    }
    
    /// Returns all security audit events.
    func securityEvents() -> [SecurityAuditEvent] {
        events(ofType: SecurityAuditEvent.self)
    }
    
    /// Returns command events for a specific command type.
    func commandEvents(forType commandType: String) -> [CommandLifecycleEvent] {
        commandEvents().filter { $0.commandType == commandType }
    }
    
    /// Returns the last command event, if any.
    func lastCommandEvent() -> CommandLifecycleEvent? {
        commandEvents().last
    }
    
    /// Returns the last security event, if any.
    func lastSecurityEvent() -> SecurityAuditEvent? {
        securityEvents().last
    }
}