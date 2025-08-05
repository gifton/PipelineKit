import XCTest
import CryptoKit
@testable import PipelineKitSecurity
@testable import PipelineKitTestSupport

final class InMemoryKeyStoreTests: XCTestCase {
    func testConcurrentAccess() async throws {
        let store = InMemoryKeyStore()
        let iterations = 100
        let keyCount = 10
        
        // Generate test keys
        let testKeys = (0..<keyCount).map { i in
            (identifier: "key-\(i)", key: SymmetricKey(size: .bits256))
        }
        
        // Track expected state
        let expectedKeys = Set(testKeys.map { $0.identifier })
        
        // Concurrent operations
        await withTaskGroup(of: Void.self) { group in
            // Concurrent stores
            for _ in 0..<iterations {
                for (identifier, key) in testKeys {
                    group.addTask {
                        await store.store(key: key, identifier: identifier)
                    }
                }
            }
            
            // Concurrent reads
            for _ in 0..<iterations {
                for (identifier, _) in testKeys {
                    group.addTask {
                        _ = await store.key(for: identifier)
                    }
                }
            }
            
            // Concurrent current key access
            for _ in 0..<iterations {
                group.addTask {
                    _ = await store.currentKey
                    _ = await store.currentKeyIdentifier
                }
            }
        }
        
        // Verify final state
        for (identifier, key) in testKeys {
            let storedKey = await store.key(for: identifier)
            XCTAssertNotNil(storedKey, "Key \(identifier) should be stored")
        }
        
        // Verify current key is one of the test keys
        let currentIdentifier = await store.currentKeyIdentifier
        XCTAssertTrue(expectedKeys.contains(currentIdentifier ?? ""),
                     "Current key should be one of the test keys")
    }
    
    func testConcurrentStoreAndRemove() async throws {
        let store = InMemoryKeyStore()
        let iterations = 50
        
        // Store initial keys
        for i in 0..<10 {
            let key = SymmetricKey(size: .bits256)
            await store.store(key: key, identifier: "initial-\(i)")
        }
        
        // Set some keys to be old
        let oldDate = Date().addingTimeInterval(-3600) // 1 hour ago
        
        await withTaskGroup(of: Void.self) { group in
            // Concurrent stores of new keys
            for i in 0..<iterations {
                group.addTask {
                    let key = SymmetricKey(size: .bits256)
                    await store.store(key: key, identifier: "new-\(i)")
                }
            }
            
            // Concurrent removal of expired keys
            for _ in 0..<iterations {
                group.addTask {
                    await store.removeExpiredKeys(before: oldDate)
                }
            }
            
            // Concurrent access to current key
            for _ in 0..<iterations {
                group.addTask {
                    _ = await store.currentKey
                }
            }
        }
        
        // Verify current key is still accessible
        let currentKey = await store.currentKey
        XCTAssertNotNil(currentKey, "Should have a current key after concurrent operations")
    }
    
    func testRaceConditionOnSameKey() async throws {
        let store = InMemoryKeyStore()
        let iterations = 100
        let keyIdentifier = "shared-key"
        
        // Multiple tasks trying to update the same key
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let key = SymmetricKey(size: .bits256)
                    await store.store(key: key, identifier: keyIdentifier)
                }
                
                group.addTask {
                    _ = await store.key(for: keyIdentifier)
                }
            }
        }
        
        // Verify key exists and is accessible
        let finalKey = await store.key(for: keyIdentifier)
        XCTAssertNotNil(finalKey, "Key should exist after concurrent updates")
        
        // Verify it's the current key
        let currentIdentifier = await store.currentKeyIdentifier
        XCTAssertEqual(currentIdentifier, keyIdentifier,
                      "Last stored key should be current")
    }
    
    func testConcurrentExpiration() async throws {
        let store = InMemoryKeyStore()
        
        // Store keys that will be expired
        for i in 0..<20 {
            let key = SymmetricKey(size: .bits256)
            await store.store(key: key, identifier: "expired-\(i)")
        }
        
        // Store current key that won't be expired
        let currentKey = SymmetricKey(size: .bits256)
        await store.store(key: currentKey, identifier: "current")
        
        let futureDate = Date().addingTimeInterval(1) // 1 second in future
        
        // Concurrent expiration attempts
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await store.removeExpiredKeys(before: futureDate)
                }
                
                group.addTask {
                    _ = await store.currentKey
                }
                
                group.addTask {
                    // Try to access potentially expired keys
                    _ = await store.key(for: "expired-\(Int.random(in: 0..<20))")
                }
            }
        }
        
        // Current key should never be removed
        let finalCurrentKey = await store.key(for: "current")
        XCTAssertNotNil(finalCurrentKey, "Current key should not be removed by expiration")
        
        let currentIdentifier = await store.currentKeyIdentifier
        XCTAssertEqual(currentIdentifier, "current",
                      "Current key identifier should remain unchanged")
    }
    
    func testActorIsolation() async throws {
        let store = InMemoryKeyStore()
        let expectation = expectation(description: "No data races")
        expectation.expectedFulfillmentCount = 1
        
        // This test verifies that actor isolation prevents data races
        let task1 = Task {
            for i in 0..<100 {
                let key = SymmetricKey(size: .bits256)
                await store.store(key: key, identifier: "task1-\(i)")
            }
        }
        
        let task2 = Task {
            for i in 0..<100 {
                let key = SymmetricKey(size: .bits256)
                await store.store(key: key, identifier: "task2-\(i)")
            }
        }
        
        let task3 = Task {
            for _ in 0..<100 {
                _ = await store.currentKey
                _ = await store.currentKeyIdentifier
            }
        }
        
        // Wait for all tasks
        await task1.value
        await task2.value
        await task3.value
        
        // If we reach here without crashes, actor isolation is working
        expectation.fulfill()
        
        await fulfillment(of: [expectation], timeout: 5)
    }
}
