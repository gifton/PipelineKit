import XCTest
import PipelineKit
import PipelineKitCache

final class NextGuardSuppressionTests: XCTestCase {
    struct EchoCommand: Command { typealias Result = String; let text: String }

    final class EchoHandler: CommandHandler {
        typealias CommandType = EchoCommand
        func handle(_ command: EchoCommand) async throws -> String { "handled:\(command.text)" }
    }

    func testCachingMiddlewareSuppressesNextGuardWarningOnCacheHit() async throws {
        // Capture NextGuard warnings via an actor for thread safety
        actor WarningCollector { var items: [String] = []; func add(_ s: String) { items.append(s) }; func snapshot() -> [String] { items } }
        let collector = WarningCollector()
        NextGuardConfiguration.setWarningHandler { msg in
            Task { await collector.add(msg) }
        }
        NextGuardConfiguration.shared.emitWarnings = true

        // Build a pipeline with caching that uses a deterministic key
        let cache = InMemoryCache(maxSize: 10)
        let key = "test-cache-key"
        let caching = CachingMiddleware(
            cache: cache,
            keyGenerator: { _ in key },
            ttl: 60,
            shouldCache: { _ in true }
        )
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(caching)

        // First call: cache miss populates cache and calls next
        let miss = try await pipeline.execute(EchoCommand(text: "hi"), context: CommandContext())
        XCTAssertEqual(miss, "handled:hi")

        // Second call: cache hit short-circuits without calling next
        let hit = try await pipeline.execute(EchoCommand(text: "hi"), context: CommandContext())
        XCTAssertEqual(hit, "handled:hi")

        // NextGuard warning should be suppressed for the cache-hit short-circuit
        // If warnings array contains items, they should not be from NextGuard
        let warnings = await collector.snapshot()
        XCTAssertTrue(warnings.isEmpty, "Expected no NextGuard warnings, got: \(warnings)")
    }
}
