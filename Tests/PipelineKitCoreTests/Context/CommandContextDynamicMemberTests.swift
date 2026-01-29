import XCTest
@testable import PipelineKitCore

/// Tests for @dynamicMemberLookup functionality in CommandContext
final class CommandContextDynamicMemberTests: XCTestCase {
    // MARK: - Direct Property Access Tests

    func testDirectPropertyAccessWrite() {
        let context = CommandContext()

        // Set via property
        context.requestID = "req-123"
        context.userID = "user-456"
        context.correlationID = "corr-789"
        context.startTime = Date()

        // Verify values were set
        XCTAssertEqual(context.requestID, "req-123")
        XCTAssertEqual(context.userID, "user-456")
        XCTAssertEqual(context.correlationID, "corr-789")
        XCTAssertNotNil(context.startTime)
    }

    func testDirectPropertyAccessRead() {
        let context = CommandContext()

        // Set via subscript
        context[ContextKeys.requestID] = "req-123"
        context[ContextKeys.userID] = "user-456"

        // Read via property
        XCTAssertEqual(context.requestID, "req-123")
        XCTAssertEqual(context.userID, "user-456")
    }

    func testDirectPropertyAccessNil() {
        let context = CommandContext()

        // Unset values return nil
        XCTAssertNil(context.requestID)
        XCTAssertNil(context.userID)
        XCTAssertNil(context.correlationID)
        XCTAssertNil(context.startTime)

        // Set and then unset
        context.requestID = "req-123"
        XCTAssertNotNil(context.requestID)

        context.requestID = nil
        XCTAssertNil(context.requestID)
    }

    // MARK: - KeyPath Subscript Tests

    func testKeyPathSubscriptWrite() {
        let context = CommandContext()

        // Set via KeyPath
        context[keyPath: \.requestID] = "req-123"
        context[keyPath: \.userID] = "user-456"
        context[keyPath: \.correlationID] = "corr-789"

        // Verify values were set
        XCTAssertEqual(context[keyPath: \.requestID], "req-123")
        XCTAssertEqual(context[keyPath: \.userID], "user-456")
        XCTAssertEqual(context[keyPath: \.correlationID], "corr-789")
    }

    func testKeyPathSubscriptRead() {
        let context = CommandContext()

        // Set via traditional subscript
        context[ContextKeys.requestID] = "req-123"
        context[ContextKeys.userID] = "user-456"

        // Read via KeyPath
        XCTAssertEqual(context[keyPath: \.requestID], "req-123")
        XCTAssertEqual(context[keyPath: \.userID], "user-456")
    }

    func testKeyPathSubscriptNil() {
        let context = CommandContext()

        // Unset values return nil
        XCTAssertNil(context[keyPath: \.requestID])
        XCTAssertNil(context[keyPath: \.userID])

        // Set and unset
        context[keyPath: \.requestID] = "req-123"
        XCTAssertNotNil(context[keyPath: \.requestID])

        context[keyPath: \.requestID] = nil
        XCTAssertNil(context[keyPath: \.requestID])
    }

    // MARK: - Mixed Access Patterns Tests

    func testMixedAccessPatterns() {
        let context = CommandContext()

        // Set via property
        context.requestID = "req-123"

        // Read via KeyPath
        XCTAssertEqual(context[keyPath: \.requestID], "req-123")

        // Read via subscript
        XCTAssertEqual(context[ContextKeys.requestID], "req-123")

        // Read via subscript
        XCTAssertEqual(context[ContextKeys.requestID], "req-123")

        // Read via property
        XCTAssertEqual(context.requestID, "req-123")
    }

    func testMixedWriteAndRead() {
        let context = CommandContext()

        // Write via KeyPath, read via property
        context[keyPath: \.requestID] = "req-123"
        XCTAssertEqual(context.requestID, "req-123")

        // Write via property, read via subscript
        context.userID = "user-456"
        XCTAssertEqual(context[ContextKeys.userID], "user-456")

        // Write via subscript, read via KeyPath
        context[ContextKeys.correlationID] = "corr-789"
        XCTAssertEqual(context[keyPath: \.correlationID], "corr-789")
    }

    // MARK: - Backwards Compatibility Tests

    func testBackwardsCompatibilityReadOnlyProperties() {
        let context = CommandContext()

        context.requestID = "req-123"
        context.userID = "user-456"
        context.correlationID = "corr-789"
        context.startTime = Date()
        context.metadata = ["key": "value"]
        context.metrics = ["metric": 100]

        // Test read-only property access (backwards compatible)
        let requestId = context.requestID
        let userId = context.userID
        let correlationId = context.correlationID
        let startTime = context.startTime
        let metadata = context.metadata
        let metrics = context.metrics

        XCTAssertEqual(requestId, "req-123")
        XCTAssertEqual(userId, "user-456")
        XCTAssertEqual(correlationId, "corr-789")
        XCTAssertNotNil(startTime)
        XCTAssertEqual(metadata["key"] as? String, "value")
        XCTAssertEqual(metrics["metric"] as? Int, 100)
    }

