import XCTest
@testable import PipelineKit
@testable import PipelineKitMiddleware

final class CachingMiddlewareErrorTests: XCTestCase {
    private var cache: InMemoryCache!
    private var middleware: CachingMiddleware!
    
    override func setUp() async throws {
        try await super.setUp()
        cache = InMemoryCache()
        middleware = CachingMiddleware(cache: cache)
    }
    
    override func tearDown() async throws {
        cache = nil
        middleware = nil
        try await super.tearDown()
    }
    
    // MARK: - Encoding Error Tests
    
    func testNotEncodableError() async throws {
        // Given - A command that returns a non-encodable type
        let command = NonEncodableCommand()
        let context = CommandContext.test()
        
        // When/Then - Should throw encoding error
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                NonEncodableResult()
            }
            XCTFail("Should throw CachingError.notEncodable")
        } catch let error as CachingError {
            if case .notEncodable = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testEncodingFailureWithCircularReference() async throws {
        // Given - A command that returns a type with circular reference
        let command = CircularReferenceCommand()
        let context = CommandContext.test()
        
        // When/Then - Should handle encoding failure gracefully
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                CircularReferenceResult()
            }
            XCTFail("Should throw CachingError.notEncodable")
        } catch let error as CachingError {
            if case .notEncodable = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    // MARK: - Decoding Error Tests
    
    func testNotDecodableError() async throws {
        // Given - Corrupted data in cache
        let command = TestCacheCommand(id: "corrupted")
        let corruptedData = "not valid json".data(using: .utf8)!
        await cache.set(key: command.cacheKey, value: corruptedData, expiration: Date().addingTimeInterval(60))
        
        let context = CommandContext.test()
        
        // When/Then - Should throw decoding error
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Should not reach next handler")
                return "should not execute"
            }
            XCTFail("Should throw CachingError.notDecodable")
        } catch let error as CachingError {
            if case .notDecodable = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    func testTypeMismatchDecoding() async throws {
        // Given - Wrong type in cache
        let command = TestCacheCommand(id: "type-mismatch")
        let wrongTypeData = try JSONEncoder().encode(42) // Int instead of String
        await cache.set(key: command.cacheKey, value: wrongTypeData, expiration: Date().addingTimeInterval(60))
        
        let context = CommandContext.test()
        
        // When/Then - Should throw decoding error
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Should not reach next handler")
                return "should not execute"
            }
            XCTFail("Should throw CachingError.notDecodable")
        } catch let error as CachingError {
            if case .notDecodable = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    // MARK: - Cache Backend Error Tests
    
    func testCacheBackendFailure() async throws {
        // Given - A failing cache backend
        let failingCache = FailingCache(failureMode: .alwaysFail)
        let failingMiddleware = CachingMiddleware(cache: failingCache)
        
        let command = TestCacheCommand(id: "backend-failure")
        let context = CommandContext.test()
        
        // When - Cache operations fail
        let result = try await failingMiddleware.execute(command, context: context) { _, _ in
            return "fresh-result"
        }
        
        // Then - Should still execute command and return result
        XCTAssertEqual(result, "fresh-result", "Should fall back to execution on cache failure")
    }
    
    func testIntermittentCacheFailure() async throws {
        // Given - A cache that fails intermittently
        let intermittentCache = FailingCache(failureMode: .intermittent(failureRate: 0.5))
        let intermittentMiddleware = CachingMiddleware(cache: intermittentCache)
        
        let context = CommandContext.test()
        var successCount = 0
        var cacheHitCount = 0
        
        // When - Execute multiple times
        for i in 0..<20 {
            let command = TestCacheCommand(id: "intermittent-\(i % 5)") // Reuse some IDs
            
            do {
                let result = try await intermittentMiddleware.execute(command, context: context) { _, _ in
                    successCount += 1
                    return "result-\(i)"
                }
                
                if !result.starts(with: "result-") {
                    cacheHitCount += 1
                }
            } catch {
                // Some failures expected due to intermittent cache
            }
        }
        
        // Then - Should handle failures gracefully
        XCTAssertGreaterThan(successCount, 0, "Should have some successful executions")
        print("Success rate: \(successCount)/20, Cache hits: \(cacheHitCount)")
    }
    
    // MARK: - Concurrent Error Scenarios
    
    func testConcurrentCacheCorruption() async throws {
        // Given - Multiple concurrent operations on same cache key
        let command = TestCacheCommand(id: "concurrent")
        let context = CommandContext.test()
        
        // When - Many concurrent executions
        await withTaskGroup(of: Result<String, Error>.self) { group in
            for i in 0..<50 {
                group.addTask {
                    do {
                        let result = try await self.middleware.execute(command, context: context) { _, _ in
                            // Simulate variable processing time
                            if i % 3 == 0 {
                                await Task.yield()
                            }
                            return "result-\(i)"
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<String, Error>] = []
            for await result in group {
                results.append(result)
            }
            
            // Then - All should complete without corruption
            let successCount = results.filter { if case .success = $0 { return true } else { return false } }.count
            XCTAssertEqual(successCount, results.count, "All operations should succeed")
        }
    }
    
    // MARK: - TTL and Expiration Error Tests
    
    func testExpiredCacheEntry() async throws {
        // Given - A cache entry that expires immediately
        let command = TestCacheCommand(id: "expired")
        let data = try JSONEncoder().encode("cached-value")
        await cache.set(key: command.cacheKey, value: data, expiration: Date().addingTimeInterval(0.001)) // 1ms TTL
        
        // Wait for expiration
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        let context = CommandContext.test()
        
        // When
        let result = try await middleware.execute(command, context: context) { _, _ in
            return "fresh-value"
        }
        
        // Then - Should execute command due to expiration
        XCTAssertEqual(result, "fresh-value", "Should return fresh value after expiration")
    }
    
    // MARK: - Error Recovery Tests
    
    func testErrorRecoveryAfterCacheFailure() async throws {
        // Given - A cache that recovers after initial failure
        let recoveringCache = FailingCache(failureMode: .failThenRecover(failureCount: 3))
        let recoveringMiddleware = CachingMiddleware(cache: recoveringCache)
        
        let context = CommandContext.test()
        var results: [String] = []
        
        // When - Execute multiple times
        for i in 0..<6 {
            let command = TestCacheCommand(id: "recovery-\(i)")
            let result = try await recoveringMiddleware.execute(command, context: context) { _, _ in
                return "result-\(i)"
            }
            results.append(result)
        }
        
        // Then - Should recover and start caching again
        XCTAssertEqual(results.count, 6, "All executions should complete")
        
        // Verify cache is working again by executing same command
        let testCommand = TestCacheCommand(id: "recovery-test")
        let firstResult = try await recoveringMiddleware.execute(testCommand, context: context) { _, _ in
            return "first"
        }
        let secondResult = try await recoveringMiddleware.execute(testCommand, context: context) { _, _ in
            XCTFail("Should use cached value")
            return "second"
        }
        
        XCTAssertEqual(firstResult, secondResult, "Cache should be working after recovery")
    }
}

// MARK: - Test Support Types

struct NonEncodableCommand: Command { // CacheableCommand not implemented yet
    typealias Result = NonEncodableResult
    
    var cacheKey: String { "non-encodable" }
    var cacheTTL: TimeInterval { 60 }
}

struct NonEncodableResult {
    let closure: () -> Void = {} // Closures are not encodable
}

struct CircularReferenceCommand: Command { // CacheableCommand not implemented yet
    typealias Result = CircularReferenceResult
    
    var cacheKey: String { "circular" }
    var cacheTTL: TimeInterval { 60 }
}

class CircularReferenceResult: Codable {
    var selfReference: CircularReferenceResult?
    
    init() {
        selfReference = self // Circular reference
    }
}

struct TestCacheCommand: Command { // CacheableCommand not implemented yet
    typealias Result = String
    
    let id: String
    
    var cacheKey: String { "test-cache-\(id)" }
    var cacheTTL: TimeInterval { 60 }
}

// Failing cache implementation for testing error scenarios
actor FailingCache: CacheProtocol {
    enum FailureMode {
        case alwaysFail
        case intermittent(failureRate: Double)
        case failThenRecover(failureCount: Int)
    }
    
    private let failureMode: FailureMode
    private var operationCount = 0
    private let realCache = InMemoryCache()
    
    init(failureMode: FailureMode) {
        self.failureMode = failureMode
    }
    
    func get(key: String) async -> Data? {
        operationCount += 1
        
        switch failureMode {
        case .alwaysFail:
            return nil
        case .intermittent(let rate):
            if Double.random(in: 0...1) < rate {
                return nil
            }
            return await realCache.get(key: key)
        case .failThenRecover(let failureCount):
            if operationCount <= failureCount {
                return nil
            }
            return await realCache.get(key: key)
        }
    }
    
    func set(key: String, value: Data, expiration: Date?) async {
        operationCount += 1
        
        switch failureMode {
        case .alwaysFail:
            return
        case .intermittent(let rate):
            if Double.random(in: 0...1) < rate {
                return
            }
            await realCache.set(key: key, value: value, expiration: expiration)
        case .failThenRecover(let failureCount):
            if operationCount <= failureCount {
                return
            }
            await realCache.set(key: key, value: value, expiration: expiration)
        }
    }
    
    func remove(key: String) async {
        operationCount += 1
        
        switch failureMode {
        case .alwaysFail:
            return
        case .intermittent(let rate):
            if Double.random(in: 0...1) < rate {
                return
            }
            await realCache.remove(key: key)
        case .failThenRecover(let failureCount):
            if operationCount <= failureCount {
                return
            }
            await realCache.remove(key: key)
        }
    }
    
    func clear() async {
        operationCount += 1
        await realCache.clear()
    }
}