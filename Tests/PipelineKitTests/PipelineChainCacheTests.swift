//
//  PipelineChainCacheTests.swift
//  PipelineKit
//
//  Tests for middleware-chain caching in StandardPipeline and DynamicPipeline.
//
//  These tests verify two properties of the chain cache:
//  1. Reuse correctness: executing the SAME pipeline multiple times reuses the cached chain
//     and still succeeds. This proves the cached chain is stateless across executions — each
//     invocation mints fresh `NextGuard`s rather than reusing a completed one (which would
//     throw `PipelineError.nextAlreadyCalled` on the second execution).
//  2. Invalidation correctness: mutating the middleware set (and, for DynamicPipeline, the
//     handler registry) invalidates the cache so subsequent executions observe the change.
//

import XCTest
@testable import PipelineKit
@testable import PipelineKitCore
import PipelineKitTestSupport

// MARK: - Shared Test Fixtures

/// A trivial command whose result is a string, used to make middleware effects observable.
private struct EchoCommand: Command {
    typealias Result = String
    let value: String

    func execute() async throws -> String { value }
}

/// Handler that echoes the command's value unchanged.
private struct ChainCacheHandler: CommandHandler {
    typealias CommandType = EchoCommand

    func handle(_ command: EchoCommand, context: CommandContext) async throws -> String {
        command.value
    }
}

/// Alternate handler that uppercases the command's value, used to detect stale-handler reuse
/// after re-registration in DynamicPipeline.
private struct UppercaseChainCacheHandler: CommandHandler {
    typealias CommandType = EchoCommand

    func handle(_ command: EchoCommand, context: CommandContext) async throws -> String {
        command.value.uppercased()
    }
}

/// Middleware that appends a suffix to a `String` result after delegating to `next`.
///
/// Because the suffix is applied on the way *out* of the chain, the observable result string
/// records which middleware ran (and, by extension, in what order), making cache reuse and
/// invalidation directly testable.
private struct AppendMiddleware: Middleware {
    let suffix: String
    let priority: ExecutionPriority = .custom

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let result = try await next(command, context)
        if let stringResult = result as? String,
           let typed = (stringResult + suffix) as? T.Result {
            return typed
        }
        return result
    }
}

// MARK: - StandardPipeline Cache Tests

final class StandardPipelineChainCacheTests: XCTestCase {
    /// Executing the same pipeline twice must succeed both times with identical results.
    ///
    /// This is the core safety property of caching: the cached chain creates fresh `NextGuard`
    /// instances per execution. If a completed guard were reused, the second execution would
    /// throw `PipelineError.nextAlreadyCalled`.
    func testStandardPipelineReusesChainAcrossExecutions() async throws {
        let pipeline = StandardPipeline(handler: ChainCacheHandler())
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "1"))
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "2"))

        let first = try await pipeline.execute(EchoCommand(value: "x"), context: CommandContext.test())
        let second = try await pipeline.execute(EchoCommand(value: "x"), context: CommandContext.test())

        // Both executions succeed and produce the same result (cache reuse is transparent).
        XCTAssertEqual(first, second)
        // Sanity: both middlewares ran, so both suffixes are present.
        XCTAssertTrue(first.contains("1"))
        XCTAssertTrue(first.contains("2"))
    }

    /// Executing many times in a row must keep succeeding (stress the reuse path).
    func testStandardPipelineRepeatedExecutionsAllSucceed() async throws {
        let pipeline = StandardPipeline(handler: ChainCacheHandler())
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "a"))
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "b"))

        for _ in 0..<10 {
            let result = try await pipeline.execute(EchoCommand(value: "v"), context: CommandContext.test())
            XCTAssertTrue(result.hasPrefix("v"))
            XCTAssertTrue(result.contains("a"))
            XCTAssertTrue(result.contains("b"))
        }
    }

    /// Adding a middleware after a first execution must invalidate the cache so the newly
    /// added middleware takes effect on the next execution.
    func testStandardPipelineInvalidatesOnAddMiddleware() async throws {
        let pipeline = StandardPipeline(handler: ChainCacheHandler())
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "1"))

        // Prime the cache with a single middleware.
        let before = try await pipeline.execute(EchoCommand(value: "x"), context: CommandContext.test())
        XCTAssertFalse(before.contains("NEW"), "New middleware should not have run yet")

        // Mutate the middleware set; this must invalidate the cached chain.
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "NEW"))

        let after = try await pipeline.execute(EchoCommand(value: "x"), context: CommandContext.test())
        XCTAssertTrue(after.contains("NEW"), "Newly added middleware must run after cache invalidation")
        XCTAssertTrue(after.contains("1"), "Original middleware must still run")
    }

    /// Clearing middleware after priming the cache must invalidate it so the handler runs alone.
    func testStandardPipelineInvalidatesOnClearMiddlewares() async throws {
        let pipeline = StandardPipeline(handler: ChainCacheHandler())
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "1"))

        let before = try await pipeline.execute(EchoCommand(value: "x"), context: CommandContext.test())
        XCTAssertEqual(before, "x1")

        await pipeline.clearMiddlewares()

        let after = try await pipeline.execute(EchoCommand(value: "x"), context: CommandContext.test())
        XCTAssertEqual(after, "x", "After clearing middleware, only the handler should run")
    }
}

