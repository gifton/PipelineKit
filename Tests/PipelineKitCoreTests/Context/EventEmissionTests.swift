import XCTest
@testable import PipelineKitCore

/// Tests for unified event emission in Core
final class EventEmissionTests: XCTestCase {
    // MARK: - Test Event Emitter
    
    /// A simple test emitter that captures events
    private actor TestEventEmitter: EventEmitter {
        private(set) var capturedEvents: [PipelineEvent] = []
        
        func emit(_ event: PipelineEvent) async {
            capturedEvents.append(event)
        }
        
        func reset() {
            capturedEvents.removeAll()
        }
        
        func lastEvent() -> PipelineEvent? {
            capturedEvents.last
        }
        
        func eventCount() -> Int {
            capturedEvents.count
        }
    }
    
    // MARK: - Basic Event Emission Tests
    
    func testEventEmissionWithEmitter() async throws {
        // Given
        let context = CommandContext()
        let emitter = TestEventEmitter()
        context.eventEmitter = emitter
        
        // When
        let event = PipelineEvent(
            name: "test.event",
            properties: ["key": "value"],
            correlationID: "test-correlation"
        )
        await context.emitEvent(event)
        
        // Then
        let capturedCount = await emitter.eventCount()
        XCTAssertEqual(capturedCount, 1)
        
        let lastEvent = await emitter.lastEvent()
        XCTAssertNotNil(lastEvent)
        XCTAssertEqual(lastEvent?.name, "test.event")
        XCTAssertEqual(lastEvent?.correlationID, "test-correlation")
    }
    
    func testEventEmissionWithoutEmitter() async throws {
        // Given
        let context = CommandContext()
        // No emitter set
        
        // When
        let event = PipelineEvent(
            name: "test.event",
            properties: [:],
            correlationID: "test-correlation"
        )
        
        // This should not crash - events are silently discarded
        await context.emitEvent(event)
        
        // Then
        let emitter = context.eventEmitter
        XCTAssertNil(emitter)
    }
    
    func testEmitterCanBeSetAndRetrieved() async throws {
        // Given
        let context = CommandContext()
        let emitter = TestEventEmitter()
        
        // When
        context.eventEmitter = emitter
        
        // Then
        let retrievedEmitter = context.eventEmitter
        XCTAssertNotNil(retrievedEmitter)
        XCTAssertTrue(retrievedEmitter is TestEventEmitter)
    }
    
    func testEmitterCanBeCleared() async throws {
        // Given
        let context = CommandContext()
        let emitter = TestEventEmitter()
        context.eventEmitter = emitter
        
        // When
        context.eventEmitter = nil
        
        // Then
        let retrievedEmitter = context.eventEmitter
        XCTAssertNil(retrievedEmitter)
    }
    
    // MARK: - Middleware Event Tests
    
    func testMiddlewareEventEmission() async throws {
        // Given
        let context = CommandContext()
        let emitter = TestEventEmitter()
        context.eventEmitter = emitter
        context.requestID = "request-123"
        
        // When
        await context.emitMiddlewareEvent(
            "middleware.executed",
            middleware: "TestMiddleware",
            properties: ["duration": 0.5]
        )
        
        // Then
        let lastEvent = await emitter.lastEvent()
        XCTAssertNotNil(lastEvent)
        XCTAssertEqual(lastEvent?.name, "middleware.executed")
        
        // Check properties
        if let props = lastEvent?.properties {
            XCTAssertEqual(props["middleware"]?.get(String.self), "TestMiddleware")
            XCTAssertEqual(props["duration"]?.get(Double.self), 0.5)
        }
        
        // Should use request ID as correlation ID
        XCTAssertEqual(lastEvent?.correlationID, "request-123")
    }
    
