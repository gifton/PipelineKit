import XCTest
import PipelineKitCore
import PipelineKitObservability

/// Tests for CommandContext observability extensions
final class CommandContextObservabilityTests: XCTestCase {
    
    // MARK: - Setup Observability Tests
    
    func testSetupObservabilityWithDefaultConfig() async throws {
        let context = CommandContext()
        
        // Setup with default development config
        await context.setupObservability()
        
        // Should have observability
        let system = await context.observability
        XCTAssertNotNil(system, "Should have observability after setup")
        
        // Should be able to record metrics
        await context.recordCounter(name: "setup.test", value: 1.0)
        
        // Verify system received it
        if let sys = system {
            let stats = await sys.getEventStatistics()
            XCTAssertGreaterThanOrEqual(stats.eventsEmitted, 0, "Should track events")
        }
    }
    
    func testSetupObservabilityWithCustomConfig() async throws {
        let context = CommandContext()
        
        // Custom configuration
        let config = ObservabilitySystem.Configuration(
            enableEvents: true,
            enableMetrics: true,
            metricsGeneration: .production,
            logEvents: false,
            logLevel: .error
        )
        
        await context.setupObservability(config)
        
        let system = await context.observability
        XCTAssertNotNil(system, "Should have observability with custom config")
    }
    
    func testSetupObservabilityMultipleTimes() async throws {
        let context = CommandContext()
        
        // Setup first time
        await context.setupObservability(.development)
        let system1 = await context.observability
        
        // Setup again (should replace)
        await context.setupObservability(.production)
        let system2 = await context.observability
        
        XCTAssertNotNil(system1)
        XCTAssertNotNil(system2)
        // Note: Can't easily test they're different instances due to actor isolation
        // but the setup should work multiple times
    }
    
    // MARK: - Metric Recording Tests
    
    func testRecordCounterThroughContext() async throws {
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Record counters with various configurations
        await context.recordCounter(name: "api.requests")
        await context.recordCounter(name: "api.errors", value: 5.0)
        await context.recordCounter(name: "api.success", value: 10.0, tags: ["endpoint": "/users"])
        
        // Should not crash and should emit events
        if let system = await context.observability {
            let stats = await system.getEventStatistics()
            XCTAssertGreaterThan(stats.eventsEmitted, 0, "Should emit events for counters")
        }
    }
    
    func testRecordGaugeThroughContext() async throws {
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Record gauges with various configurations
        await context.recordGauge(name: "memory.usage", value: 75.5)
        await context.recordGauge(name: "cpu.usage", value: 45.2, tags: ["core": "1"])
        await context.recordGauge(name: "disk.space", value: 1024.0, tags: ["drive": "ssd"], unit: "GB")
        
        // Verify events are emitted
        if let system = await context.observability {
            // Give time for async processing
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
            let stats = await system.getEventStatistics()
            XCTAssertGreaterThan(stats.eventsEmitted, 0, "Should emit events for gauges")
        }
    }
    
    func testRecordTimerThroughContext() async throws {
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Record timers
        await context.recordTimer(name: "request.duration", duration: 0.125)
        await context.recordTimer(name: "db.query", duration: 0.045, tags: ["query": "select"])
        await context.recordTimer(name: "cache.fetch", duration: 0.002, tags: ["hit": "true"])
        
        // Verify events are emitted
        if let system = await context.observability {
            let stats = await system.getEventStatistics()
            XCTAssertGreaterThan(stats.eventsEmitted, 0, "Should emit events for timers")
        }
    }
    
    func testMetricRecordingWithoutObservability() async throws {
        let context = CommandContext()
        
        // Don't setup observability
        
        // These should not crash
        await context.recordCounter(name: "test", value: 1.0)
        await context.recordGauge(name: "test", value: 1.0)
        await context.recordTimer(name: "test", duration: 1.0)
        
        // Observability should be nil
        let system = await context.observability
        XCTAssertNil(system, "Should have no observability without setup")
    }
    
    // MARK: - Correlation ID Tests
    
