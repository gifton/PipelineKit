import XCTest
@testable import PipelineKitCore

final class CommandContextTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testInitWithDefaultMetadata() async {
        let context = CommandContext()
        
        // Verify basic properties are initialized
        // CommandContext is an actor, so we can't access commandMetadata directly
        // Instead, verify through the methods that use it
        _ = context.getUserID()
        let startTime = context.getStartTime()
        // By default, startTime is unset until explicitly provided
        XCTAssertNil(startTime)
    }
    
    func testInitWithCustomMetadata() async {
        let metadata = TestCommandMetadata(
            userID: "user123",
            correlationID: "corr456"
        )
        let context = CommandContext(metadata: metadata)
        
        // Verify metadata is properly stored
        let userId = context.getUserID()
        let correlationId = context.getCorrelationID()
        let requestId = context.getRequestID()
        
        XCTAssertEqual(userId, "user123")
        XCTAssertEqual(correlationId, "corr456")
        XCTAssertEqual(requestId, "corr456") // Should be set from correlationID
    }
    
    // MARK: - Typed Key Access Tests
    
    func testTypedKeyGetSet() async {
        let context = CommandContext()
        let testKey = ContextKey<String>("testKey")
        
        // Test setting and getting
        context.set(testKey, value: "testValue")
        let value = context.get(testKey)
        XCTAssertEqual(value, "testValue")
        
        // Test removing
        context.set(testKey, value: nil)
        let removedValue = context.get(testKey)
        XCTAssertNil(removedValue)
    }
    
    func testTypedKeyWithDifferentTypes() async {
        let context = CommandContext()
        
        let stringKey = ContextKey<String>("string")
        let intKey = ContextKey<Int>("int")
        let doubleKey = ContextKey<Double>("double")
        let boolKey = ContextKey<Bool>("bool")
        let dateKey = ContextKey<Date>("date")
        
        let testDate = Date()
        
        context.set(stringKey, value: "test")
        context.set(intKey, value: 42)
        context.set(doubleKey, value: 3.14)
        context.set(boolKey, value: true)
        context.set(dateKey, value: testDate)
        
        let stringValue = context.get(stringKey)
        let intValue = context.get(intKey)
        let doubleValue = context.get(doubleKey)
        let boolValue = context.get(boolKey)
        let dateValue = context.get(dateKey)
        
        XCTAssertEqual(stringValue, "test")
        XCTAssertEqual(intValue, 42)
        XCTAssertEqual(doubleValue, 3.14)
        XCTAssertEqual(boolValue, true)
        XCTAssertEqual(dateValue, testDate)
    }
    
    func testTypedKeyTypeySafety() async {
        let context = CommandContext()
        let stringKey = ContextKey<String>("test")
        
        context.set(stringKey, value: "stringValue")
        
        // Try to get with wrong type - should return nil due to type mismatch
        let intKey = ContextKey<Int>("test") // Same name, different type
        let wrongTypeValue = context.get(intKey)
        XCTAssertNil(wrongTypeValue)
    }
    
    // MARK: - Direct Property Access Tests
    
    func testRequestIDGetSet() async {
        let context = CommandContext()
        
        context.setRequestID("req123")
        let requestId = context.getRequestID()
        XCTAssertEqual(requestId, "req123")
        
        context.setRequestID(nil)
        let clearedId = context.getRequestID()
        XCTAssertNil(clearedId)
    }
    
    func testUserIDGetSet() async {
        let context = CommandContext()
        
        context.setUserID("user456")
        let userId = context.getUserID()
        XCTAssertEqual(userId, "user456")
        
        context.setUserID(nil)
        let clearedId = context.getUserID()
        XCTAssertNil(clearedId)
    }
    
    func testCorrelationIDGetSet() async {
        let context = CommandContext()
        
        context.setCorrelationID("corr789")
        let correlationId = context.getCorrelationID()
        XCTAssertEqual(correlationId, "corr789")
        
        context.setCorrelationID(nil)
        let clearedId = context.getCorrelationID()
        XCTAssertNil(clearedId)
    }
    
    func testStartTimeGetSet() async {
        let context = CommandContext()
        let testTime = Date()
        
        context.setStartTime(testTime)
        let startTime = context.getStartTime()
        XCTAssertEqual(startTime, testTime)
        
        context.setStartTime(nil)
        let clearedTime = context.getStartTime()
        XCTAssertNil(clearedTime)
    }
    
    // MARK: - Metadata Operations Tests
    
    func testMetadataOperations() async {
        let context = CommandContext()
        
        // Test setting individual metadata
        context.setMetadata("key1", value: "value1")
        context.setMetadata("key2", value: 42)
        
        let value1 = context.getMetadata("key1") as? String
        let value2 = context.getMetadata("key2") as? Int
        
        XCTAssertEqual(value1, "value1")
        XCTAssertEqual(value2, 42)
        
        // Test getting all metadata
        let allMetadata = context.getMetadata()
        XCTAssertEqual(allMetadata["key1"] as? String, "value1")
        XCTAssertEqual(allMetadata["key2"] as? Int, 42)
    }
    
    func testMetadataUpdate() async {
        let context = CommandContext()
        
        context.setMetadata("existing", value: "old")
        context.updateMetadata([
            "existing": "new",
            "added": "value"
        ])
        
        let metadata = context.getMetadata()
        XCTAssertEqual(metadata["existing"] as? String, "new")
        XCTAssertEqual(metadata["added"] as? String, "value")
    }
    
    func testMetadataReplace() async {
        let context = CommandContext()
        
        context.setMetadata("key1", value: "value1")
        context.setMetadata("key2", value: "value2")
        
        let newMetadata: [String: any Sendable] = ["key3": "value3"]
        context.setMetadata(newMetadata)
        
        let metadata = context.getMetadata()
        XCTAssertNil(metadata["key1"])
        XCTAssertNil(metadata["key2"])
        XCTAssertEqual(metadata["key3"] as? String, "value3")
    }
    
    // MARK: - Metrics Operations Tests
    
    func testMetricsOperations() async {
        let context = CommandContext()
        
        // Test setting individual metrics
        context.setMetric("latency", value: 0.125)
        context.setMetric("count", value: 100)
        
        let latency = context.getMetric("latency") as? Double
        let count = context.getMetric("count") as? Int
        
        XCTAssertEqual(latency, 0.125)
        XCTAssertEqual(count, 100)
        
        // Test storeMetric (alias)
        context.storeMetric("throughput", value: 1000.0)
        let throughput = context.getMetric("throughput") as? Double
        XCTAssertEqual(throughput, 1000.0)
    }
    
    func testMetricsUpdate() async {
        let context = CommandContext()
        
        context.setMetric("metric1", value: 1)
        context.updateMetrics([
            "metric1": 2,
            "metric2": 3
        ])
        
        let metrics = context.getMetrics()
        XCTAssertEqual(metrics["metric1"] as? Int, 2)
        XCTAssertEqual(metrics["metric2"] as? Int, 3)
    }
    
    func testRecordDuration() async throws {
        let context = CommandContext()
        let startTime = Date()
        context.setStartTime(startTime)
        
        // Wait a small amount
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        context.recordDuration()
        
        let duration = context.getMetric("duration") as? TimeInterval
        XCTAssertNotNil(duration)
        XCTAssertGreaterThan(duration!, 0)
        XCTAssertLessThan(duration!, 1.0) // Should be less than 1 second
    }
    
    func testRecordDurationWithCustomName() async throws {
        let context = CommandContext()
        let startTime = Date()
        context.setStartTime(startTime)
        
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        context.recordDuration("customDuration")
        
        let duration = context.getMetric("customDuration") as? TimeInterval
        XCTAssertNotNil(duration)
        XCTAssertGreaterThan(duration!, 0)
    }
    
    func testRecordDurationWithoutStartTime() async {
        let context = CommandContext()
        // Don't set start time
        
        context.recordDuration()
        
        // Should not crash, just not record anything
        let duration = context.getMetric("duration")
        XCTAssertNil(duration)
    }
    
    // MARK: - Utility Methods Tests
    
    func testClear() async {
        let metadata = TestCommandMetadata(
            userID: "user123",
            correlationID: "corr456"
        )
        let context = CommandContext(metadata: metadata)
        
        // Add some data
        context.setMetadata("key", value: "value")
        context.setMetric("metric", value: 123)
        let testKey = ContextKey<String>("test")
        context.set(testKey, value: "testValue")
        
        // Clear
        context.clear()
        
        // Verify custom data is cleared
        let clearedMeta = context.getMetadata("key")
        XCTAssertNil(clearedMeta)
        let clearedMetric = context.getMetric("metric")
        XCTAssertNil(clearedMetric)
        let clearedValue = context.get(testKey)
        XCTAssertNil(clearedValue)
        
        // Verify command metadata is preserved
        let userId = context.getUserID()
        XCTAssertEqual(userId, "user123")
        let correlationId = context.getCorrelationID()
        XCTAssertEqual(correlationId, "corr456")
    }
    
    func testSnapshot() async {
        let context = CommandContext()
        
        context.setRequestID("req123")
        context.setMetadata("meta", value: "data")
        context.setMetric("metric", value: 456)
        
        let snapshot = context.snapshot()
        
        // Verify snapshot contains data
        XCTAssertNotNil(snapshot["commandMetadata"])
        XCTAssertNotNil(snapshot[ContextKeys.requestID.name])
        XCTAssertNotNil(snapshot[ContextKeys.metadata.name])
        XCTAssertNotNil(snapshot[ContextKeys.metrics.name])
    }
    
    func testSnapshotRaw() async {
        let context = CommandContext()
        
        context.setRequestID("req123")
        context.setMetadata("meta", value: "data")
        
        let snapshot = context.snapshotRaw()
        
        // Verify raw snapshot contains AnySendable wrappers
        XCTAssertNotNil(snapshot["commandMetadata"])
        XCTAssertNotNil(snapshot[ContextKeys.requestID.name])
        
        // Verify we can extract values from AnySendable
        if let wrapper = snapshot[ContextKeys.requestID.name] {
            let value = wrapper.get(String.self)
            XCTAssertEqual(value, "req123")
        }
    }
    
    func testContains() async {
        let context = CommandContext()
        let key = ContextKey<String>("test")
        
        let contains1 = context.contains(key)
        XCTAssertFalse(contains1)
        
        context.set(key, value: "value")
        let contains2 = context.contains(key)
        XCTAssertTrue(contains2)
        
        context.remove(key)
        let contains3 = context.contains(key)
        XCTAssertFalse(contains3)
    }
    
    func testRemove() async {
        let context = CommandContext()
        let key = ContextKey<String>("test")
        
        context.set(key, value: "value")
        let beforeRemove = context.get(key)
        XCTAssertNotNil(beforeRemove)
        
        context.remove(key)
        let afterRemove = context.get(key)
        XCTAssertNil(afterRemove)
    }
    
    func testUpdate() async {
        let context = CommandContext()
        
        context.update { ctx in
            ctx.setRequestID("req123")
            ctx.setUserID("user456")
            ctx.setMetadata("key", value: "value")
        }
        
        let requestId = context.getRequestID()
        XCTAssertEqual(requestId, "req123")
        let userId = context.getUserID()
        XCTAssertEqual(userId, "user456")
        let metaValue = context.getMetadata("key") as? String
        XCTAssertEqual(metaValue, "value")
    }
    
    // MARK: - Cancellation Support Tests
    
    func testCancellationSupport() async {
        let context = CommandContext()
        
        let isCancelled1 = context.isCancelled
        XCTAssertFalse(isCancelled1)
        let reason0 = context.getCancellationReason()
        XCTAssertNil(reason0)
        
        context.markAsCancelled(reason: .timeout(duration: 5.0, gracePeriod: nil))
        
        let isCancelled2 = context.isCancelled
        XCTAssertTrue(isCancelled2)
        let reason = context.getCancellationReason()
        XCTAssertEqual(reason, .timeout(duration: 5.0, gracePeriod: nil))
    }
    
    func testDifferentCancellationReasons() async {
        let context = CommandContext()
        
        context.markAsCancelled(reason: .userCancellation)
        let reason1 = context.getCancellationReason()
        XCTAssertEqual(reason1, .userCancellation)
        
        // Change reason
        context.markAsCancelled(reason: .systemShutdown)
        let reason2 = context.getCancellationReason()
        XCTAssertEqual(reason2, .systemShutdown)
    }
    
    // MARK: - Fork Support Tests
    
    func testFork() async {
        let context = CommandContext()
        
        // Set up original context
        context.setRequestID("req123")
        context.setMetadata("key", value: "value")
        context.setMetric("metric", value: 100)
        
        // Fork
        let forked = context.fork()
        
        // Verify forked context has same data
        let forkedReqId1 = await forked.getRequestID()
        XCTAssertEqual(forkedReqId1, "req123")
        let forkedMeta1 = await forked.getMetadata("key") as? String
        XCTAssertEqual(forkedMeta1, "value")
        let forkedMetric = await forked.getMetric("metric") as? Int
        XCTAssertEqual(forkedMetric, 100)
        
        // Modify forked context
        await forked.setRequestID("req456")
        await forked.setMetadata("key", value: "newValue")
        
        // Verify original is unchanged
        let origReqId = context.getRequestID()
        XCTAssertEqual(origReqId, "req123")
        let origMeta = context.getMetadata("key") as? String
        XCTAssertEqual(origMeta, "value")
        
        // Verify forked has changes
        let forkedReqId2 = await forked.getRequestID()
        XCTAssertEqual(forkedReqId2, "req456")
        let forkedMeta2 = await forked.getMetadata("key") as? String
        XCTAssertEqual(forkedMeta2, "newValue")
    }
    
    // MARK: - Backward Compatibility Tests
    
    func testBackwardCompatibilityProperties() async {
        let context = CommandContext()
        
        context.setRequestID("req123")
        context.setUserID("user456")
        context.setCorrelationID("corr789")
        context.setStartTime(Date())
        context.setMetadata(["key": "value"])
        context.setMetrics(["metric": 100])
        
        // Test property-style access
        let requestId = context.requestID
        let userId = context.userID
        let correlationId = context.correlationID
        let startTime = context.startTime
        let metadata = context.metadata
        let metrics = context.metrics
        
        XCTAssertEqual(requestId, "req123")
        XCTAssertEqual(userId, "user456")
        XCTAssertEqual(correlationId, "corr789")
        XCTAssertNotNil(startTime)
        XCTAssertEqual(metadata["key"] as? String, "value")
        XCTAssertEqual(metrics["metric"] as? Int, 100)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentReads() async {
        let context = CommandContext()
        context.setRequestID("req123")
        
        // Perform many concurrent reads
        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    context.getRequestID()
                }
            }
            
            for await value in group {
                XCTAssertEqual(value, "req123")
            }
        }
    }
    
    func testConcurrentWrites() async {
        let context = CommandContext()
        let iterations = 100
        
        // Perform concurrent writes to different keys
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let key = ContextKey<Int>("key\(i)")
                    context.set(key, value: i)
                }
            }
        }
        
        // Verify all writes succeeded
        for i in 0..<iterations {
            let key = ContextKey<Int>("key\(i)")
            let value = context.get(key)
            XCTAssertEqual(value, i)
        }
    }
    
    func testConcurrentMixedOperations() async {
        let context = CommandContext()
        
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<50 {
                group.addTask {
                    context.setMetadata("key\(i)", value: i)
                }
            }
            
            // Readers
            for _ in 0..<50 {
                group.addTask {
                    _ = context.getMetadata()
                }
            }
            
            // Updates
            for i in 0..<50 {
                group.addTask {
                    context.setMetric("metric\(i)", value: i * 2)
                }
            }
        }
        
        // Verify state after concurrent operations
        let metadata = context.getMetadata()
        let metrics = context.getMetrics()
        
        XCTAssertGreaterThan(metadata.count, 0)
        XCTAssertGreaterThan(metrics.count, 0)
    }
    
    // MARK: - Edge Cases Tests
    
    func testEmptyKeyHandling() async {
        let context = CommandContext()
        let emptyKey = ContextKey<String>("")
        
        context.set(emptyKey, value: "value")
        let value = context.get(emptyKey)
        XCTAssertEqual(value, "value")
    }
    
    func testLargeValueHandling() async {
        let context = CommandContext()
        let largeArray = Array(repeating: "test", count: 10000)
        let key = ContextKey<[String]>("large")
        
        context.set(key, value: largeArray)
        let retrieved = context.get(key)
        
        XCTAssertEqual(retrieved?.count, 10000)
    }
    
    func testSpecialCharactersInKeys() async {
        let context = CommandContext()
        let specialKey = ContextKey<String>("key!@#$%^&*()[]{}|\\:;\"'<>,.?/")
        
        context.set(specialKey, value: "value")
        let value = context.get(specialKey)
        XCTAssertEqual(value, "value")
    }
    
    // MARK: - Debug Description Tests
    
    func testDebugDescription() async {
        let context = CommandContext()
        
        // Nonisolated debug description
        let description = context.debugDescription
        XCTAssertTrue(description.contains("CommandContext"))
        XCTAssertTrue(description.contains("id:"))
        
        // Async debug description
        context.setRequestID("req123")
        let asyncDescription = context.debugDescription
        XCTAssertTrue(asyncDescription.contains("CommandContext"))
    }
    
    // MARK: - Performance Tests
    
    func testGetSetPerformance() async {
        let context = CommandContext()
        let key = ContextKey<String>("test")
        
        let start = Date()
        for i in 0..<1000 {
            context.set(key, value: "value\(i)")
            _ = context.get(key)
        }
        let duration = Date().timeIntervalSince(start)
        
        print("Get/Set performance: 2000 operations in \(duration)s")
        XCTAssertLessThan(duration, 1.0) // Should complete in less than 1 second
    }
    
    func testMetadataPerformance() async {
        let context = CommandContext()
        
        let start = Date()
        for i in 0..<1000 {
            context.setMetadata("key\(i)", value: "value\(i)")
        }
        _ = context.getMetadata()
        let duration = Date().timeIntervalSince(start)
        
        print("Metadata performance: 1000 writes + 1 read in \(duration)s")
        XCTAssertLessThan(duration, 1.0)
    }
}

// MARK: - Test Helpers

private struct TestCommandMetadata: CommandMetadata {
    let id = UUID()
    let timestamp = Date()
    let userID: String?
    let correlationID: String?
    
    init(userID: String? = nil, correlationID: String? = nil) {
        self.userID = userID
        self.correlationID = correlationID
    }
}
