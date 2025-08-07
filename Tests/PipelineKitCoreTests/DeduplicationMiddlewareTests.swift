import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

// MARK: - DeduplicationMiddleware Tests (Commented Out - Feature Not Implemented Yet)

/*
 These tests are for a deduplication middleware feature that hasn't been implemented yet.
 The following types need to be created before these tests can be uncommented:
 - InMemoryDeduplicationCache
 - DeduplicationMiddleware
 - DeduplicationError
 - DeduplicationStrategy (.reject, .returnCached, .markAndProceed)
 - CommandContext.isDuplicate property
 - ObserverRegistry
 */

final class DeduplicationMiddlewareTests: XCTestCase {
    func testPlaceholder() {
        // Placeholder test to keep the test class valid
        XCTAssertTrue(true, "Deduplication feature not implemented yet")
    }
    
    /*
    func testDuplicateRejection() async throws {
        // Given
        let cache = InMemoryDeduplicationCache()
        let middleware = DeduplicationMiddleware(
            cache: cache,
            window: 60,
            strategy: .reject
        )
        
        let command = DedupeTestCommand(id: "123", value: "test")
        let context = CommandContext()
        
        let executionCounter = TestActor<Int>(0)
        
        // First execution - should succeed
        let result1 = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        XCTAssertEqual(result1, "test")
        let count = await executionCounter.get()
        XCTAssertEqual(count, 1)
        
        // Second execution - should be rejected
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                await executionCounter.increment()
                return cmd.value
            }
            XCTFail("Should have thrown DeduplicationError")
        } catch let error as DeduplicationError {
            if case .duplicateCommand = error {
                // Expected
            } else {
                XCTFail("Wrong error type")
            }
        }
        
        let count = await executionCounter.get()
        XCTAssertEqual(count, 1) // Should not execute again
    }
    
    func testReturnCachedStrategy() async throws {
        // Given
        let cache = InMemoryDeduplicationCache()
        let middleware = DeduplicationMiddleware(
            cache: cache,
            window: 60,
            strategy: .returnCached
        )
        
        let command = DedupeTestCommand(id: "cached", value: "original")
        let context = CommandContext()
        
        let executionCounter = TestActor<Int>(0)
        let returnValueActor = TestActor<String>("original")
        
        // First execution
        let result1 = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            return await returnValueActor.get()
        }
        
        XCTAssertEqual(result1, "original")
        let count = await executionCounter.get()
        XCTAssertEqual(count, 1)
        
        // Change the return value (to prove cache is used)
        await returnValueActor.set("modified")
        
        // Second execution - should return cached result
        let result2 = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            return await returnValueActor.get()
        }
        
        XCTAssertEqual(result2, "original") // Cached value
        let count = await executionCounter.get()
        XCTAssertEqual(count, 1) // Should not execute
    }
    
    func testMarkAndProceedStrategy() async throws {
        // Given
        let cache = InMemoryDeduplicationCache()
        let middleware = DeduplicationMiddleware(
            cache: cache,
            window: 60,
            strategy: .markAndProceed
        )
        
        let command = DedupeTestCommand(id: "mark", value: "test")
        let context = CommandContext()
        
        let executionCounter = TestActor<Int>(0)
        
        // First execution
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            let isDupe = await context.isDuplicate
            XCTAssertFalse(isDupe) // First execution is not duplicate
            return cmd.value
        }
        
        // Second execution
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            let isDupe = await context.isDuplicate
            XCTAssertTrue(isDupe) // Second execution is marked as duplicate
            return cmd.value
        }
        
        let count = await executionCounter.get()
        XCTAssertEqual(count, 2) // Both should execute
    }
    
    func testDeduplicationWindow() async throws {
        // Given
        let cache = InMemoryDeduplicationCache()
        let middleware = DeduplicationMiddleware(
            cache: cache,
            window: 0.1, // 100ms window
            strategy: .reject
        )
        
        let command = DedupeTestCommand(id: "window", value: "test")
        let context = CommandContext()
        
        let executionCounter = Actor<Int>(0)
        
        // First execution
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        let count1 = await executionCounter.get()
        XCTAssertEqual(count1, 1)
        
        // Second execution within window - should be rejected
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                await executionCounter.increment()
                return cmd.value
            }
            XCTFail("Should have been rejected")
        } catch is DeduplicationError {
            // Expected
        }
        
        // Wait for window to expire
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Third execution outside window - should succeed
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            await executionCounter.increment()
            return cmd.value
        }
        
        let count2 = await executionCounter.get()
        XCTAssertEqual(count2, 2)
    }
    
    func testCustomFingerprinter() async throws {
        // Given
        let cache = InMemoryDeduplicationCache()
        let middleware = DeduplicationMiddleware(
            cache: cache,
            window: 60,
            strategy: .reject,
            fingerprinter: { command in
                // Custom fingerprinter that only uses the ID
                if let cmd = command as? DedupeTestCommand {
                    return "custom-\(cmd.id)"
                }
                return "unknown"
            }
        )
        
        let command1 = DedupeTestCommand(id: "same", value: "value1")
        let command2 = DedupeTestCommand(id: "same", value: "value2") // Same ID, different value
        let context = CommandContext()
        
        // Execute first command
        _ = try await middleware.execute(command1, context: context) { cmd, _ in
            cmd.value
        }
        
        // Execute second command with same ID - should be rejected
        do {
            _ = try await middleware.execute(command2, context: context) { cmd, _ in
                cmd.value
            }
            XCTFail("Should have been rejected")
        } catch is DeduplicationError {
            // Expected - same fingerprint
        }
    }
    
    func testDeduplicationEvents() async throws {
        // Given
        let cache = InMemoryDeduplicationCache()
        let middleware = DeduplicationMiddleware(
            cache: cache,
            window: 60,
            strategy: .reject
        )
        
        let eventCollector = TestDedupeEventCollector()
        let observerRegistry = ObserverRegistry(observers: [eventCollector])
        
        let command = DedupeTestCommand(id: "events", value: "test")
        let context = CommandContext()
        await context.setObserverRegistry(observerRegistry)
        
        // First execution
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            cmd.value
        }
        
        await eventCollector.waitForEvents(count: 1) // stored event
        
        let events1 = await eventCollector.getEvents()
        XCTAssertTrue(events1.contains { $0.name == "deduplication.stored" })
        
        await eventCollector.clear()
        
        // Second execution - duplicate
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                cmd.value
            }
        } catch {
            // Expected
        }
        
        await eventCollector.waitForEvents(count: 1) // rejected event
        
        let events2 = await eventCollector.getEvents()
        XCTAssertTrue(events2.contains { $0.name == "deduplication.rejected" })
    }
    
    func testCacheCleanup() async throws {
        // Given
        let cache = InMemoryDeduplicationCache()
        let middleware = DeduplicationMiddleware(cache: cache)
        
        let commands = (0..<5).map { DedupeTestCommand(id: "\($0)", value: "test\($0)") }
        let context = CommandContext()
        
        // Execute all commands
        for command in commands {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                cmd.value
            }
        }
        
        // Verify all are cached
        for command in commands {
            do {
                _ = try await middleware.execute(command, context: context) { cmd, _ in
                    cmd.value
                }
                XCTFail("Should have been rejected")
            } catch is DeduplicationError {
                // Expected
            }
        }
        
        // Clean up old entries
        let cutoffDate = Date().addingTimeInterval(-30) // 30 seconds ago
        await cache.cleanupOlderThan(cutoffDate)
        
        // Clear all
        await cache.clear()
        
        // Now all commands should execute again
        for command in commands {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                cmd.value
            }
        }
    }
    
    func testHashableCommandDeduplication() async throws {
        // Given
        let cache = InMemoryDeduplicationCache()
        let middleware = DeduplicationMiddleware.forCommandType(
            HashableDedupeCommand.self,
            cache: cache,
            window: 60,
            strategy: .reject
        )
        
        let command1 = HashableDedupeCommand(id: 123, data: "test")
        let command2 = HashableDedupeCommand(id: 123, data: "test") // Equal
        let command3 = HashableDedupeCommand(id: 456, data: "other") // Different
        let context = CommandContext()
        
        // Execute first command
        _ = try await middleware.execute(command1, context: context) { cmd, _ in
            cmd.data
        }
        
        // Execute equal command - should be rejected
        do {
            _ = try await middleware.execute(command2, context: context) { cmd, _ in
                cmd.data
            }
            XCTFail("Should have been rejected")
        } catch is DeduplicationError {
            // Expected
        }
        
        // Execute different command - should succeed
        let result = try await middleware.execute(command3, context: context) { cmd, _ in
            cmd.data
        }
        
        XCTAssertEqual(result, "other")
    }
    */
}

/*
// Test support types
private struct DedupeTestCommand: Command {
    typealias Result = String
    let id: String
    let value: String
    
    func execute() async throws -> String {
        value
    }
}

private struct HashableDedupeCommand: Command, Hashable {
    typealias Result = String
    let id: Int
    let data: String
    
    func execute() async throws -> String {
        data
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(data)
    }
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.data == rhs.data
    }
}

private actor TestDedupeEventCollector: PipelineObserver {
    private var events: [(name: String, properties: [String: Sendable])] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    
    func getEvents() -> [(name: String, properties: [String: Sendable])] {
        events
    }
    
    func clear() {
        events.removeAll()
    }
    
    func waitForEvents(count: Int) async {
        while events.count < count {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }
    
    private func notifyWaiters() {
        let waiters = continuations
        continuations.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }
    
    // PipelineObserver conformance
    func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {}
    func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {}
    func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {}
    func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {}
    func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {}
    func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {}
    func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {}
    func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {}
    func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {}
    
    func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        events.append((name: eventName, properties: properties))
        notifyWaiters()
    }
}
*/
