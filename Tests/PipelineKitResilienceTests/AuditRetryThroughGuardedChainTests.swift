//
//  AuditRetryThroughGuardedChainTests.swift
//  PipelineKit
//
//  Audit evidence tests (2026-08): pin the scenario an external review flagged as a
//  blocker — a retry's SECOND attempt traversing a guarded (non-Unsafe) middleware.
//  Safety rests on two independent properties:
//  1. RetryMiddleware/ResilientMiddleware conform to `UnsafeMiddleware`, so their own
//     `next` is unguarded and may be called once per attempt.
//  2. `MiddlewareChainBuilder.build` mints fresh `NextGuard`s inside the chain closure
//     on every invocation, so downstream guarded middleware gets a new guard per attempt.
//  Prior coverage exercised retry middlewares only in isolation (bare closures) or
//  cached-chain reuse across separate executions — never a real second attempt through
//  a guarded middleware. These tests close that gap.
//

import XCTest
@testable import PipelineKitCore
import PipelineKitResilience
import PipelineKit

// MARK: - Fixtures

private enum AuditTestError: Error {
    case transient
}

/// Actor-backed counter so fixtures stay Sendable under strict concurrency.
private actor AttemptCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    var value: Int { count }
}

private struct PingCommand: Command {
    typealias Result = String
}

/// Fails on the first attempt, succeeds on every subsequent one.
private struct FailOnceHandler: CommandHandler {
    typealias CommandType = PingCommand
    let attempts: AttemptCounter

    func handle(_ command: PingCommand, context: CommandContext) async throws -> String {
        let attempt = await attempts.increment()
        if attempt == 1 {
            throw AuditTestError.transient
        }
        return "ok after \(attempt)"
    }
}

/// A plain, guarded middleware (NOT `UnsafeMiddleware`): every traversal goes through a
/// freshly minted `NextGuard`. Counts traversals so the test can prove the second retry
/// attempt actually passed through it.
private struct GuardedCountingMiddleware: Middleware {
    let priority: ExecutionPriority = .custom
    let traversals: AttemptCounter

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        _ = await traversals.increment()
        return try await next(command, context)
    }
}

// MARK: - Tests

final class AuditRetryThroughGuardedChainTests: XCTestCase {
    /// RetryMiddleware's second attempt must traverse a guarded downstream middleware
    /// without throwing `PipelineError.nextAlreadyCalled`.
    func testRetryMiddlewareSecondAttemptTraversesGuardedMiddleware() async throws {
        let attempts = AttemptCounter()
        let traversals = AttemptCounter()
        let pipeline = StandardPipeline(handler: FailOnceHandler(attempts: attempts))

        let retry = RetryMiddleware(
            configuration: RetryMiddleware.Configuration(
                maxAttempts: 3,
                errorEvaluator: { error in error is AuditTestError }
            )
        )
        try await pipeline.addMiddleware(retry)
        try await pipeline.addMiddleware(GuardedCountingMiddleware(traversals: traversals))

        let result = try await pipeline.execute(PingCommand(), context: CommandContext())

        XCTAssertEqual(result, "ok after 2")
        let handlerAttempts = await attempts.value
        let guardedTraversals = await traversals.value
        XCTAssertEqual(handlerAttempts, 2, "handler should have been attempted twice")
        XCTAssertEqual(
            guardedTraversals, 2,
            "the guarded middleware must be traversed once per attempt with a fresh NextGuard"
        )
    }

    /// Same property for ResilientMiddleware's internal retry loop.
    func testResilientMiddlewareSecondAttemptTraversesGuardedMiddleware() async throws {
        let attempts = AttemptCounter()
        let traversals = AttemptCounter()
        let pipeline = StandardPipeline(handler: FailOnceHandler(attempts: attempts))

        let resilient = ResilientMiddleware(
            name: "audit",
            retryPolicy: RetryPolicy(
                maxAttempts: 2,
                delayStrategy: .immediate,
                shouldRetry: { _ in true }
            )
        )
        try await pipeline.addMiddleware(resilient)
        try await pipeline.addMiddleware(GuardedCountingMiddleware(traversals: traversals))

        let result = try await pipeline.execute(PingCommand(), context: CommandContext())

        XCTAssertEqual(result, "ok after 2")
        let guardedTraversals = await traversals.value
        XCTAssertEqual(
            guardedTraversals, 2,
            "the guarded middleware must be traversed once per attempt with a fresh NextGuard"
        )
    }

    /// DynamicPipeline's own `send(_:retryPolicy:)` loop re-invokes the cached chain; every
    /// attempt must re-mint guards for ALL middleware (this loop sits outside the chain, so
    /// even non-Unsafe middleware is legitimately re-executed).
    func testDynamicPipelineRetryPolicyReExecutesGuardedChain() async throws {
        let attempts = AttemptCounter()
        let traversals = AttemptCounter()
        let pipeline = DynamicPipeline()
        await pipeline.register(PingCommand.self, handler: FailOnceHandler(attempts: attempts))
        try await pipeline.addMiddleware(GuardedCountingMiddleware(traversals: traversals))

        let result = try await pipeline.send(
            PingCommand(),
            retryPolicy: RetryPolicy(
                maxAttempts: 3,
                delayStrategy: .immediate,
                shouldRetry: { _ in true }
            )
        )

        XCTAssertEqual(result, "ok after 2")
        let guardedTraversals = await traversals.value
        XCTAssertEqual(
            guardedTraversals, 2,
            "each retry attempt must re-run the guarded middleware with a fresh NextGuard"
        )
    }
}
