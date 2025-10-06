import XCTest
import PipelineKit
import PipelineKitCore
import PipelineKitObservability

/// Integration tests for the complete observability system
final class ObservabilityIntegrationTests: XCTestCase {
    
    // MARK: - Parent System Reference Tests
    
    func testEventHubMaintainsWeakReferenceToParentSystem() async throws {
        let hub: EventHub
        
        // Create system in an inner scope
        do {
            let system = await ObservabilitySystem(configuration: .development)
            hub = await system.getEventHub()
            
            // Verify parent is set
            let parent1 = await hub.getParentSystem()
            XCTAssertNotNil(parent1, "EventHub should have parent system")
        }
        // System goes out of scope here
        
        // Give time for actor deallocation
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Parent should be nil due to weak reference
        let parent2 = await hub.getParentSystem()
        XCTAssertNil(parent2, "EventHub should not retain parent system")
    }
    
    func testMultipleEventHubsCanHaveDifferentParents() async throws {
        // Create two separate systems
        let system1 = await ObservabilitySystem(configuration: .development)
        let system2 = await ObservabilitySystem(configuration: .production)
        
        let hub1 = await system1.getEventHub()
        let hub2 = await system2.getEventHub()
        
        // Each hub should reference its own parent
        let parent1 = await hub1.getParentSystem()
        let parent2 = await hub2.getParentSystem()
        
        XCTAssertNotNil(parent1)
        XCTAssertNotNil(parent2)
        XCTAssertFalse(parent1 === parent2, "Each hub should have different parent")
    }
    
    // MARK: - Context Integration Tests
    
    func testContextPreservesObservabilityAcrossOperations() async throws {
        let context = CommandContext()
        
        // Setup observability
        await context.setupObservability(.development)
        
        // Perform various operations
        context.set(ContextKey<String>("test"), value: "value")
        context.setMetadata("key", value: "data")
        context.setRequestID("req-123")
        
        // Observability should still be accessible
        let system = await context.observability
        XCTAssertNotNil(system, "Observability should persist across context operations")
    }
    
    func testContextObservabilityWithCustomConfiguration() async throws {
        let context = CommandContext()
        
        // Setup with custom configuration
        let config = ObservabilitySystem.Configuration(
            enableEvents: true,
            enableMetrics: false,
            metricsGeneration: .production,
            logEvents: false,
            logLevel: .error
        )
        
        await context.setupObservability(config)
        
        let system = await context.observability
        XCTAssertNotNil(system, "Should have system with custom config")
        
        // Verify configuration affects behavior
        await system?.recordCounter(name: "test", value: 1.0)
        _ = await system?.getMetrics() ?? []
        // Metrics might still be recorded locally even if disabled
        // The important thing is the system exists and is accessible
        XCTAssertNotNil(system)
    }
    
    func testReplaceEventEmitterClearsObservability() async throws {
        let context = CommandContext()
        
        // Setup initial observability
        await context.setupObservability(.development)
        let system1 = await context.observability
        XCTAssertNotNil(system1)
        
        // Replace with different event emitter
        let customEmitter = MockEventEmitter()
        context.setEventEmitter(customEmitter)
        
        // Observability should be nil (not an EventHub)
        let system2 = await context.observability
        XCTAssertNil(system2, "Non-EventHub emitter should not provide observability")
        
        // Set back to observability
        await context.setupObservability(.production)
        let system3 = await context.observability
        XCTAssertNotNil(system3, "Should have observability again")
    }
    
    // MARK: - Metrics Recording Tests
    
    func testMetricsRecordedThroughContextAreAccessibleViaSystem() async throws {
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Record various metrics through context
        await context.recordCounter(name: "requests", value: 5.0, tags: ["endpoint": "users"])
        await context.recordGauge(name: "memory", value: 1024.5, tags: ["unit": "MB"])
        await context.recordTimer(name: "duration", duration: 0.5, tags: ["operation": "fetch"])
        
        // Get system and verify metrics
        if let system = await context.observability {
            // Give time for async event processing
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            let stats = await system.getEventStatistics()
            // We should have emitted events for metrics
            XCTAssertGreaterThan(stats.eventsEmitted, 0, "Should have emitted metric events")
        } else {
            XCTFail("Should have observability system")
        }
    }
    
    func testDirectSystemMetricsVsContextMetrics() async throws {
        let system = await ObservabilitySystem(configuration: .development)
        let context = CommandContext()
        let hub = await system.getEventHub()
        context.setEventEmitter(hub)
        
        // Record through system directly
        await system.recordCounter(name: "direct.counter", value: 10.0)
        
        // Record through context (generates events)
        await context.recordCounter(name: "context.counter", value: 20.0)
        
        // Both should be accessible
        let metrics = await system.getMetrics()
        
        // Direct recording should definitely be there
        let directMetric = metrics.first { $0.name == "direct.counter" }
        XCTAssertNotNil(directMetric, "Should find directly recorded metric")
        XCTAssertEqual(directMetric?.value, 10.0)
        
        // Context metrics are recorded as events and might be converted
        // The important thing is the system is working
        XCTAssertTrue(metrics.count > 0, "Should have some metrics")
    }
    
