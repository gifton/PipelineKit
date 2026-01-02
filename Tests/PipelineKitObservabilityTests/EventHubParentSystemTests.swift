import XCTest
import PipelineKitCore
import PipelineKitObservability

/// Tests specifically for EventHub parent system relationship
final class EventHubParentSystemTests: XCTestCase {
    // MARK: - Parent System Reference Tests
    
    func testEventHubStoresParentSystemReference() async throws {
        let system = await ObservabilitySystem(configuration: .development)
        let hub = await system.getEventHub()
        
        let parent = await hub.getParentSystem()
        XCTAssertNotNil(parent, "EventHub should have parent system reference")
        XCTAssertTrue(parent === system, "Parent should be the creating system")
    }
    
    func testEventHubParentSystemIsWeak() async throws {
        weak var weakSystem: ObservabilitySystem?
        let hub: EventHub
        
        // Create system in inner scope
        do {
            let system = await ObservabilitySystem(configuration: .development)
            weakSystem = system
            hub = await system.getEventHub()
            
            // Verify parent exists while system is alive
            let parent = await hub.getParentSystem()
            XCTAssertNotNil(parent)
        }
        
        // System should be deallocated
        XCTAssertNil(weakSystem, "System should be deallocated")
        
        // Parent reference should be nil
        let parent = await hub.getParentSystem()
        XCTAssertNil(parent, "Parent should be nil after system deallocation")
    }
    
    func testManualParentSystemSetting() async throws {
        // Create standalone hub
        let hub = EventHub()
        
        // Initially no parent
        let initialParent = await hub.getParentSystem()
        XCTAssertNil(initialParent, "Standalone hub should have no parent")
        
        // Create and set parent
        let system = await ObservabilitySystem(configuration: .development)
        await hub.setParentSystem(system)
        
        // Verify parent is set
        let parent = await hub.getParentSystem()
        XCTAssertNotNil(parent)
        XCTAssertTrue(parent === system)
        
        // Clear parent
        await hub.setParentSystem(nil)
        let clearedParent = await hub.getParentSystem()
        XCTAssertNil(clearedParent, "Parent should be cleared")
    }
    
    func testEventHubWorksWithoutParent() async throws {
        // Create standalone hub
        let hub = EventHub()
        
        // Should function normally without parent
        let subscriber = MockSubscriber()
        await hub.subscribe(subscriber)
        
        // Emit event
        let event = PipelineEvent(
            name: "test",
            properties: [:],
            correlationID: "123"
        )
        await hub.emit(event)
        
        // Give time for async processing
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Verify event was processed
        let received = await subscriber.receivedEvents
        XCTAssertEqual(received.count, 1, "Should process events without parent")
    }
    
    // MARK: - System Retrieval Tests
    
    func testRetrieveSystemThroughEventHub() async throws {
        let originalSystem = await ObservabilitySystem(configuration: .development)
        let hub = await originalSystem.getEventHub()
        
        // Create context and set hub
        let context = CommandContext()
        context.eventEmitter = hub
        
        // Retrieve system through context
        let retrievedSystem = await context.observability
        XCTAssertNotNil(retrievedSystem)
        XCTAssertTrue(retrievedSystem === originalSystem, "Should retrieve same system instance")
    }
    
    func testCannotRetrieveSystemFromNonEventHub() async throws {
        let context = CommandContext()
        
        // Set non-EventHub emitter
        let customEmitter = SimpleEventEmitter()
        context.eventEmitter = customEmitter
        
        // Should not be able to retrieve system
        let system = await context.observability
        XCTAssertNil(system, "Should not retrieve system from non-EventHub emitter")
    }
    
    func testSystemRetrievalAfterParentDeallocation() async throws {
        let hub: EventHub
        
        // Create system in inner scope
        do {
            let system = await ObservabilitySystem(configuration: .development)
            hub = await system.getEventHub()
        }
        
        // System is deallocated, but hub exists
        let context = CommandContext()
        context.eventEmitter = hub
        
        // Should not retrieve deallocated system
        let retrievedSystem = await context.observability
        XCTAssertNil(retrievedSystem, "Should not retrieve deallocated system")
    }
    
    // MARK: - Multiple Systems Tests
    
    func testMultipleSystemsIndependence() async throws {
        // Create multiple independent systems
        let system1 = await ObservabilitySystem(configuration: .development)
        let system2 = await ObservabilitySystem(configuration: .production)
        let system3 = await ObservabilitySystem.test()
        
        let hub1 = await system1.getEventHub()
        let hub2 = await system2.getEventHub()
        let hub3 = await system3.getEventHub()
        
        // Each hub should reference its own system
        let parent1 = await hub1.getParentSystem()
        let parent2 = await hub2.getParentSystem()
        let parent3 = await hub3.getParentSystem()
        
        XCTAssertNotNil(parent1)
        XCTAssertNotNil(parent2)
        XCTAssertNotNil(parent3)
        
        XCTAssertTrue(parent1 === system1)
        XCTAssertTrue(parent2 === system2)
        XCTAssertTrue(parent3 === system3)
        
        // Systems should be different
        XCTAssertFalse(system1 === system2)
        XCTAssertFalse(system2 === system3)
        XCTAssertFalse(system1 === system3)
    }
    
    func testSwitchingBetweenSystems() async throws {
        let context = CommandContext()
        
        // Setup first system
        let system1 = await ObservabilitySystem(configuration: .development)
        let hub1 = await system1.getEventHub()
        context.eventEmitter = hub1
        
        let retrieved1 = await context.observability
        XCTAssertNotNil(retrieved1)
        XCTAssertTrue(retrieved1 === system1)
        
        // Switch to second system
        let system2 = await ObservabilitySystem(configuration: .production)
        let hub2 = await system2.getEventHub()
        context.eventEmitter = hub2
        
        let retrieved2 = await context.observability
        XCTAssertNotNil(retrieved2)
        XCTAssertTrue(retrieved2 === system2)
        XCTAssertFalse(retrieved1 === retrieved2)
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentParentSystemAccess() async throws {
        let system = await ObservabilitySystem(configuration: .development)
        let hub = await system.getEventHub()
        
        // Concurrent reads should be safe
        await withTaskGroup(of: ObservabilitySystem?.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await hub.getParentSystem()
                }
            }
            
            var results: [ObservabilitySystem?] = []
            for await result in group {
                results.append(result)
            }
            
            // All should return the same parent
            for result in results {
                XCTAssertNotNil(result)
                XCTAssertTrue(result === system)
            }
        }
    }
    
    func testConcurrentParentSystemModification() async throws {
        let hub = EventHub()
        let system1 = await ObservabilitySystem(configuration: .development)
        let system2 = await ObservabilitySystem(configuration: .production)
        
        // Concurrent modifications should be safe
        await withTaskGroup(of: Void.self) { group in
            // Alternate between setting different parents
            for i in 0..<100 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        await hub.setParentSystem(system1)
                    } else {
                        await hub.setParentSystem(system2)
                    }
                }
            }
        }
        
        // Final parent should be one of the systems
        let finalParent = await hub.getParentSystem()
        XCTAssertTrue(finalParent === system1 || finalParent === system2)
    }
}

// MARK: - Test Helpers

/// Simple event emitter for testing
final class SimpleEventEmitter: EventEmitter {
    func emit(_ event: PipelineEvent) {
        // No-op
    }
}

/// Mock subscriber for testing
actor MockSubscriber: EventSubscriber {
    var receivedEvents: [PipelineEvent] = []
    
    func process(_ event: PipelineEvent) async {
        receivedEvents.append(event)
    }
}
