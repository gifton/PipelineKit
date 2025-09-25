import XCTest
@testable import PipelineKitCore

final class CommandContextTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testInitWithDefaultMetadata() async {
        let context = CommandContext()
        
        // Verify basic properties are initialized
        // CommandContext is an actor, so we can't access commandMetadata directly
        // Instead, verify through the methods that use it
        _ = await context.getUserID()
        let startTime = await context.getStartTime()
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
        let userId = await context.getUserID()
        let correlationId = await context.getCorrelationID()
        let requestId = await context.getRequestID()
        
        XCTAssertEqual(userId, "user123")
        XCTAssertEqual(correlationId, "corr456")
        XCTAssertEqual(requestId, "corr456") // Should be set from correlationID
    }
    
    // MARK: - Typed Key Access Tests
    
    func testTypedKeyGetSet() async {
        let context = CommandContext()
        let testKey = ContextKey<String>("testKey")
        
        // Test setting and getting
        await context.set(testKey, value: "testValue")
        let value = await context.get(testKey)
        XCTAssertEqual(value, "testValue")
        
        // Test removing
        await context.set(testKey, value: nil)
        let removedValue = await context.get(testKey)
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
        
        await context.set(stringKey, value: "test")
        await context.set(intKey, value: 42)
        await context.set(doubleKey, value: 3.14)
        await context.set(boolKey, value: true)
        await context.set(dateKey, value: testDate)
        
        let stringValue = await context.get(stringKey)
        let intValue = await context.get(intKey)
        let doubleValue = await context.get(doubleKey)
        let boolValue = await context.get(boolKey)
        let dateValue = await context.get(dateKey)
        
        XCTAssertEqual(stringValue, "test")
        XCTAssertEqual(intValue, 42)
        XCTAssertEqual(doubleValue, 3.14)
        XCTAssertEqual(boolValue, true)
        XCTAssertEqual(dateValue, testDate)
    }
    
    func testTypedKeyTypeySafety() async {
        let context = CommandContext()
        let stringKey = ContextKey<String>("test")
        
        await context.set(stringKey, value: "stringValue")
        
        // Try to get with wrong type - should return nil due to type mismatch
        let intKey = ContextKey<Int>("test") // Same name, different type
        let wrongTypeValue = await context.get(intKey)
        XCTAssertNil(wrongTypeValue)
    }
    
    // MARK: - Direct Property Access Tests
    
    func testRequestIDGetSet() async {
        let context = CommandContext()
        
        await context.setRequestID("req123")
        let requestId = await context.getRequestID()
        XCTAssertEqual(requestId, "req123")
        
        await context.setRequestID(nil)
        let clearedId = await context.getRequestID()
        XCTAssertNil(clearedId)
    }
    
    func testUserIDGetSet() async {
        let context = CommandContext()
        
        await context.setUserID("user456")
        let userId = await context.getUserID()
        XCTAssertEqual(userId, "user456")
        
        await context.setUserID(nil)
        let clearedId = await context.getUserID()
        XCTAssertNil(clearedId)
    }
    
    func testCorrelationIDGetSet() async {
        let context = CommandContext()
        
        await context.setCorrelationID("corr789")
        let correlationId = await context.getCorrelationID()
        XCTAssertEqual(correlationId, "corr789")
        
        await context.setCorrelationID(nil)
        let clearedId = await context.getCorrelationID()
        XCTAssertNil(clearedId)
    }
    
    func testStartTimeGetSet() async {
        let context = CommandContext()
        let testTime = Date()
        
        await context.setStartTime(testTime)
        let startTime = await context.getStartTime()
        XCTAssertEqual(startTime, testTime)
        
        await context.setStartTime(nil)
        let clearedTime = await context.getStartTime()
        XCTAssertNil(clearedTime)
    }
    
    // MARK: - Metadata Operations Tests
    
    func testMetadataOperations() async {
        let context = CommandContext()
        
        // Test setting individual metadata
        await context.setMetadata("key1", value: "value1")
        await context.setMetadata("key2", value: 42)
        
        let value1 = await context.getMetadata("key1") as? String
        let value2 = await context.getMetadata("key2") as? Int
        
        XCTAssertEqual(value1, "value1")
        XCTAssertEqual(value2, 42)
        
        // Test getting all metadata
        let allMetadata = await context.getMetadata()
        XCTAssertEqual(allMetadata["key1"] as? String, "value1")
        XCTAssertEqual(allMetadata["key2"] as? Int, 42)
    }
    
    func testMetadataUpdate() async {
        let context = CommandContext()
        
        await context.setMetadata("existing", value: "old")
        await context.updateMetadata([
            "existing": "new",
            "added": "value"
        ])
        
        let metadata = await context.getMetadata()
        XCTAssertEqual(metadata["existing"] as? String, "new")
        XCTAssertEqual(metadata["added"] as? String, "value")
    }
    
    func testMetadataReplace() async {
        let context = CommandContext()
        
        await context.setMetadata("key1", value: "value1")
        await context.setMetadata("key2", value: "value2")
        
        let newMetadata: [String: any Sendable] = ["key3": "value3"]
        await context.setMetadata(newMetadata)
        
        let metadata = await context.getMetadata()
        XCTAssertNil(metadata["key1"])
        XCTAssertNil(metadata["key2"])
        XCTAssertEqual(metadata["key3"] as? String, "value3")
    }
    
    // MARK: - Metrics Operations Tests
    
    func testMetricsOperations() async {
        let context = CommandContext()
        
        // Test setting individual metrics
        await context.setMetric("latency", value: 0.125)
        await context.setMetric("count", value: 100)
        
        let latency = await context.getMetric("latency") as? Double
        let count = await context.getMetric("count") as? Int
        
        XCTAssertEqual(latency, 0.125)
        XCTAssertEqual(count, 100)
        
        // Test storeMetric (alias)
        await context.storeMetric("throughput", value: 1000.0)
        let throughput = await context.getMetric("throughput") as? Double
        XCTAssertEqual(throughput, 1000.0)
    }
    
    func testMetricsUpdate() async {
        let context = CommandContext()
        
        await context.setMetric("metric1", value: 1)
        await context.updateMetrics([
            "metric1": 2,
            "metric2": 3
        ])
        
        let metrics = await context.getMetrics()
        XCTAssertEqual(metrics["metric1"] as? Int, 2)
        XCTAssertEqual(metrics["metric2"] as? Int, 3)
    }
    
    func testRecordDuration() async throws {
        let context = CommandContext()
        let startTime = Date()
        await context.setStartTime(startTime)
        
        // Wait a small amount
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        await context.recordDuration()
        
        let duration = await context.getMetric("duration") as? TimeInterval
        XCTAssertNotNil(duration)
        XCTAssertGreaterThan(duration!, 0)
        XCTAssertLessThan(duration!, 1.0) // Should be less than 1 second
    }
    
    func testRecordDurationWithCustomName() async throws {
        let context = CommandContext()
        let startTime = Date()
        await context.setStartTime(startTime)
        
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        await context.recordDuration("customDuration")
        
        let duration = await context.getMetric("customDuration") as? TimeInterval
        XCTAssertNotNil(duration)
        XCTAssertGreaterThan(duration!, 0)
    }
    
    func testRecordDurationWithoutStartTime() async {
        let context = CommandContext()
        // Don't set start time
        
        await context.recordDuration()
        
        // Should not crash, just not record anything
        let duration = await context.getMetric("duration")
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
        await context.setMetadata("key", value: "value")
        await context.setMetric("metric", value: 123)
        let testKey = ContextKey<String>("test")
        await context.set(testKey, value: "testValue")
        
        // Clear
        await context.clear()
        
        // Verify custom data is cleared
        let clearedMeta = await context.getMetadata("key")
        XCTAssertNil(clearedMeta)
        let clearedMetric = await context.getMetric("metric")
        XCTAssertNil(clearedMetric)
        let clearedValue = await context.get(testKey)
        XCTAssertNil(clearedValue)
        
        // Verify command metadata is preserved
        let userId = await context.getUserID()
        XCTAssertEqual(userId, "user123")
        let correlationId = await context.getCorrelationID()
        XCTAssertEqual(correlationId, "corr456")
    }
    
    func testSnapshot() async {
        let context = CommandContext()
        
        await context.setRequestID("req123")
        await context.setMetadata("meta", value: "data")
        await context.setMetric("metric", value: 456)
        
        let snapshot = await context.snapshot()
        
        // Verify snapshot contains data
        XCTAssertNotNil(snapshot["commandMetadata"])
        XCTAssertNotNil(snapshot[ContextKeys.requestID.name])
        XCTAssertNotNil(snapshot[ContextKeys.metadata.name])
        XCTAssertNotNil(snapshot[ContextKeys.metrics.name])
    }
    
    func testSnapshotRaw() async {
        let context = CommandContext()
        
        await context.setRequestID("req123")
        await context.setMetadata("meta", value: "data")
        
        let snapshot = await context.snapshotRaw()
        
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
        
        let contains1 = await context.contains(key)
        XCTAssertFalse(contains1)
        
        await context.set(key, value: "value")
        let contains2 = await context.contains(key)
        XCTAssertTrue(contains2)
        
        await context.remove(key)
        let contains3 = await context.contains(key)
        XCTAssertFalse(contains3)
    }
    
    func testRemove() async {
        let context = CommandContext()
        let key = ContextKey<String>("test")
        
        await context.set(key, value: "value")
        let beforeRemove = await context.get(key)
        XCTAssertNotNil(beforeRemove)
        
        await context.remove(key)
        let afterRemove = await context.get(key)
        XCTAssertNil(afterRemove)
    }
    
    func testUpdate() async {
        let context = CommandContext()
        
        await context.update { ctx in
            await ctx.setRequestID("req123")
            await ctx.setUserID("user456")
            await ctx.setMetadata("key", value: "value")
        }
        
        let requestId = await context.getRequestID()
        XCTAssertEqual(requestId, "req123")
        let userId = await context.getUserID()
        XCTAssertEqual(userId, "user456")
        let metaValue = await context.getMetadata("key") as? String
        XCTAssertEqual(metaValue, "value")
    }
    
    // MARK: - Cancellation Support Tests
    
    func testCancellationSupport() async {
        let context = CommandContext()
        
        let isCancelled1 = await context.isCancelled
        XCTAssertFalse(isCancelled1)
        let reason0 = await context.getCancellationReason()
        XCTAssertNil(reason0)
        
        await context.markAsCancelled(reason: .timeout(duration: 5.0, gracePeriod: nil))
        
        let isCancelled2 = await context.isCancelled
        XCTAssertTrue(isCancelled2)
        let reason = await context.getCancellationReason()
        XCTAssertEqual(reason, .timeout(duration: 5.0, gracePeriod: nil))
    }
    
    func testDifferentCancellationReasons() async {
        let context = CommandContext()
        
        await context.markAsCancelled(reason: .userCancellation)
        let reason1 = await context.getCancellationReason()
        XCTAssertEqual(reason1, .userCancellation)
        
        // Change reason
        await context.markAsCancelled(reason: .systemShutdown)
        let reason2 = await context.getCancellationReason()
        XCTAssertEqual(reason2, .systemShutdown)
    }
    
    // MARK: - Fork Support Tests
    
    func testFork() async {
        let context = CommandContext()
        
        // Set up original context
        await context.setRequestID("req123")
        await context.setMetadata("key", value: "value")
        await context.setMetric("metric", value: 100)
        
        // Fork
        let forked = await context.fork()
        
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
        let origReqId = await context.getRequestID()
        XCTAssertEqual(origReqId, "req123")
        let origMeta = await context.getMetadata("key") as? String
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
        
        await context.setRequestID("req123")
        await context.setUserID("user456")
        await context.setCorrelationID("corr789")
        await context.setStartTime(Date())
        await context.setMetadata(["key": "value"])
        await context.setMetrics(["metric": 100])
        
        // Test property-style access
        let requestId = await context.requestID
        let userId = await context.userID
        let correlationId = await context.correlationID
        let startTime = await context.startTime
        let metadata = await context.metadata
        let metrics = await context.metrics
        
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
        await context.setRequestID("req123")
        
        // Perform many concurrent reads
        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await context.getRequestID()
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
                    await context.set(key, value: i)
                }
            }
        }
        
        // Verify all writes succeeded
        for i in 0..<iterations {
            let key = ContextKey<Int>("key\(i)")
            let value = await context.get(key)
            XCTAssertEqual(value, i)
        }
    }
    
    func testConcurrentMixedOperations() async {
        let context = CommandContext()
        
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<50 {
                group.addTask {
                    await context.setMetadata("key\(i)", value: i)
                }
            }
            
            // Readers
            for _ in 0..<50 {
                group.addTask {
                    _ = await context.getMetadata()
                }
            }
            
            // Updates
            for i in 0..<50 {
                group.addTask {
                    await context.setMetric("metric\(i)", value: i * 2)
                }
            }
        }
        
        // Verify state after concurrent operations
        let metadata = await context.getMetadata()
        let metrics = await context.getMetrics()
        
        XCTAssertGreaterThan(metadata.count, 0)
        XCTAssertGreaterThan(metrics.count, 0)
    }
    
    // MARK: - Edge Cases Tests
    
    func testEmptyKeyHandling() async {
        let context = CommandContext()
        let emptyKey = ContextKey<String>("")
        
        await context.set(emptyKey, value: "value")
        let value = await context.get(emptyKey)
        XCTAssertEqual(value, "value")
    }
    
    func testLargeValueHandling() async {
        let context = CommandContext()
        let largeArray = Array(repeating: "test", count: 10000)
        let key = ContextKey<[String]>("large")
        
        await context.set(key, value: largeArray)
        let retrieved = await context.get(key)
        
        XCTAssertEqual(retrieved?.count, 10000)
    }
    
    func testSpecialCharactersInKeys() async {
        let context = CommandContext()
        let specialKey = ContextKey<String>("key!@#$%^&*()[]{}|\\:;\"'<>,.?/")
        
        await context.set(specialKey, value: "value")
        let value = await context.get(specialKey)
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
        await context.setRequestID("req123")
        let asyncDescription = await context.debugDescriptionAsync()
        XCTAssertTrue(asyncDescription.contains("CommandContext"))
    }
    
    // MARK: - Performance Tests
    
    func testGetSetPerformance() async {
        let context = CommandContext()
        let key = ContextKey<String>("test")
        
        let start = Date()
        for i in 0..<1000 {
            await context.set(key, value: "value\(i)")
            _ = await context.get(key)
        }
        let duration = Date().timeIntervalSince(start)
        
        print("Get/Set performance: 2000 operations in \(duration)s")
        XCTAssertLessThan(duration, 1.0) // Should complete in less than 1 second
    }
    
    func testMetadataPerformance() async {
        let context = CommandContext()
        
        let start = Date()
        for i in 0..<1000 {
            await context.setMetadata("key\(i)", value: "value\(i)")
        }
        _ = await context.getMetadata()
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
