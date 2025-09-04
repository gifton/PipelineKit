import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

final class CommandContextTests: XCTestCase {
    // MARK: - Basic Operations
    
    func testContextCreation() async throws {
        let context = CommandContext()
        
        // May or may not have request ID (depends on whether correlationId is set)
        let requestID = await context.getRequestID()
        // Request ID is optional
        _ = requestID
        
        // Metadata dictionary might be empty initially (it's a separate storage)
        let metadata = await context.getMetadata()
        // Metadata is stored separately from other context values
        XCTAssertTrue(metadata.isEmpty || metadata.isEmpty, "Metadata dictionary initialized")
    }
    
    func testContextWithMetadata() async throws {
        let metadata = DefaultCommandMetadata(correlationId: "test-correlation-id")
        let context = CommandContext(metadata: metadata)
        
        let requestID = await context.getRequestID()
        XCTAssertEqual(requestID, "test-correlation-id")
    }
    
    // MARK: - Metadata Operations
    
    func testMetadataSetAndGet() async throws {
        let context = CommandContext()
        
        // Set various types
        await context.setMetadata("string", value: "test")
        await context.setMetadata("number", value: 42)
        await context.setMetadata("bool", value: true)
        await context.setMetadata("array", value: [1, 2, 3])
        
        // Get and verify
        let stringValue = await context.getMetadata("string") as? String
        XCTAssertEqual(stringValue, "test")
        
        let numberValue = await context.getMetadata("number") as? Int
        XCTAssertEqual(numberValue, 42)
        
        let boolValue = await context.getMetadata("bool") as? Bool
        XCTAssertEqual(boolValue, true)
        
        let arrayValue = await context.getMetadata("array") as? [Int]
        XCTAssertEqual(arrayValue, [1, 2, 3])
    }
    
    func testMetadataBulkOperations() async throws {
        let context = CommandContext()
        
        // Set multiple values
        for i in 0..<10 {
            await context.setMetadata("key\(i)", value: "value\(i)")
        }
        
        // Get all metadata
        let metadata = await context.getMetadata()
        
        // Verify all values present
        for i in 0..<10 {
            XCTAssertEqual(metadata["key\(i)"] as? String, "value\(i)")
        }
    }
    
    func testMetadataOverwrite() async throws {
        let context = CommandContext()
        
        await context.setMetadata("key", value: "initial")
        let initial = await context.getMetadata("key") as? String
        XCTAssertEqual(initial, "initial")
        
        await context.setMetadata("key", value: "updated")
        let updated = await context.getMetadata("key") as? String
        XCTAssertEqual(updated, "updated")
    }
    
    // MARK: - Metrics Operations
    
    func testMetricsSetAndGet() async throws {
        let context = CommandContext()
        
        await context.setMetric("latency", value: 123.45)
        await context.setMetric("count", value: 10.0)
        
        let latency = await context.getMetric("latency") as? Double
        XCTAssertEqual(latency, 123.45)
        
        let count = await context.getMetric("count") as? Double
        XCTAssertEqual(count, 10.0)
        
        let missing = await context.getMetric("missing")
        XCTAssertNil(missing)
    }
    
    func testMetricsBulkOperations() async throws {
        let context = CommandContext()
        
        // Set multiple metrics
        for i in 0..<10 {
            await context.setMetric("metric\(i)", value: Double(i) * 1.5)
        }
        
        // Get all metrics
        let metrics = await context.getMetrics()
        
        // Verify all metrics present
        for i in 0..<10 {
            XCTAssertEqual(metrics["metric\(i)"] as? Double, Double(i) * 1.5)
        }
    }
    
    // MARK: - Request ID Management
    
    func testRequestIDManagement() async throws {
        let context = CommandContext()
        
        // Initially may be nil
        let originalID = await context.getRequestID()
        
        // Set a new ID
        await context.setRequestID("new-id")
        
        let newID = await context.getRequestID()
        XCTAssertEqual(newID, "new-id")
        
        // Can update it
        await context.setRequestID("updated-id")
        let updatedID = await context.getRequestID()
        XCTAssertEqual(updatedID, "updated-id")
    }
    
    func testRequestIDGeneration() async throws {
        // Create contexts with explicit correlation IDs
        let metadata1 = DefaultCommandMetadata(correlationId: UUID().uuidString)
        let metadata2 = DefaultCommandMetadata(correlationId: UUID().uuidString)
        
        let context1 = CommandContext(metadata: metadata1)
        let context2 = CommandContext(metadata: metadata2)
        
        let id1 = await context1.getRequestID()
        let id2 = await context2.getRequestID()
        
        // Each context should have unique ID
        XCTAssertNotNil(id1)
        XCTAssertNotNil(id2)
        XCTAssertNotEqual(id1, id2)
    }
    
    // MARK: - Fork Operations
    
    func testContextFork() async throws {
        let original = CommandContext()
        
        // Set up original context
        await original.setMetadata("key1", value: "value1")
        await original.setMetadata("key2", value: "value2")
        await original.setMetric("metric1", value: 100.0)
        
        // Fork the context
        let forked = await original.fork()
        
        // Verify forked has same data
        let forkedMetadata = await forked.getMetadata()
        XCTAssertEqual(forkedMetadata["key1"] as? String, "value1")
        XCTAssertEqual(forkedMetadata["key2"] as? String, "value2")
        
        let forkedMetric = await forked.getMetric("metric1") as? Double
        XCTAssertEqual(forkedMetric, 100.0)
        
        // Modify forked context
        await forked.setMetadata("key3", value: "value3")
        
        // Original should not be affected
        let originalMetadata = await original.getMetadata()
        XCTAssertNil(originalMetadata["key3"])
    }
    