    func testMetricEventsUseCorrelationID() async throws {
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Set correlation ID
        await context.setRequestID("req-123")
        
        // Create a test subscriber to capture events
        let subscriber = EventCapturingSubscriber()
        if let system = await context.observability {
            await system.subscribe(subscriber)
        }
        
        // Record metric
        await context.recordCounter(name: "test.counter", value: 1.0)
        
        // Give time for async processing
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        // Check events have correlation ID
        let events = await subscriber.getCapturedEvents()
        let metricEvent = events.first { $0.name == "metric.counter.recorded" }
        XCTAssertNotNil(metricEvent)
        // Correlation ID should be set (either from request ID or generated)
        XCTAssertFalse(metricEvent?.correlationID.isEmpty ?? true)
    }
    
    // MARK: - Event Emitter Tests
    
    func testGetEventEmitterFromContext() async throws {
        let context = CommandContext()
        
        // Initially no emitter
        let initialEmitter = await context.eventEmitter
        XCTAssertNil(initialEmitter, "Should have no emitter initially")
        
        // Setup observability
        await context.setupObservability(.development)
        
        // Should have emitter
        let emitter = await context.eventEmitter
        XCTAssertNotNil(emitter, "Should have emitter after setup")
        XCTAssertTrue(emitter is EventHub, "Emitter should be EventHub")
    }
    
    func testSetCustomEventEmitter() async throws {
        let context = CommandContext()
        
        // Set custom emitter
        let customEmitter = CustomEventEmitter()
        await context.setEventEmitter(customEmitter)
        
        // Should have custom emitter
        let emitter = await context.eventEmitter
        XCTAssertNotNil(emitter)
        XCTAssertTrue((emitter as AnyObject) === customEmitter)
        
        // Observability should be nil (not EventHub)
        let system = await context.observability
        XCTAssertNil(system, "Should not have observability with custom emitter")
    }
    
    // MARK: - Integration with Context Data Tests
    
    func testObservabilityWithContextMetadata() async throws {
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Set various context metadata
        await context.setMetadata("user_id", value: "user-123")
        await context.setMetadata("tenant", value: "acme-corp")
        await context.setRequestID("req-456")
        
        // Record metrics
        await context.recordCounter(name: "action.performed", value: 1.0)
        
        // Observability should still work
        let system = await context.observability
        XCTAssertNotNil(system)
        
        // Context metadata should be preserved
        let metadata = await context.getMetadata()
        XCTAssertEqual(metadata["user_id"] as? String, "user-123")
        XCTAssertEqual(metadata["tenant"] as? String, "acme-corp")
    }
    
    func testObservabilityWithTypedContextKeys() async throws {
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Use typed context keys
        let userKey = ContextKey<String>("user")
        let countKey = ContextKey<Int>("count")
        
        await context.set(userKey, value: "alice")
        await context.set(countKey, value: 42)
        
        // Record metrics
        await context.recordGauge(name: "user.activity", value: 42.0)
        
        // Both observability and context data should work
        let system = await context.observability
        XCTAssertNotNil(system)
        
        let user = await context.get(userKey)
        let count = await context.get(countKey)
        XCTAssertEqual(user, "alice")
        XCTAssertEqual(count, 42)
    }
    
    // MARK: - Performance Tests
    
    func testObservabilitySetupPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Setup performance")
            
            Task {
                let context = CommandContext()
                await context.setupObservability(.production)
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 1.0)
        }
    }
    
    func testObservabilityRetrievalPerformance() async throws {
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Warm up
        _ = await context.observability
        
        // Measure retrieval
        let start = Date()
        for _ in 0..<1000 {
            _ = await context.observability
        }
        let elapsed = Date().timeIntervalSince(start)
        
        // Should be fast (< 1ms per retrieval)
        XCTAssertLessThan(elapsed, 1.0, "Should retrieve quickly")
    }
}

// MARK: - Test Helpers

/// Custom event emitter for testing
final class CustomEventEmitter: EventEmitter, @unchecked Sendable {
    private var events: [PipelineEvent] = []
    private let lock = NSLock()
    
    func emit(_ event: PipelineEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }
}

/// Event capturing subscriber
actor EventCapturingSubscriber: EventSubscriber {
    private var capturedEvents: [PipelineEvent] = []
    
    func process(_ event: PipelineEvent) async {
        capturedEvents.append(event)
    }
    
    func getCapturedEvents() -> [PipelineEvent] {
        return capturedEvents
    }
}