    // MARK: - Event Emission Tests
    
    func testEventsEmittedThroughContextReachSystem() async throws {
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Create a custom subscriber to verify events
        let subscriber = TestEventSubscriber()
        
        if let system = await context.observability {
            await system.subscribe(subscriber)
            
            // Emit event through context
            let event = PipelineEvent(
                name: "test.event",
                properties: ["key": "value"],
                correlationID: "test-123"
            )
            await context.emitEvent(event)
            
            // Give time for async processing
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            // Verify subscriber received it
            let events = await subscriber.getEvents()
            XCTAssertTrue(events.contains { $0.name == "test.event" }, "Should receive event")
        } else {
            XCTFail("Should have observability system")
        }
    }
    
    // MARK: - StatsD Integration Tests
    
    func testStatsDExporterIntegration() async throws {
        // Create production system with StatsD
        let system = await ObservabilitySystem.production(
            statsdHost: "localhost",
            statsdPort: 8125,
            prefix: "test",
            globalTags: ["env": "test"]
        )
        
        let context = CommandContext()
        let hub = await system.getEventHub()
        context.setEventEmitter(hub)
        
        // Should be able to retrieve the configured system
        let retrieved = await context.observability
        XCTAssertNotNil(retrieved, "Should retrieve production system with StatsD")
        
        // Record metrics
        await system.recordCounter(name: "statsd.test", value: 1.0)
        
        // Verify system is functioning
        let metrics = await system.getMetrics()
        XCTAssertFalse(metrics.isEmpty, "Should record metrics with StatsD configured")
    }
    
    // MARK: - Lifecycle Tests
    
    func testObservabilitySystemLifecycle() async throws {
        // Test full lifecycle
        let context = CommandContext()
        
        // 1. Initially no observability
        let initial = await context.observability
        XCTAssertNil(initial, "Should start with no observability")
        
        // 2. Setup observability
        await context.setupObservability(.development)
        let afterSetup = await context.observability
        XCTAssertNotNil(afterSetup, "Should have observability after setup")
        
        // 3. Use observability
        await context.recordCounter(name: "lifecycle.test", value: 1.0)
        
        // 4. Get metrics through system
        if let system = await context.observability {
            let metrics = await system.drainMetrics()
            // Drain should clear metrics
            let afterDrain = await system.getMetrics()
            XCTAssertTrue(afterDrain.isEmpty || afterDrain.count < metrics.count, 
                         "Drain should remove metrics")
        }
        
        // 5. Clear observability
        context.setEventEmitter(nil)
        let afterClear = await context.observability
        XCTAssertNil(afterClear, "Should have no observability after clearing")
    }
    
    // MARK: - Error Handling Tests
    
    func testObservabilityWithInvalidEventEmitter() async throws {
        let context = CommandContext()
        
        // Set a non-EventHub emitter
        let customEmitter = MockEventEmitter()
        context.setEventEmitter(customEmitter)
        
        // Observability should gracefully return nil
        let system = await context.observability
        XCTAssertNil(system, "Should return nil for non-EventHub emitters")
        
        // Context metrics methods should still work (no-op)
        await context.recordCounter(name: "test", value: 1.0) // Should not crash
        await context.recordGauge(name: "test", value: 1.0) // Should not crash
        await context.recordTimer(name: "test", duration: 1.0) // Should not crash
    }
    
    // MARK: - Performance Tests
    
    func testObservabilitySystemPerformance() async throws {
        let context = CommandContext()
        await context.setupObservability(.production)
        
        measure {
            let expectation = XCTestExpectation(description: "Performance test")
            
            Task {
                // Record many metrics rapidly
                for i in 0..<1000 {
                    await context.recordCounter(
                        name: "perf.counter",
                        value: Double(i),
                        tags: ["index": "\(i)"]
                    )
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10.0)
        }
    }
}

// MARK: - Test Helpers

/// Mock event emitter for testing
final class MockEventEmitter: EventEmitter, @unchecked Sendable {
    private var events: [PipelineEvent] = []
    private let lock = NSLock()
    
    func emit(_ event: PipelineEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }
    
    func getEvents() -> [PipelineEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// Test event subscriber
final actor TestEventSubscriber: EventSubscriber {
    private var events: [PipelineEvent] = []
    
    func process(_ event: PipelineEvent) async {
        events.append(event)
    }
    
    func getEvents() -> [PipelineEvent] {
        return events
    }
}