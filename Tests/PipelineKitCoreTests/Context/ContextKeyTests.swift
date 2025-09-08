import XCTest
@testable import PipelineKitCore

final class ContextKeyTests: XCTestCase {
    
    // MARK: - Basic Functionality Tests
    
    func testContextKeyCreation() {
        let key = ContextKey<String>("testKey")
        XCTAssertEqual(key.name, "testKey")
    }
    
    func testContextKeyWithDifferentTypes() {
        let stringKey = ContextKey<String>("string")
        let intKey = ContextKey<Int>("int")
        let boolKey = ContextKey<Bool>("bool")
        let arrayKey = ContextKey<[String]>("array")
        let dictKey = ContextKey<[String: Int]>("dict")
        
        XCTAssertEqual(stringKey.name, "string")
        XCTAssertEqual(intKey.name, "int")
        XCTAssertEqual(boolKey.name, "bool")
        XCTAssertEqual(arrayKey.name, "array")
        XCTAssertEqual(dictKey.name, "dict")
    }
    
    // MARK: - Hashable Tests
    
    func testHashable() {
        let key1 = ContextKey<String>("test")
        let key2 = ContextKey<String>("test")
        let key3 = ContextKey<String>("other")
        
        // Same keys should have same hash
        XCTAssertEqual(key1.hashValue, key2.hashValue)
        
        // Different keys likely have different hashes
        XCTAssertNotEqual(key1.hashValue, key3.hashValue)
    }
    
    func testEquatable() {
        let key1 = ContextKey<String>("test")
        let key2 = ContextKey<String>("test")
        let key3 = ContextKey<String>("other")
        
        XCTAssertEqual(key1, key2)
        XCTAssertNotEqual(key1, key3)
    }
    
    func testSetOperations() {
        var set = Set<ContextKey<String>>()
        
        let key1 = ContextKey<String>("test")
        let key2 = ContextKey<String>("test") // Same name
        let key3 = ContextKey<String>("other")
        
        set.insert(key1)
        set.insert(key2) // Should not add duplicate
        set.insert(key3)
        
        XCTAssertEqual(set.count, 2)
        XCTAssertTrue(set.contains(key1))
        XCTAssertTrue(set.contains(key3))
    }
    
    // MARK: - Standard Keys Tests
    
    func testStandardRequestMetadataKeys() {
        XCTAssertEqual(ContextKeys.requestID.name, "requestID")
        XCTAssertEqual(ContextKeys.userID.name, "userID")
        XCTAssertEqual(ContextKeys.correlationID.name, "correlationID")
        XCTAssertEqual(ContextKeys.startTime.name, "startTime")
        XCTAssertEqual(ContextKeys.metrics.name, "metrics")
        XCTAssertEqual(ContextKeys.metadata.name, "metadata")
        XCTAssertEqual(ContextKeys.traceID.name, "traceID")
        XCTAssertEqual(ContextKeys.spanID.name, "spanID")
        XCTAssertEqual(ContextKeys.commandType.name, "commandType")
        XCTAssertEqual(ContextKeys.commandID.name, "commandID")
    }
    
    func testStandardSecurityKeys() {
        XCTAssertEqual(ContextKeys.authToken.name, "authToken")
        XCTAssertEqual(ContextKeys.authenticatedUser.name, "authenticatedUser")
        XCTAssertEqual(ContextKeys.roles.name, "roles")
        XCTAssertEqual(ContextKeys.permissions.name, "permissions")
    }
    
    func testStandardObservabilityKeys() {
        XCTAssertEqual(ContextKeys.eventEmitter.name, "eventEmitter")
        XCTAssertEqual(ContextKeys.logLevel.name, "logLevel")
        XCTAssertEqual(ContextKeys.logContext.name, "logContext")
        XCTAssertEqual(ContextKeys.performanceMeasurements.name, "performanceMeasurements")
    }
    
