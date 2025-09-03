//
//  CapturingEmitter.swift
//  PipelineKit
//
//  Test infrastructure for capturing and verifying events
//

import Foundation
import PipelineKitCore
import PipelineKitObservability

/// An event emitter that captures events for testing.
///
/// This emitter stores all emitted events in memory for later verification
/// in tests. It's thread-safe using an actor for event storage.
///
/// ## Usage Example
/// ```swift
/// let emitter = CapturingEmitter()
/// context.eventEmitter = emitter
///
/// // Execute code that emits events
/// await command.execute()
///
/// // Verify events
/// let events = await emitter.events
/// XCTAssertEqual(events.count, 2)
/// XCTAssertEqual(events[0].name, "command.started")
/// ```
public final class CapturingEmitter: EventEmitter {
    /// Actor for thread-safe event storage
    private let storage = EventStorage()

    public init() {}

    /// Emits an event by capturing it.
    public func emit(_ event: PipelineEvent) async {
        await storage.capture(event)
    }

    /// Gets all captured events.
    public var events: [PipelineEvent] {
        get async { await storage.events }
    }

    /// Gets the count of captured events.
    public var eventCount: Int {
        get async { await storage.events.count }
    }

    /// Clears all captured events.
    public func clear() async {
        await storage.clear()
    }

    /// Finds events matching a predicate.
    ///
    /// - Parameter predicate: The filter predicate
    /// - Returns: Events matching the predicate
    public func events(matching predicate: @escaping (PipelineEvent) -> Bool) async -> [PipelineEvent] {
        await storage.events.filter(predicate)
    }

    /// Finds events with a specific name.
    ///
    /// - Parameter name: The event name to match
    /// - Returns: Events with the specified name
    public func events(named name: String) async -> [PipelineEvent] {
        await events(matching: { $0.name == name })
    }

    /// Waits for a specific number of events to be captured.
    ///
    /// - Parameters:
    ///   - count: The number of events to wait for
    ///   - timeout: Maximum time to wait
    /// - Returns: True if the count was reached, false if timeout
    public func waitForEvents(count: Int, timeout: TimeInterval = 5.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await eventCount >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        return false
    }

    /// Asserts that an event was emitted.
    ///
    /// - Parameters:
    ///   - name: The event name
    ///   - properties: Optional properties to match
    /// - Returns: The matching event if found, nil otherwise
    public func assertEventEmitted(
        named name: String,
        withProperties properties: [String: String]? = nil
    ) async -> PipelineEvent? {
        let matches = await events(named: name)

        guard let properties = properties else {
            return matches.first
        }

        // Find event with matching properties
        for event in matches {
            var allMatch = true
            for (key, expectedValue) in properties {
                if let actualValue = event.properties[key]?.get(String.self),
                   actualValue != expectedValue {
                    allMatch = false
                    break
                }
            }
            if allMatch {
                return event
            }
        }

        return nil
    }
}

/// Actor for thread-safe event storage.
private actor EventStorage {
    private var capturedEvents: [PipelineEvent] = []

    var events: [PipelineEvent] {
        capturedEvents
    }

    func capture(_ event: PipelineEvent) {
        capturedEvents.append(event)
    }

    func clear() {
        capturedEvents.removeAll()
    }
}

// MARK: - Mock Subscriber

/// A mock event subscriber for testing.
///
/// This subscriber captures events it receives and can be used
/// to verify event delivery through an EventHub.
public final class MockEventSubscriber: EventSubscriber {
    private let storage = EventStorage()

    /// Optional delay to simulate processing time
    public let processingDelay: TimeInterval?

    /// Optional error to throw during processing
    public let shouldFail: Bool

    public init(processingDelay: TimeInterval? = nil, shouldFail: Bool = false) {
        self.processingDelay = processingDelay
        self.shouldFail = shouldFail
    }

    public func process(_ event: PipelineEvent) async {
        // Simulate processing delay if configured
        if let delay = processingDelay {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        // Capture the event
        await storage.capture(event)

        // Simulate failure if configured
        if shouldFail {
            // In real scenarios, we might log the error
            // For testing, we just swallow it
        }
    }

    /// Gets all processed events.
    public var processedEvents: [PipelineEvent] {
        get async { await storage.events }
    }

    /// Clears all processed events.
    public func clear() async {
        await storage.clear()
    }
}
