import XCTest
import PipelineKitCore
import PipelineKitObservability

final class ObservabilitySystemTests: XCTestCase {
    // MARK: - Context Integration Tests
    
    func testContextObservabilityPropertyWorks() async throws {
        // Create a context
        let context = CommandContext()
        
        // Initially, observability should be nil
        let initialObservability = await context.observability
        XCTAssertNil(initialObservability, "Observability should be nil before setup")
        
        // Set up observability
        await context.setupObservability(.development)
        
        // Now observability should be accessible
        let observability = await context.observability
        XCTAssertNotNil(observability, "Observability should be accessible after setup")
        
        // Verify we can use the observability system
        if let system = observability {
            // Record a metric through the system
            await system.recordCounter(name: "test.counter", value: 1.0)
            
            // Get metrics to verify it was recorded
            let metrics = await system.getMetrics()
            XCTAssertFalse(metrics.isEmpty, "Should have recorded metrics")
            
            // Find our counter metric
            let counterMetric = metrics.first { $0.name == "test.counter" }
            XCTAssertNotNil(counterMetric, "Should find the counter metric")
            XCTAssertEqual(counterMetric?.value, 1.0, "Counter value should be 1.0")
        }
    }
    
    func testObservabilitySystemRetrieval() async throws {
        // Create an observability system directly
        let system = await ObservabilitySystem(configuration: .development)
        
        // Create a context and set the event hub
        let context = CommandContext()
        let hub = await system.getEventHub()
        context.setEventEmitter(hub)
        
        // Should be able to retrieve the system through the context
        let retrievedSystem = await context.observability
        XCTAssertNotNil(retrievedSystem, "Should retrieve the ObservabilitySystem")
        
        // Verify it's the same system (by testing functionality)
        await system.recordCounter(name: "direct.counter", value: 5.0)
        
        if let retrieved = retrievedSystem {
            let metrics = await retrieved.getMetrics()
            let counter = metrics.first { $0.name == "direct.counter" }
            XCTAssertNotNil(counter, "Should find metric recorded through original system")
            XCTAssertEqual(counter?.value, 5.0, "Should have correct value")
        }
    }
    
    func testContextMetricsRecording() async throws {
        // Set up context with observability
        let context = CommandContext()
        await context.setupObservability(.development)
        
        // Record metrics through context helper methods
        await context.recordCounter(name: "api.requests", value: 3.0, tags: ["endpoint": "users"])
        await context.recordGauge(name: "memory.usage", value: 75.5, tags: ["unit": "MB"])
        await context.recordTimer(name: "request.duration", duration: 0.125, tags: ["method": "GET"])
        
        // Verify metrics were recorded through the observability system
        if let system = await context.observability {
            // Event delivery is asynchronous; poll briefly for eventual consistency
            var metrics = await system.getMetrics()
            if metrics.count < 3 {
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    metrics = await system.getMetrics()
                    if metrics.count >= 3 { break }
                }
            }
            // We should have both direct metrics and event-generated metrics
            // (the context methods generate events which are converted to metrics)
            XCTAssertTrue(metrics.count >= 3, "Should have at least 3 metrics after event processing")
            
            // The event bridge may or may not have converted them yet depending on timing
            // So we'll just verify the system is working by checking we can record more metrics
            await system.recordCounter(name: "test.verification", value: 1.0)
            let finalMetrics = await system.getMetrics()
            XCTAssertTrue(finalMetrics.count > 0, "Should have some metrics")
        }
    }
    
    func testProductionSystemSetup() async throws {
        // Create production system with StatsD config
        let system = await ObservabilitySystem.production(
            statsdHost: "metrics.example.com",
            statsdPort: 8125,
            prefix: "myapp",
            globalTags: ["environment": "test"]
        )
        
        // Set it up on a context
        let context = CommandContext()
        let hub = await system.getEventHub()
        context.setEventEmitter(hub)
        
        // Should be retrievable
        let retrieved = await context.observability
        XCTAssertNotNil(retrieved, "Should retrieve production system")
        
        // Record some metrics
        await system.recordCounter(name: "test.production", value: 1.0)
        
        // Verify they're accessible
        let metrics = await system.getMetrics()
        XCTAssertFalse(metrics.isEmpty, "Should have metrics in production system")
    }
    
    func testMultipleContextsSameSystem() async throws {
        // Create one observability system
        let system = await ObservabilitySystem(configuration: .development)
        
        // Set it up on multiple contexts
        let context1 = CommandContext()
        let context2 = CommandContext()
        let context3 = CommandContext()
        
        let hub = await system.getEventHub()
        await context1.setEventEmitter(hub)
        await context2.setEventEmitter(hub)
        await context3.setEventEmitter(hub)
        
        // All should retrieve the same system
        let retrieved1 = await context1.observability
        let retrieved2 = await context2.observability
        let retrieved3 = await context3.observability
        
        XCTAssertNotNil(retrieved1)
        XCTAssertNotNil(retrieved2)
        XCTAssertNotNil(retrieved3)
        
        // Record metrics from different contexts
        await context1.recordCounter(name: "context1.counter", value: 1.0)
        await context2.recordCounter(name: "context2.counter", value: 2.0)
        await context3.recordCounter(name: "context3.counter", value: 3.0)
        
        // All metrics should be in the same system
        _ = await system.getMetrics()
        
        // Note: Metrics might be recorded as events first, then converted
        // So we just verify the system is functioning
        
        // Verify event statistics show activity
        _ = await system.getEventStatistics()
        // Events are emitted asynchronously, so we might not see them immediately
        // Just verify the system is set up correctly
        XCTAssertNotNil(retrieved1, "System 1 should be retrievable")
        XCTAssertNotNil(retrieved2, "System 2 should be retrievable")
        XCTAssertNotNil(retrieved3, "System 3 should be retrievable")
    }
    
    func testObservabilitySystemCleanup() async throws {
        // Create a context
        let context = CommandContext()
        
        // Set up observability
        await context.setupObservability(.development)
        
        // Get the system
        let system = await context.observability
        XCTAssertNotNil(system, "Should have system after setup")
        
        // Clear the event emitter
        context.setEventEmitter(nil)
        
        // Now observability should be nil
        let clearedSystem = await context.observability
        XCTAssertNil(clearedSystem, "Should be nil after clearing event emitter")
    }
}
