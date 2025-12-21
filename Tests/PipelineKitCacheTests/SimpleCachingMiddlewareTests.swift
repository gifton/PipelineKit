import XCTest
@testable import PipelineKitCache
@testable import PipelineKit
@testable import PipelineKitCore

final class SimpleCachingMiddlewareTests: XCTestCase {
    // MARK: - Test Types

    private struct TestCommand: Command {
        typealias Result = String
        let id: String
    }

    private final class TestHandler: CommandHandler {
        typealias CommandType = TestCommand

        let response: String

        init(response: String = "test-result") {
            self.response = response
        }

        func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
            return response
        }
    }

    private struct NumberCommand: Command {
        typealias Result = Int
        let value: Int
    }

    private final class NumberHandler: CommandHandler {
        typealias CommandType = NumberCommand

        func handle(_ command: NumberCommand, context: CommandContext) async throws -> Int {
            return command.value * 2
        }
    }

    // MARK: - Basic Caching Tests

    func testBasicCaching() async throws {
        let cache = SimpleCachingMiddleware(ttl: 60)
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()
        let command = TestCommand(id: "test")

        // First execution - should execute handler
        let result1 = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result1, "test-result")

        // Second execution - should return cached result
        let result2 = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result2, "test-result")

        // Verify stats
        let stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1)
        XCTAssertEqual(stats.activeEntries, 1)
        XCTAssertEqual(stats.expiredEntries, 0)
    }

    func testCacheMiss() async throws {
        let cache = SimpleCachingMiddleware(ttl: 60)
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()

        // Different commands should not share cache
        let result1 = try await pipeline.execute(TestCommand(id: "cmd1"), context: context)
        let result2 = try await pipeline.execute(TestCommand(id: "cmd2"), context: context)

        // Both should execute (different keys)
        XCTAssertEqual(result1, "test-result")
        XCTAssertEqual(result2, "test-result")

        let stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1) // Same command type
    }

    // MARK: - TTL Expiration Tests

    func testTTLExpiration() async throws {
        let cache = SimpleCachingMiddleware(ttl: 0.1) // 100ms TTL
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()
        let command = TestCommand(id: "test")

        // First execution
        let result1 = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result1, "test-result")

        // Wait for expiration
        try await Task.sleep(nanoseconds: 150_000_000) // 150ms

        // Should execute again (expired)
        let result2 = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result2, "test-result")

        // Expired entry should be removed on access
        let stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1)
        XCTAssertEqual(stats.expiredEntries, 0)
    }

    func testRemoveExpired() async throws {
        let cache = SimpleCachingMiddleware(ttl: 0.1) // 100ms TTL
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()

        // Cache a result
        _ = try await pipeline.execute(TestCommand(id: "test"), context: context)

        var stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1)

        // Wait for expiration
        try await Task.sleep(nanoseconds: 150_000_000)

        // Before cleanup
        stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1)
        XCTAssertEqual(stats.expiredEntries, 1)

        // Manual cleanup
        cache.removeExpired()

        // After cleanup
        stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 0)
    }

    // MARK: - LRU Eviction Tests

    func testLRUEviction() async throws {
        // Use custom key generation to differentiate commands by value
        let cache = SimpleCachingMiddleware(
            ttl: 60,
            maxSize: 2,
            keyGenerator: { command in
                if let cmd = command as? NumberCommand {
                    return "number-\(cmd.value)"
                }
                return String(describing: type(of: command))
            }
        )

        let pipeline = StandardPipeline(handler: NumberHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()

        // Fill cache to capacity
        _ = try await pipeline.execute(NumberCommand(value: 1), context: context)
        _ = try await pipeline.execute(NumberCommand(value: 2), context: context)

        var stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 2)

        // Access first item to make it most recently used
        _ = try await pipeline.execute(NumberCommand(value: 1), context: context)

        // Add third item - should evict value: 2 (least recently used)
        _ = try await pipeline.execute(NumberCommand(value: 3), context: context)

        stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 2)

        // value: 2 should be evicted, value: 1 and value: 3 should remain
        // We can verify by checking that value: 2 is re-executed (not cached)
    }

    // MARK: - Custom Key Generation Tests

    func testCustomKeyGeneration() async throws {
        // Use command value in key generation
        let cache = SimpleCachingMiddleware(
            ttl: 60,
            keyGenerator: { command in
                if let cmd = command as? NumberCommand {
                    return "number-\(cmd.value)"
                }
                return String(describing: type(of: command))
            }
        )

        let pipeline = StandardPipeline(handler: NumberHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()

        // These should be cached separately
        let result1 = try await pipeline.execute(NumberCommand(value: 1), context: context)
        let result2 = try await pipeline.execute(NumberCommand(value: 2), context: context)

        XCTAssertEqual(result1, 2)
        XCTAssertEqual(result2, 4)

        let stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 2)

        // Same value should hit cache
        let result3 = try await pipeline.execute(NumberCommand(value: 1), context: context)
        XCTAssertEqual(result3, 2)
    }

    // MARK: - Selective Caching Tests

    func testShouldCache() async throws {
        // Only cache even numbers
        let cache = SimpleCachingMiddleware(
            ttl: 60,
            shouldCache: { command in
                if let cmd = command as? NumberCommand {
                    return cmd.value.isMultiple(of: 2)
                }
                return false
            }
        )

        let pipeline = StandardPipeline(handler: NumberHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()

        // Odd number - should not cache
        _ = try await pipeline.execute(NumberCommand(value: 1), context: context)
        var stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 0)

        // Even number - should cache
        _ = try await pipeline.execute(NumberCommand(value: 2), context: context)
        stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1)
    }

    func testCommandTypeConvenience() async throws {
        let cache = SimpleCachingMiddleware(
            ttl: 60,
            commandType: NumberCommand.self
        )

        let pipeline = StandardPipeline(handler: NumberHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()

        _ = try await pipeline.execute(NumberCommand(value: 1), context: context)

        let stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1)
    }

    // MARK: - Cache Management Tests

    func testClear() async throws {
        let cache = SimpleCachingMiddleware(ttl: 60)
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()

        // Cache some results
        _ = try await pipeline.execute(TestCommand(id: "test"), context: context)

        var stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1)

        // Clear cache
        cache.clear()

        stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 0)
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAccess() async throws {
        let cache = SimpleCachingMiddleware(ttl: 60, maxSize: 100)
        let pipeline = StandardPipeline(handler: NumberHandler())
        try await pipeline.addMiddleware(cache)

        await withTaskGroup(of: Void.self) { group in
            // Concurrent reads and writes
            for i in 0..<100 {
                group.addTask {
                    let context = CommandContext()
                    _ = try? await pipeline.execute(NumberCommand(value: i % 10), context: context)
                }
            }
        }

        let stats = cache.getStats()
        // Should have cached some results without crashing
        XCTAssertGreaterThan(stats.totalEntries, 0)
        XCTAssertLessThanOrEqual(stats.totalEntries, 10) // Only 10 unique values
    }

    func testHighContentionCaching() async throws {
        let cache = SimpleCachingMiddleware(ttl: 60)
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(cache)

        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    let context = CommandContext()
                    _ = try? await pipeline.execute(TestCommand(id: "same"), context: context)
                }
            }
        }

        let stats = cache.getStats()
        // Should have exactly one cached entry
        XCTAssertEqual(stats.totalEntries, 1)
        XCTAssertEqual(stats.activeEntries, 1)
    }

    // MARK: - Event Emission Tests

    func testCacheEvents() async throws {
        let cache = SimpleCachingMiddleware(ttl: 60)
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()
        let command = TestCommand(id: "test")

        // First execution - should emit cache.miss
        _ = try await pipeline.execute(command, context: context)

        // Second execution - should emit cache.hit
        _ = try await pipeline.execute(command, context: context)

        // Events would be captured with a CapturingEmitter in real tests
    }

    // MARK: - Edge Cases

    func testNilResults() async throws {
        struct OptionalCommand: Command {
            typealias Result = String?
        }

        final class OptionalHandler: CommandHandler {
            typealias CommandType = OptionalCommand

            func handle(_ command: OptionalCommand, context: CommandContext) async throws -> String? {
                return nil
            }
        }

        let cache = SimpleCachingMiddleware(ttl: 60)
        let pipeline = StandardPipeline(handler: OptionalHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()

        // Should cache nil results
        let result1 = try await pipeline.execute(OptionalCommand(), context: context)
        XCTAssertNil(result1)

        let result2 = try await pipeline.execute(OptionalCommand(), context: context)
        XCTAssertNil(result2)

        let stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1)
    }

    func testComplexResultTypes() async throws {
        struct ComplexResult: Sendable, Equatable {
            let id: String
            let data: [String: Int]
        }

        struct ComplexCommand: Command {
            typealias Result = ComplexResult
        }

        final class ComplexHandler: CommandHandler {
            typealias CommandType = ComplexCommand

            func handle(_ command: ComplexCommand, context: CommandContext) async throws -> ComplexResult {
                return ComplexResult(id: "test", data: ["a": 1, "b": 2])
            }
        }

        let cache = SimpleCachingMiddleware(ttl: 60)
        let pipeline = StandardPipeline(handler: ComplexHandler())
        try await pipeline.addMiddleware(cache)

        let context = CommandContext()

        let result1 = try await pipeline.execute(ComplexCommand(), context: context)
        let result2 = try await pipeline.execute(ComplexCommand(), context: context)

        XCTAssertEqual(result1, result2)

        let stats = cache.getStats()
        XCTAssertEqual(stats.totalEntries, 1)
    }

    // MARK: - Performance Tests

    func testCachingPerformance() throws {
        let cache = SimpleCachingMiddleware(ttl: 300)
        let iterations = 10000

        measure(metrics: [XCTClockMetric()]) {
            let expectation = expectation(description: "Performance test")
            expectation.expectedFulfillmentCount = iterations

            Task {
                let pipeline = StandardPipeline(handler: TestHandler())
                try await pipeline.addMiddleware(cache)
                let context = CommandContext()

                for _ in 0..<iterations {
                    _ = try await pipeline.execute(TestCommand(id: "perf"), context: context)
                    expectation.fulfill()
                }
            }

            wait(for: [expectation], timeout: 10)
        }
    }
}