    func testMiddlewareEventWithTypedProperties() async throws {
        // Given
        let context = CommandContext()
        let emitter = TestEventEmitter()
        context.eventEmitter = emitter
        
        // When
        let typedProps: [String: Int] = ["retryCount": 3, "statusCode": 200]
        await context.emitMiddlewareEvent(
            "middleware.retry",
            middleware: "RetryMiddleware",
            properties: typedProps
        )
        
        // Then
        let lastEvent = await emitter.lastEvent()
        XCTAssertNotNil(lastEvent)
        
        if let props = lastEvent?.properties {
            XCTAssertEqual(props["retryCount"]?.get(Int.self), 3)
            XCTAssertEqual(props["statusCode"]?.get(Int.self), 200)
            XCTAssertEqual(props["middleware"]?.get(String.self), "RetryMiddleware")
        }
    }
    
    // MARK: - Multiple Events Tests
    
    func testMultipleEventEmission() async throws {
        // Given
        let context = CommandContext()
        let emitter = TestEventEmitter()
        context.eventEmitter = emitter
        
        // When
        for i in 1...5 {
            let event = PipelineEvent(
                name: "event.\(i)",
                correlationID: "test"
            )
            await context.emitEvent(event)
        }
        
        // Then
        let count = await emitter.eventCount()
        XCTAssertEqual(count, 5)
        
        let events = await emitter.capturedEvents
        XCTAssertEqual(events[0].name, "event.1")
        XCTAssertEqual(events[4].name, "event.5")
    }
    
    // MARK: - Context Forking Tests
    
    func testEmitterInheritanceOnFork() async throws {
        // Given
        let parentContext = CommandContext()
        let emitter = TestEventEmitter()
        parentContext.eventEmitter = emitter
        
        // When
        let childContext = await parentContext.fork()
        
        // Then - child should inherit the emitter
        let childEmitter = await childContext.eventEmitter
        XCTAssertNotNil(childEmitter)
        
        // Events from child should go to same emitter
        await childContext.emitEvent(PipelineEvent(
            name: "child.event",
            correlationID: "test"
        ))
        
        let count = await emitter.eventCount()
        XCTAssertEqual(count, 1)
    }
    
    func testEmitterCanBeOverriddenInChild() async throws {
        // Given
        let parentContext = CommandContext()
        let parentEmitter = TestEventEmitter()
        parentContext.eventEmitter = parentEmitter
        
        let childContext = await parentContext.fork()
        let childEmitter = TestEventEmitter()
        childContext.eventEmitter = childEmitter
        
        // When
        await parentContext.emitEvent(PipelineEvent(
            name: "parent.event",
            correlationID: "test"
        ))
        await childContext.emitEvent(PipelineEvent(
            name: "child.event",
            correlationID: "test"
        ))
        
        // Then
        let parentCount = await parentEmitter.eventCount()
        let childCount = await childEmitter.eventCount()
        
        XCTAssertEqual(parentCount, 1)
        XCTAssertEqual(childCount, 1)
        
        let parentEvent = await parentEmitter.lastEvent()
        let childEvent = await childEmitter.lastEvent()
        
        XCTAssertEqual(parentEvent?.name, "parent.event")
        XCTAssertEqual(childEvent?.name, "child.event")
    }
    
    // MARK: - Event Sequence ID Tests
    
    func testEventSequenceIDsAreMonotonic() async throws {
        // Given
        let context = CommandContext()
        let emitter = TestEventEmitter()
        context.eventEmitter = emitter
        
        // When - emit multiple events
        for i in 1...10 {
            let event = PipelineEvent(
                name: "event.\(i)",
                correlationID: "test"
            )
            await context.emitEvent(event)
        }
        
        // Then - sequence IDs should be monotonically increasing
        let events = await emitter.capturedEvents
        for i in 1..<events.count {
            XCTAssertGreaterThan(
                events[i].sequenceID,
                events[i - 1].sequenceID,
                "Sequence IDs should be monotonically increasing"
            )
        }
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentEventEmission() async throws {
        // Given
        let context = CommandContext()
        let emitter = TestEventEmitter()
        context.eventEmitter = emitter
        
        // When - emit events concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 1...100 {
                group.addTask {
                    let event = PipelineEvent(
                        name: "concurrent.event.\(i)",
                        correlationID: "test-\(i)"
                    )
                    await context.emitEvent(event)
                }
            }
        }
        
        // Then - all events should be captured
        let count = await emitter.eventCount()
        XCTAssertEqual(count, 100)
    }
}