    func testBackwardsCompatibilityOldSyntaxStillWorks() {
        let context = CommandContext()

        // Old syntax still works
        context[ContextKeys.requestID] = "req-123"
        XCTAssertEqual(context[ContextKeys.requestID], "req-123")

        // Can access via new syntax
        XCTAssertEqual(context.requestID, "req-123")
        XCTAssertEqual(context[keyPath: \.requestID], "req-123")
    }

    func testBackwardsCompatibilityMethodsStillWork() {
        let context = CommandContext()

        // Subscript-based access
        context[ContextKeys.requestID] = "req-123"
        XCTAssertEqual(context[ContextKeys.requestID], "req-123")

        // Accessible via new syntax
        XCTAssertEqual(context.requestID, "req-123")
        XCTAssertEqual(context[keyPath: \.requestID], "req-123")
    }

    // MARK: - Different Value Types Tests

    func testStringValues() {
        let context = CommandContext()

        // String values
        context.requestID = "req-123"
        context.userID = "user-456"
        context.correlationID = "corr-789"

        XCTAssertEqual(context.requestID, "req-123")
        XCTAssertEqual(context.userID, "user-456")
        XCTAssertEqual(context.correlationID, "corr-789")
    }

    func testDateValues() {
        let context = CommandContext()

        // Date value
        let now = Date()
        context.startTime = now

        XCTAssertEqual(context.startTime, now)
    }

    func testIntValues() {
        let context = CommandContext()

        // Int value
        context.retryCount = 3

        XCTAssertEqual(context.retryCount, 3)
    }

    func testArrayValues() {
        let context = CommandContext()

        // Array value
        context.roles = ["admin", "user"]

        XCTAssertEqual(context.roles, ["admin", "user"])
    }

    func testDictionaryValues() {
        let context = CommandContext()

        // Dictionary values
        let metadata: [String: any Sendable] = ["key1": "value1", "key2": 123]
        context.metadata = metadata

        XCTAssertEqual(context.metadata["key1"] as? String, "value1")
        XCTAssertEqual(context.metadata["key2"] as? Int, 123)
    }

    func testUUIDValues() {
        let context = CommandContext()

        // UUID value (commandID)
        let uuid = UUID()
        context.commandID = uuid

        XCTAssertEqual(context.commandID, uuid)
    }

    // MARK: - Custom Keys Tests

    func testCustomKeysStillWorkWithSubscript() {
        let context = CommandContext()
        let customKey = ContextKey<String>("customKey")

        // Custom keys work with subscript
        context[customKey] = "customValue"
        XCTAssertEqual(context[customKey], "customValue")
    }

    func testCustomKeysWithSubscript() {
        let context = CommandContext()
        let customKey = ContextKey<String>("customKey")

        // Custom keys work with subscript
        context[customKey] = "customValue"
        XCTAssertEqual(context[customKey], "customValue")
    }

    func testCustomKeysDontWorkWithDynamicMemberLookup() {
        // This test documents that custom keys defined at call-site
        // don't work with property/KeyPath syntax (expected limitation)
        let context = CommandContext()
        let customKey = ContextKey<String>("myCustomKey")

        // Set via subscript (the only way for custom keys)
        context[customKey] = "value"

        // Cannot use: context.myCustomKey = "value"
        // Cannot use: context[\.myCustomKey] = "value"
        // This is documented behavior

        XCTAssertEqual(context[customKey], "value")
    }

    // MARK: - Type Safety Tests

    func testTypeSafetyEnforced() {
        let context = CommandContext()

        // Type is enforced by ContextKey
        context.requestID = "req-123" // String
        context.retryCount = 5        // Int
        context.startTime = Date()    // Date

        // Compiler ensures type safety
        let id: String? = context.requestID
        let count: Int? = context.retryCount
        let time: Date? = context.startTime

        XCTAssertEqual(id, "req-123")
        XCTAssertEqual(count, 5)
        XCTAssertNotNil(time)
    }

    // MARK: - Nil Handling Tests

    func testNilValueHandling() {
        let context = CommandContext()

        // Set value
        context.requestID = "req-123"
        XCTAssertNotNil(context.requestID)

        // Set to nil removes the value
        context.requestID = nil
        XCTAssertNil(context.requestID)
    }

    func testNilValueHandlingViaKeyPath() {
        let context = CommandContext()

        // Set via KeyPath
        context[keyPath: \.requestID] = "req-123"
        XCTAssertNotNil(context[keyPath: \.requestID])

        // Set to nil via KeyPath
        context[keyPath: \.requestID] = nil
        XCTAssertNil(context[keyPath: \.requestID])
    }

    // MARK: - Thread Safety Tests

    func testConcurrentPropertyAccess() async {
        let context = CommandContext()
        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            // Concurrent writes via property
            for i in 0..<iterations {
                group.addTask {
                    context.requestID = "req-\(i)"
                }
            }

            // Concurrent reads via property
            for _ in 0..<iterations {
                group.addTask {
                    _ = context.requestID
                }
            }
        }