// MARK: - DynamicPipeline Cache Tests

final class DynamicPipelineChainCacheTests: XCTestCase {
    /// Sending the same command twice through a DynamicPipeline must succeed both times.
    ///
    /// Before the refactor, DynamicPipeline baked a single `NextGuard` into the chain structure;
    /// caching such a chain would throw `nextAlreadyCalled` on the second send. Routing through
    /// `MiddlewareChainBuilder.build` (lazy guard creation) makes reuse correct.
    func testDynamicPipelineSendTwiceSucceeds() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: ChainCacheHandler())
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "1"))
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "2"))

        let first = try await pipeline.send(EchoCommand(value: "x"))
        let second = try await pipeline.send(EchoCommand(value: "x"))

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("1"))
        XCTAssertTrue(first.contains("2"))
    }

    /// Adding middleware between sends must invalidate the per-command-type chain cache.
    func testDynamicPipelineInvalidatesOnAddMiddleware() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: ChainCacheHandler())
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "1"))

        // Prime the cache.
        let before = try await pipeline.send(EchoCommand(value: "x"))
        XCTAssertFalse(before.contains("NEW"))

        // Add another middleware; chainCache must be invalidated.
        try await pipeline.addMiddleware(AppendMiddleware(suffix: "NEW"))

        let after = try await pipeline.send(EchoCommand(value: "x"))
        XCTAssertTrue(after.contains("NEW"), "Newly added middleware must run after cache invalidation")
        XCTAssertTrue(after.contains("1"), "Original middleware must still run")
    }

    /// Re-registering (replacing) the handler for a command type after priming the cache must
    /// invalidate the chain cache so the NEW handler is used. This guards against the
    /// stale-handler bug that would occur if a chain closing over the old handler were reused.
    func testDynamicPipelineInvalidatesOnHandlerReRegister() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: ChainCacheHandler())

        // Prime the cache with the echo (lowercase) handler.
        let before = try await pipeline.send(EchoCommand(value: "abc"))
        XCTAssertEqual(before, "abc")

        // Re-register a different handler for the same command type.
        await pipeline.register(EchoCommand.self, handler: UppercaseChainCacheHandler())

        let after = try await pipeline.send(EchoCommand(value: "abc"))
        XCTAssertEqual(after, "ABC", "Re-registered handler must be used after cache invalidation")
    }

    /// `replace(_:with:)` must likewise invalidate the chain cache.
    func testDynamicPipelineInvalidatesOnHandlerReplace() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: ChainCacheHandler())

        let before = try await pipeline.send(EchoCommand(value: "abc"))
        XCTAssertEqual(before, "abc")

        let replaced = await pipeline.replace(EchoCommand.self, with: UppercaseChainCacheHandler())
        XCTAssertTrue(replaced, "A previous handler should have existed")

        let after = try await pipeline.send(EchoCommand(value: "abc"))
        XCTAssertEqual(after, "ABC", "Replaced handler must be used after cache invalidation")
    }

    /// Unregistering the handler after priming the cache must invalidate the chain so a
    /// subsequent send fails with `handlerNotFound` rather than silently invoking a stale chain.
    func testDynamicPipelineInvalidatesOnUnregister() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: ChainCacheHandler())

        let before = try await pipeline.send(EchoCommand(value: "abc"))
        XCTAssertEqual(before, "abc")

        let removed = await pipeline.unregister(EchoCommand.self)
        XCTAssertTrue(removed)

        do {
            _ = try await pipeline.send(EchoCommand(value: "abc"), retryPolicy: .none)
            XCTFail("Expected handlerNotFound after unregister")
        } catch let error as PipelineError {
            guard case .handlerNotFound = error else {
                return XCTFail("Expected .handlerNotFound, got \(error)")
            }
        }
    }
}