    func testStandardResilienceKeys() {
        XCTAssertEqual(ContextKeys.retryCount.name, "retryCount")
        XCTAssertEqual(ContextKeys.circuitBreakerState.name, "circuitBreakerState")
        XCTAssertEqual(ContextKeys.rateLimitRemaining.name, "rateLimitRemaining")
        XCTAssertEqual(ContextKeys.cancellationReason.name, "cancellationReason")
    }
    
    // MARK: - Custom Factory Method Tests
    
    func testCustomFactoryMethod() {
        let key1 = ContextKey<Double>.custom("temperature", Double.self)
        XCTAssertEqual(key1.name, "temperature")
        
        let key2 = ContextKey<Int>.custom("count", Int.self)
        XCTAssertEqual(key2.name, "count")
        
        let key3 = ContextKey<[String]>.custom("tags", [String].self)
        XCTAssertEqual(key3.name, "tags")
    }
    
    func testCustomFactoryWithComplexTypes() {
        struct CustomData: Sendable {
            let id: String
            let value: Int
        }
        
        let key = ContextKey<CustomData>.custom("customData", CustomData.self)
        XCTAssertEqual(key.name, "customData")
    }
    
    // MARK: - Type Safety Tests
    
    func testTypeSafetyWithDifferentValueTypes() {
        // Keys with same name but different types are different types
        let stringKey = ContextKey<String>("value")
        let intKey = ContextKey<Int>("value")
        
        // They have the same name
        XCTAssertEqual(stringKey.name, intKey.name)
        
        // But they are different types at compile time
        // This ensures type safety when used with CommandContext
    }
    
    // MARK: - Sendable Conformance Tests
    
    func testSendableConformance() async {
        // Test that ContextKey can be safely passed between actors
        actor TestActor {
            func useKey<T: Sendable>(_ key: ContextKey<T>) -> String {
                return key.name
            }
        }
        
        let actor = TestActor()
        let key = ContextKey<String>("test")
        
        let name = await actor.useKey(key)
        XCTAssertEqual(name, "test")
    }
    
    // MARK: - Edge Case Tests
    
    func testEmptyKeyName() {
        let key = ContextKey<String>("")
        XCTAssertEqual(key.name, "")
    }
    
    func testLongKeyName() {
        let longName = String(repeating: "a", count: 10000)
        let key = ContextKey<String>(longName)
        XCTAssertEqual(key.name.count, 10000)
    }
    
    func testSpecialCharactersInKeyName() {
        let specialName = "key!@#$%^&*()[]{}|\\:;\"'<>,.?/~`"
        let key = ContextKey<String>(specialName)
        XCTAssertEqual(key.name, specialName)
    }
    
    func testUnicodeInKeyName() {
        let unicodeName = "🔑📝🚀キー"
        let key = ContextKey<String>(unicodeName)
        XCTAssertEqual(key.name, unicodeName)
    }
    
    // MARK: - Use Case Tests
    
    func testKeyUniqueness() {
        // Different instances with same name are equal
        let key1 = ContextKey<String>("userID")
        let key2 = ContextKey<String>("userID")
        
        XCTAssertEqual(key1, key2)
        
        // Can be used as dictionary keys
        var dict: [ContextKey<String>: String] = [:]
        dict[key1] = "value1"
        dict[key2] = "value2" // Will overwrite
        
        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict[key1], "value2")
    }
    
    func testKeyCollections() {
        let keys: [ContextKey<String>] = [
            ContextKeys.requestID,
            ContextKeys.userID,
            ContextKeys.traceID,
            ContextKey<String>("custom")
        ]
        
        XCTAssertEqual(keys.count, 4)
        XCTAssertTrue(keys.contains(ContextKeys.requestID))
        XCTAssertTrue(keys.contains(ContextKeys.userID))
    }
    
    // MARK: - Performance Tests
    
    func testKeyCreationPerformance() {
        measure {
            for i in 0..<10000 {
                _ = ContextKey<String>("key\(i)")
            }
        }
    }
    
    func testKeyComparisonPerformance() {
        let key1 = ContextKey<String>("test")
        let key2 = ContextKey<String>("test")
        
        measure {
            for _ in 0..<100000 {
                _ = key1 == key2
            }
        }
    }
}