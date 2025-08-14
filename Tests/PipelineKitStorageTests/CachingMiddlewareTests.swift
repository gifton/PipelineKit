import XCTest
@testable import PipelineKit
@testable import PipelineKitStorage
import PipelineKitTestSupport

final class CachingMiddlewareTests: XCTestCase {
    func testCacheHit() async throws {
        // Given
        let cache = InMemoryCache(maxSize: 100)
        let middleware = CachingMiddleware(
            cache: cache,
            keyGenerator: { command in
                if let cmd = command as? CacheTestCommand {
                    return "test-\(cmd.id)"
                }
                return "unknown"
            },
            ttl: 60
        )
        
        let command = CacheTestCommand(id: "123", value: "test")
        let context = CommandContext()
        
        let executionCounter = TestActor<Int>(0)
        
        // First execution - cache miss
        let result1 = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        XCTAssertEqual(result1, "test")
        let count1 = await executionCounter.get()
        XCTAssertEqual(count1, 1)
        
        // Second execution - cache hit
        let result2 = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        XCTAssertEqual(result2, "test")
        let count2 = await executionCounter.get()
        XCTAssertEqual(count2, 1) // Should not execute again
    }
    
    func testCacheMiss() async throws {
        // Given
        let cache = InMemoryCache(maxSize: 100)
        let middleware = CachingMiddleware(
            cache: cache,
            keyGenerator: { command in
                if let cmd = command as? CacheTestCommand {
                    return cmd.id
                }
                return String(describing: type(of: command))
            },
            ttl: 60
        )
        
        let command1 = CacheTestCommand(id: "1", value: "first")
        let command2 = CacheTestCommand(id: "2", value: "second")
        let context = CommandContext()
        
        let executionCounter = TestActor<Int>(0)
        
        // Execute different commands
        let result1 = try await middleware.execute(command1, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        let result2 = try await middleware.execute(command2, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        XCTAssertEqual(result1, "first")
        XCTAssertEqual(result2, "second")
        let count = await executionCounter.get()
        XCTAssertEqual(count, 2) // Both should execute
    }
    
    func testCacheTTLExpiration() async throws {
        // Given
        let cache = InMemoryCache(maxSize: 100)
        let middleware = CachingMiddleware(
            cache: cache,
            ttl: 0.1 // 100ms TTL
        )
        
        let command = CacheTestCommand(id: "ttl", value: "test")
        let context = CommandContext()
        
        let executionCounter = TestActor<Int>(0)
        
        // First execution
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        let count1 = await executionCounter.get()
        XCTAssertEqual(count1, 1)
        
        // Wait for TTL to expire
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Second execution - should miss cache due to expiration
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        let count2 = await executionCounter.get()
        XCTAssertEqual(count2, 2)
    }
    
    func testShouldCacheFunction() async throws {
        // Given
        let cache = InMemoryCache(maxSize: 100)
        let middleware = CachingMiddleware(
            cache: cache,
            keyGenerator: { command in
                if let cmd = command as? CacheTestCommand {
                    return cmd.id
                }
                return String(describing: type(of: command))
            },
            shouldCache: { command in
                // Only cache commands with specific IDs
                if let cmd = command as? CacheTestCommand {
                    return cmd.id.hasPrefix("cache-")
                }
                return false
            }
        )
        
        let cacheableCommand = CacheTestCommand(id: "cache-123", value: "cached")
        let nonCacheableCommand = CacheTestCommand(id: "nocache-456", value: "not-cached")
        let context = CommandContext()
        
        let executionCounter = TestActor<Int>(0)
        
        // Execute cacheable command twice
        _ = try await middleware.execute(cacheableCommand, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        _ = try await middleware.execute(cacheableCommand, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        let count1 = await executionCounter.get()
        XCTAssertEqual(count1, 1) // Should cache
        
        // Execute non-cacheable command twice
        _ = try await middleware.execute(nonCacheableCommand, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        _ = try await middleware.execute(nonCacheableCommand, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        let count2 = await executionCounter.get()
        XCTAssertEqual(count2, 3) // Should not cache
    }
    
    // TODO: Re-enable when EventEmitter is implemented  
    // func testCacheEventsEmitted() async throws {
    //     // Given
    //     let cache = InMemoryCache(maxSize: 100)
    //     let middleware = CachingMiddleware(
    //         cache: cache,
    //         keyGenerator: { command in
    //             if let cmd = command as? CacheTestCommand {
    //                 return cmd.id
    //             }
    //             return String(describing: type(of: command))
    //         }
    //     )
    //     
    //     let eventCollector = TestCacheEventCollector()
    //     let observerRegistry = ObserverRegistry(observers: [eventCollector])
    //     
    //     let command = CacheTestCommand(id: "event-test", value: "test")
    //     let context = CommandContext()
    //     await context.setObserverRegistry(observerRegistry)
    //     
    //     // First execution - cache miss
    //     _ = try await middleware.execute(command, context: context) { cmd, _ in
    //         cmd.value
    //     }
    //     
    //     // Wait for events
    //     await eventCollector.waitForEvents(count: 2) // miss + stored
    //     
    //     let events1 = await eventCollector.getEvents()
    //     XCTAssertTrue(events1.contains { $0.name == "cache.miss" })
    //     XCTAssertTrue(events1.contains { $0.name == "cache.stored" })
    //     
    //     await eventCollector.clear()
    //     
    //     // Second execution - cache hit
    //     _ = try await middleware.execute(command, context: context) { cmd, _ in
    //         cmd.value
    //     }
    //     
    //     await eventCollector.waitForEvents(count: 1) // hit
    //     
    //     let events2 = await eventCollector.getEvents()
    //     XCTAssertTrue(events2.contains { $0.name == "cache.hit" })
    // }
    
    func testCacheLRUEviction() async throws {
        // Given
        let cache = InMemoryCache(maxSize: 2) // Small cache
        let middleware = CachingMiddleware(
            cache: cache,
            keyGenerator: { command in
                if let cmd = command as? CacheTestCommand {
                    return cmd.id
                }
                return String(describing: type(of: command))
            }
        )
        
        let command1 = CacheTestCommand(id: "1", value: "first")
        let command2 = CacheTestCommand(id: "2", value: "second")
        let command3 = CacheTestCommand(id: "3", value: "third")
        let context = CommandContext()
        
        let executionCounts = TestActor<[String: Int]>([:])
        
        // Fill cache with command1 and command2
        _ = try await middleware.execute(command1, context: context) { cmd, _ in
            await executionCounts.incrementCount(for: cmd.id)
            return cmd.value
        }
        
        _ = try await middleware.execute(command2, context: context) { cmd, _ in
            await executionCounts.incrementCount(for: cmd.id)
            return cmd.value
        }
        
        // Access command1 to make it more recently used
        _ = try await middleware.execute(command1, context: context) { cmd, _ in
            await executionCounts.incrementCount(for: cmd.id)
            return cmd.value
        }
        
        // Add command3 - should evict command2 (LRU)
        _ = try await middleware.execute(command3, context: context) { cmd, _ in
            await executionCounts.incrementCount(for: cmd.id)
            return cmd.value
        }
        
        // Verify command1 is still cached
        _ = try await middleware.execute(command1, context: context) { cmd, _ in
            await executionCounts.incrementCount(for: cmd.id)
            return cmd.value
        }
        
        // Verify command2 was evicted
        _ = try await middleware.execute(command2, context: context) { cmd, _ in
            await executionCounts.incrementCount(for: cmd.id)
            return cmd.value
        }
        
        let counts = await executionCounts.get()
        XCTAssertEqual(counts["1"], 1) // Still cached
        XCTAssertEqual(counts["2"], 2) // Evicted and re-executed
        XCTAssertEqual(counts["3"], 1) // Cached
    }
}

// Test support types
private struct CacheTestCommand: Command, Hashable {
    typealias Result = String
    
    let id: String
    let value: String
    
    func execute() async throws -> String {
        value
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: CacheTestCommand, rhs: CacheTestCommand) -> Bool {
        lhs.id == rhs.id
    }
}

// TODO: Re-enable when EventEmitter is implemented
// private actor TestCacheEventCollector: PipelineObserver {
//     private var events: [(name: String, properties: [String: Sendable])] = []
//     private var continuations: [CheckedContinuation<Void, Never>] = []
//     
//     func getEvents() -> [(name: String, properties: [String: Sendable])] {
//         events
//     }
//     
//     func clear() {
//         events.removeAll()
//     }
//     
//     func waitForEvents(count: Int) async {
//         while events.count < count {
//             await withCheckedContinuation { continuation in
//                 continuations.append(continuation)
//             }
//         }
//     }
//     
//     private func notifyWaiters() {
//         let waiters = continuations
//         continuations.removeAll()
//         for continuation in waiters {
//             continuation.resume()
//         }
//     }
//     
//     // PipelineObserver conformance
//     func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {}
//     func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {}
//     func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {}
//     func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {}
//     func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {}
//     func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {}
//     func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {}
//     func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {}
//     func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {}
//     
//     func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
//         events.append((name: eventName, properties: properties))
//         notifyWaiters()
//     }
// }
