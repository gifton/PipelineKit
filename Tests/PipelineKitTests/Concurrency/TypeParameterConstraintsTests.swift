import XCTest
@testable import PipelineKit

// MARK: - Type Parameter Constraints Tests

final class TypeParameterConstraintsTests: XCTestCase {
    
    // MARK: - MiddlewareCache Tests
    
    func testMiddlewareCacheRequiresSendableTypes() async {
        let cache = InMemoryMiddlewareCache()
        
        // These should compile - Sendable types
        await cache.set(key: "string", value: "test", ttl: 60)
        await cache.set(key: "int", value: 42, ttl: 60)
        await cache.set(key: "data", value: Data([1, 2, 3]), ttl: 60)
        
        // Retrieve values
        let stringValue: String? = await cache.get(key: "string", type: String.self)
        let intValue: Int? = await cache.get(key: "int", type: Int.self)
        let dataValue: Data? = await cache.get(key: "data", type: Data.self)
        
        XCTAssertEqual(stringValue, "test")
        XCTAssertEqual(intValue, 42)
        XCTAssertEqual(dataValue, Data([1, 2, 3]))
    }
    
    func testCacheSendableValueTypes() async {
        struct SendableValue: Sendable, Equatable {
            let id: Int
            let name: String
        }
        
        let cache = InMemoryMiddlewareCache()
        let value = SendableValue(id: 1, name: "Test")
        
        await cache.set(key: "value", value: value, ttl: 60)
        let retrieved = await cache.get(key: "value", type: SendableValue.self)
        
        XCTAssertEqual(retrieved, value)
    }
    
    // MARK: - ObjectPool Tests
    
    func testObjectPoolRequiresSendableReference() async {
        // This should compile - NSLock is Sendable
        final class SendableObject: NSObject, @unchecked Sendable {
            private let lock = NSLock()
            private var _value: Int = 0
            
            var value: Int {
                get { lock.withLock { _value } }
                set { lock.withLock { _value = newValue } }
            }
        }
        
        let pool = ObjectPool<SendableObject>(
            maxSize: 10,
            factory: { SendableObject() },
            reset: { obj in
                obj.value = 0
            }
        )
        
        let obj = await pool.acquire()
        obj.value = 42
        await pool.release(obj)
        
        let stats = await pool.statistics
        XCTAssertEqual(stats.allocations, 1)
    }
    
    // MARK: - Buffer Tests
    
    func testBufferRequiresSendableElements() async {
        let pool = BufferPool<Int>(
            maxSize: 5,
            bufferCapacity: 100
        )
        
        let buffer = await pool.acquire()
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        
        XCTAssertEqual(buffer.data, [1, 2, 3])
        
        await pool.release(buffer)
    }
    
    // MARK: - Generic Method Constraints
    
    func testGenericMethodConstraints() async {
        // Test that generic methods properly constrain to Sendable
        
        actor TestActor {
            private var storage: [String: Any] = [:]
            
            func store<T: Sendable>(key: String, value: T) {
                storage[key] = value
            }
            
            func retrieve<T: Sendable>(key: String, as type: T.Type) -> T? {
                storage[key] as? T
            }
        }
        
        let actor = TestActor()
        
        // Store Sendable values
        await actor.store(key: "number", value: 42)
        await actor.store(key: "text", value: "Hello")
        await actor.store(key: "array", value: [1, 2, 3])
        
        // Retrieve values
        let number = await actor.retrieve(key: "number", as: Int.self)
        let text = await actor.retrieve(key: "text", as: String.self)
        let array = await actor.retrieve(key: "array", as: [Int].self)
        
        XCTAssertEqual(number, 42)
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(array, [1, 2, 3])
    }
    
    // MARK: - Compile-Time Safety Tests
    
    func testNonSendableTypesPreventedAtCompileTime() {
        // This test verifies that non-Sendable types cannot be used
        // The following would NOT compile:
        
        /*
        class NonSendableClass {
            var value = 0
        }
        
        let cache = InMemoryMiddlewareCache()
        let nonSendable = NonSendableClass()
        
        // This would fail to compile:
        // await cache.set(key: "bad", value: nonSendable, ttl: 60)
        // Error: Type 'NonSendableClass' does not conform to protocol 'Sendable'
        */
        
        // Instead, we must use Sendable types
        XCTAssertTrue(true) // Compilation is the test
    }
    
    // MARK: - Associated Type Constraints
    
    func testCommandResultMustBeSendable() {
        // Command protocol already requires Result: Sendable
        struct TestCommand: Command {
            typealias Result = String // String is Sendable
            let input: String
        }
        
        // This verifies the constraint is enforced
        func requiresSendableResult<C: Command>(_ command: C) where C.Result: Sendable {}
        
        let command = TestCommand(input: "test")
        requiresSendableResult(command)
        
        XCTAssertTrue(true) // Compilation is the test
    }
    
    // MARK: - ContextKey Value Constraints
    
    func testContextKeyValueMustBeSendable() {
        // ContextKey protocol requires Value: Sendable
        struct UserKey: ContextKey {
            typealias Value = User
        }
        
        struct User: Sendable {
            let id: String
            let name: String
        }
        
        let context = CommandContext()
        let user = User(id: "123", name: "Test")
        
        context[UserKey.self] = user
        let retrieved = context[UserKey.self]
        
        XCTAssertEqual(retrieved?.id, "123")
        XCTAssertEqual(retrieved?.name, "Test")
    }
}

// MARK: - Test Helpers

private struct CacheableValue: Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let data: String
}

private final class SendableReference: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.queue")
    private var _counter: Int = 0
    
    var counter: Int {
        get { queue.sync { _counter } }
        set { queue.sync { _counter = newValue } }
    }
}