        // Should not crash and should have a valid value
        XCTAssertNotNil(context.requestID)
    }

    func testConcurrentMixedAccess() async {
        let context = CommandContext()
        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            // Write via property
            for i in 0..<iterations {
                group.addTask {
                    context.requestID = "req-\(i)"
                }
            }

            // Read via KeyPath
            for _ in 0..<iterations {
                group.addTask {
                    _ = context[keyPath: \.requestID]
                }
            }

            // Read via subscript
            for _ in 0..<iterations {
                group.addTask {
                    _ = context[ContextKeys.requestID]
                }
            }
        }

        // Should not crash
        XCTAssertNotNil(context.requestID)
    }

    // MARK: - Integration Tests

    func testRealWorldUsagePattern() {
        let context = CommandContext()

        // Typical middleware pattern
        context.requestID = UUID().uuidString
        context.userID = "user-123"
        context.startTime = Date()

        // Later middleware reads values
        guard let requestID = context.requestID else {
            XCTFail("requestID should be set")
            return
        }

        guard let userID = context.userID else {
            XCTFail("userID should be set")
            return
        }

        guard let startTime = context.startTime else {
            XCTFail("startTime should be set")
            return
        }

        // Calculate duration
        let duration = Date().timeIntervalSince(startTime)

        XCTAssertFalse(requestID.isEmpty)
        XCTAssertEqual(userID, "user-123")
        XCTAssertGreaterThanOrEqual(duration, 0)
    }

    func testMetadataAndMetricsAccess() {
        let context = CommandContext()

        // Metadata access (dictionary)
        context.metadata = ["key1": "value1", "key2": 123]

        // Read via property (returns non-nil empty dict)
        XCTAssertEqual(context.metadata["key1"] as? String, "value1")
        XCTAssertEqual(context.metadata["key2"] as? Int, 123)

        // Metrics access (dictionary)
        context.metrics = ["latency": 0.5, "throughput": 1000]

        XCTAssertEqual(context.metrics["latency"] as? Double, 0.5)
        XCTAssertEqual(context.metrics["throughput"] as? Int, 1000)
    }

    func testAllBuiltInKeysAccessible() {
        let context = CommandContext()

        // All built-in keys should be accessible via property syntax
        context.requestID = "req-123"
        context.userID = "user-456"
        context.correlationID = "corr-789"
        context.startTime = Date()
        context.traceID = "trace-123"
        context.spanID = "span-456"
        context.commandType = "TestCommand"
        context.commandID = UUID()
        context.authToken = "token-123"
        context.roles = ["admin", "user"]
        context.permissions = ["read", "write"]
        context.logLevel = "debug"
        context.retryCount = 3
        context.circuitBreakerState = "closed"
        context.rateLimitRemaining = 100

        // Verify all are set
        XCTAssertEqual(context.requestID, "req-123")
        XCTAssertEqual(context.userID, "user-456")
        XCTAssertEqual(context.correlationID, "corr-789")
        XCTAssertNotNil(context.startTime)
        XCTAssertEqual(context.traceID, "trace-123")
        XCTAssertEqual(context.spanID, "span-456")
        XCTAssertEqual(context.commandType, "TestCommand")
        XCTAssertNotNil(context.commandID)
        XCTAssertEqual(context.authToken, "token-123")
        XCTAssertEqual(context.roles, ["admin", "user"])
        XCTAssertEqual(context.permissions, ["read", "write"])
        XCTAssertEqual(context.logLevel, "debug")
        XCTAssertEqual(context.retryCount, 3)
        XCTAssertEqual(context.circuitBreakerState, "closed")
        XCTAssertEqual(context.rateLimitRemaining, 100)
    }

    func testKeysWithoutComputedPropertiesUseDynamicMemberLookup() {
        let context = CommandContext()

        // These keys don't have explicit computed properties
        // They ONLY work via @dynamicMemberLookup
        context.traceID = "trace-123"
        context.spanID = "span-456"
        context.commandType = "TestCommand"
        context.authToken = "token-789"
        context.logLevel = "debug"
        context.retryCount = 5
        context.circuitBreakerState = "open"
        context.rateLimitRemaining = 42

        // Verify values are set correctly
        XCTAssertEqual(context.traceID, "trace-123")
        XCTAssertEqual(context.spanID, "span-456")
        XCTAssertEqual(context.commandType, "TestCommand")
        XCTAssertEqual(context.authToken, "token-789")
        XCTAssertEqual(context.logLevel, "debug")
        XCTAssertEqual(context.retryCount, 5)
        XCTAssertEqual(context.circuitBreakerState, "open")
        XCTAssertEqual(context.rateLimitRemaining, 42)

        // Verify they also work via KeyPath subscript
        context[keyPath: \.traceID] = "trace-updated"
        XCTAssertEqual(context.traceID, "trace-updated")

        context[keyPath: \.authToken] = "token-updated"
        XCTAssertEqual(context.authToken, "token-updated")

        // Verify they work via traditional subscript too
        context[ContextKeys.logLevel] = "info"
        XCTAssertEqual(context.logLevel, "info")

        // Verify nil handling
        context.traceID = nil
        XCTAssertNil(context.traceID)

        context[keyPath: \.spanID] = nil
        XCTAssertNil(context.spanID)
    }
}