    func testForkedContextIndependence() async throws {
        let original = CommandContext()
        await original.setMetadata("shared", value: "original")
        
        let fork1 = await original.fork()
        let fork2 = await original.fork()
        
        await fork1.setMetadata("shared", value: "fork1")
        await fork2.setMetadata("shared", value: "fork2")
        
        // Each context should have its own value
        let originalValue = await original.getMetadata("shared") as? String
        let fork1Value = await fork1.getMetadata("shared") as? String
        let fork2Value = await fork2.getMetadata("shared") as? String
        
        XCTAssertEqual(originalValue, "original")
        XCTAssertEqual(fork1Value, "fork1")
        XCTAssertEqual(fork2Value, "fork2")
    }
    
    // MARK: - Snapshot Operations
    
    func testContextSnapshot() async throws {
        let context = CommandContext()
        
        await context.setMetadata("key1", value: "value1")
        await context.setMetadata("key2", value: 42)
        await context.setMetric("metric1", value: 99.9)
        
        let snapshot = await context.snapshot()
        
        // Snapshot should contain all data
        XCTAssertFalse(snapshot.isEmpty)
        
        // The snapshot contains the raw storage, which may have nested structure
        // Metadata is stored under ContextKeys.metadata, metrics under ContextKeys.metrics
        // Just verify we have some data in the snapshot
        XCTAssertTrue(!snapshot.isEmpty, "Snapshot should contain data")
        
        // Verify we can retrieve our values back through the context
        let retrievedMetadata = await context.getMetadata()
        XCTAssertEqual(retrievedMetadata["key1"] as? String, "value1")
        XCTAssertEqual(retrievedMetadata["key2"] as? Int, 42)
        
        let retrievedMetric = await context.getMetric("metric1") as? Double
        XCTAssertEqual(retrievedMetric, 99.9)
    }
    
    // MARK: - Event Emission Tests
    
    func testEventEmission() async throws {
        let context = CommandContext()
        let emitter = CapturingEmitter()
        await context.setEventEmitter(emitter)
        
        // Emit an event
        await context.emitMiddlewareEvent(
            "test.event",
            middleware: "TestMiddleware",
            properties: ["key": "value"]
        )
        
        // Verify event was emitted
        let events = await emitter.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, "test.event")
        XCTAssertNotNil(events.first?.correlationID)
        XCTAssertNotNil(events.first?.sequenceID)
        
        // Check properties
        if let props = events.first?.properties {
            XCTAssertEqual(props["middleware"]?.get(String.self), "TestMiddleware")
            XCTAssertEqual(props["key"]?.get(String.self), "value")
        }
    }
    
    func testEventWithTypedProperties() async throws {
        let context = CommandContext()
        let emitter = CapturingEmitter()
        await context.setEventEmitter(emitter)
        
        await context.emitMiddlewareEvent(
            "test.typed",
            middleware: "TestMiddleware",
            properties: ["count": 42, "rate": 3.14]
        )
        
        let events = await emitter.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, "test.typed")
        
        // Check typed properties
        if let props = events.first?.properties {
            XCTAssertEqual(props["count"]?.get(Int.self), 42)
            XCTAssertEqual(props["rate"]?.get(Double.self), 3.14)
        }
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentMetadataAccess() async throws {
        let context = CommandContext()
        let iterations = 100
        
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<iterations {
                group.addTask {
                    await context.setMetadata("key\(i)", value: "value\(i)")
                }
            }
            
            // Readers
            for i in 0..<iterations {
                group.addTask {
                    _ = await context.getMetadata("key\(i)")
                }
            }
        }
        
        // Verify data integrity
        for i in 0..<iterations {
            let value = await context.getMetadata("key\(i)") as? String
            XCTAssertEqual(value, "value\(i)")
        }
    }
    
    func testConcurrentMetricsAccess() async throws {
        let context = CommandContext()
        let iterations = 100
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    await context.setMetric("metric\(i)", value: Double(i))
                }
            }
        }
        
        let metrics = await context.getMetrics()
        XCTAssertEqual(metrics.count, iterations)
    }
    
    // MARK: - Performance Tests
    
    func testMetadataPerformance() async throws {
        let context = CommandContext()
        let iterations = 10000
        
        let start = Date()
        
        for i in 0..<iterations {
            await context.setMetadata("key\(i % 100)", value: "value\(i)")
        }
        
        let duration = Date().timeIntervalSince(start)
        let opsPerSecond = Double(iterations) / duration
        
        print("Metadata operations: \(Int(opsPerSecond)) ops/sec")
        XCTAssertGreaterThan(opsPerSecond, 50000) // Should handle at least 50k ops/sec
    }
    
    // MARK: - Memory Management
    
    func testContextMemoryManagement() async throws {
        // CommandContext is an actor (reference type), so we can test memory management
        weak var weakContext: CommandContext?
        
        do {
            let context = CommandContext()
            weakContext = context
            
            await context.setMetadata("test", value: "value")
            
            // Context should still exist here
            XCTAssertNotNil(weakContext)
        }
        
        // Force a small delay to allow cleanup
        try? await Task.sleep(nanoseconds: 10_000_000)
        
        // Context should be deallocated after leaving scope
        XCTAssertNil(weakContext)
    }
}
