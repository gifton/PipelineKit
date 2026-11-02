import Synchronization
import XCTest
@testable import PipelineKit
import PipelineKitCore

final class BuilderCompositionContractTests: XCTestCase {
    // The Cartesian product covers both insertion orders, including same-family pairs.
    // Array families receive two stages; duplicate cases reuse the same instance throughout.
    func testAllBuilderFamilyPairsPreserveStages() async throws {
        for first in AdditionFamily.allCases {
            for second in AdditionFamily.allCases {
                for scenario in AdditionScenario.allCases {
                    let duplicate = scenario == .duplicate
                    let trace = Trace()
                    let a = RecordingStage("a", priority: .observability, trace: trace)
                    let b = duplicate ? a : RecordingStage("b", priority: .observability, trace: trace)
                    let rightIntrinsic: ExecutionPriority = scenario == .uniqueMixedPriorities ? .validation : .observability
                    let c = duplicate ? a : RecordingStage("c", priority: rightIntrinsic, trace: trace)
                    let d = duplicate ? a : RecordingStage("d", priority: rightIntrinsic, trace: trace)
                    let left = first.isBatch ? [a, b] : [a]
                    let right = second.isBatch ? [c, d] : [c]
                    let leftPriority = first == .explicitOrder ? 100 : 700
                    let rightPriority = second == .explicitOrder ? 100 : (scenario == .uniqueMixedPriorities ? 200 : 700)
                    let expected = leftPriority <= rightPriority ? left + right : right + left
                    let expectedPriorities = leftPriority <= rightPriority
                        ? Array(repeating: leftPriority, count: left.count) + Array(repeating: rightPriority, count: right.count)
                        : Array(repeating: rightPriority, count: right.count) + Array(repeating: leftPriority, count: left.count)
                    let label = "\(first) then \(second), \(scenario)"
                    let builder = PipelineBuilder(handler: RecordingHandler<UnscopedCommand>(trace: trace))
                    await first.add(left, to: builder)
                    await second.add(right, to: builder)

                    let pipeline = try await builder.build()
                    let count = await pipeline.middlewareCount
                    let details = await pipeline.getMiddlewareDetails()
                    XCTAssertEqual(count, left.count + right.count, label)
                    XCTAssertEqual(details.map(\.priority), expectedPriorities, label)
                    let result = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
                    XCTAssertEqual(result, "handled", label)
                    XCTAssertEqual(trace.items, expected.map(\.id) + ["handler"], label)
                }
            }
        }
    }

    func testExplicitOrderSurvivesStandardPipelineSort() async throws {
        let trace = Trace()
        let builder = PipelineBuilder(handler: RecordingHandler<UnscopedCommand>(trace: trace))
        await builder.with(RecordingStage("late", priority: .authentication, trace: trace), order: .observability)
        await builder.with(RecordingStage("early-1", priority: .custom, trace: trace), order: .authentication)
        await builder.with(RecordingStage("early-2", priority: .observability, trace: trace), order: .authentication)
        let pipeline = try await builder.build()

        _ = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
        XCTAssertEqual(trace.take(), ["early-1", "early-2", "late", "handler"])
        let initialDetails = await pipeline.getMiddlewareDetails()
        XCTAssertEqual(initialDetails.map(\.priority), [100, 100, 700])

        try await pipeline.addMiddleware(RecordingStage("direct", priority: .authentication, trace: trace))
        _ = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
        XCTAssertEqual(trace.take(), ["early-1", "early-2", "direct", "late", "handler"])

        try await pipeline.addMiddlewares([
            RecordingStage("batch-1", priority: .authentication, trace: trace),
            RecordingStage("batch-2", priority: .validation, trace: trace)
        ])
        _ = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
        XCTAssertEqual(trace.items, ["early-1", "early-2", "direct", "batch-1", "batch-2", "late", "handler"])
        let finalDetails = await pipeline.getMiddlewareDetails()
        XCTAssertEqual(finalDetails.map(\.priority), [100, 100, 100, 100, 200, 700])
    }

    func testOrderBuilderRetainsTuplesIdentityAndStableTies() {
        let trace = Trace()
        let late = RecordingStage("late", priority: .authentication, trace: trace)
        let early = RecordingStage("early", priority: .custom, trace: trace)
        let tied = RecordingStage("tied", priority: .custom, trace: trace)
        let between = RecordingStage("between", priority: .custom, trace: trace)
        var builder = MiddlewareOrderBuilder()
        builder.add(late, order: .observability)
        builder.add(early, priority: 100)
        builder.add(tied, order: .authentication)
        builder.add(between, between: .authentication, and: .validation)

        let entries = builder.build()
        XCTAssertEqual(entries.map { $0.1 }, [100, 100, 150, 700])
        XCTAssertEqual(entries.compactMap { ($0.0 as? RecordingStage)?.id }, ["early", "tied", "between", "late"])
        XCTAssertTrue((entries[0].0 as? RecordingStage) === early)
        XCTAssertTrue((entries[1].0 as? RecordingStage) === tied)
        XCTAssertTrue((entries[2].0 as? RecordingStage) === between)
        XCTAssertTrue((entries[3].0 as? RecordingStage) === late)
    }

    func testRejectingStagePreventsHandlerEntry() async throws {
        for rejectingFirst in [false, true] {
            let trace = Trace()
            let builder = PipelineBuilder(handler: RecordingHandler<UnscopedCommand>(trace: trace))
            let reject = RejectingStage(trace: trace)
            let logging = RecordingStage("logging", priority: .observability, trace: trace)
            if rejectingFirst {
                await builder.with(reject)
                await builder.withLogging(logging)
            } else {
                await builder.withLogging(logging)
                await builder.with(reject)
            }
            let pipeline = try await builder.build()
            do {
                _ = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
                XCTFail("Expected rejection before handler entry, rejectingFirst=\(rejectingFirst)")
            } catch FixtureError.denied {
                // Expected: the configured rejecting stage is preserved and its error propagates.
            }
            XCTAssertEqual(trace.items, ["reject"])
        }
    }

    func testCapabilityMatrixAcrossBuilderArrayAndContiguousArray() async throws {
        for route in ChainRoute.allCases {
            for active in [false, true] {
                for replay in ReplayKind.allCases {
                    let trace = Trace()
                    let replayStage: any Middleware
                    switch replay {
                    case .unconditional: replayStage = ReplayStage(trace: trace)
                    case .conditional: replayStage = ConditionalReplayStage(active: active, trace: trace)
                    case .scoped: replayStage = ScopedReplayStage(trace: trace)
                    }
                    let stages: [any Middleware] = [
                        RecordingStage("ordinary", priority: .custom, trace: trace),
                        ConditionalStage(active: active, trace: trace),
                        ScopedStage(trace: trace),
                        replayStage
                    ]
                    let result: String
                    if active {
                        result = try await execute(ScopedCommand(), stages: stages, route: route, trace: trace)
                    } else {
                        result = try await execute(UnscopedCommand(), stages: stages, route: route, trace: trace)
                    }
                    let performsReplay = active || replay == .unconditional
                    let expected = ["ordinary"] + (active ? ["conditional", "scoped"] : [])
                        + (performsReplay ? ["replay", "handler", "handler"] : ["handler"])
                    XCTAssertEqual(result, "handled", "\(route), active=\(active), \(replay)")
                    XCTAssertEqual(trace.items, expected, "\(route), active=\(active), \(replay)")
                }
            }
        }
    }

    func testWarningAndGuardMatrixAcrossBuilderArrayAndContiguousArray() async throws {
        let warnings = Trace()
        let previousHandler = NextGuardConfiguration.shared.warningHandler
        let previousEmitWarnings = NextGuardConfiguration.shared.emitWarnings
        NextGuardConfiguration.setWarningHandler { warnings.add($0) }
        defer {
            NextGuardConfiguration.shared.warningHandler = previousHandler
            NextGuardConfiguration.shared.emitWarnings = previousEmitWarnings
        }

        for route in ChainRoute.allCases {
            for scenario in GuardScenario.allCases {
                let trace = Trace()
                let stage: any Middleware
                switch scenario {
                case .suppressed: stage = SuppressedStage(trace: trace)
                case .silent: stage = SilentStage(trace: trace)
                case .rejecting: stage = RejectingStage(trace: trace)
                case .doubleNext: stage = GuardedReplayStage(trace: trace)
                }
                do {
                    let result = try await execute(UnscopedCommand(), stages: [stage], route: route, trace: trace)
                    XCTAssertTrue(scenario == .suppressed || scenario == .silent, "\(route), \(scenario)")
                    XCTAssertEqual(result, "cached")
                    XCTAssertEqual(trace.items, ["short-circuit"])
                } catch FixtureError.denied {
                    XCTAssertEqual(scenario, .rejecting)
                    XCTAssertEqual(trace.items, ["reject"])
                } catch PipelineError.nextAlreadyCalled {
                    XCTAssertEqual(scenario, .doubleNext)
                    XCTAssertEqual(trace.items, ["guarded-replay", "handler"])
                }
                let captured = warnings.take()
                #if DEBUG
                XCTAssertEqual(captured.count, scenario == .silent ? 1 : 0, "\(route), \(scenario): \(captured)")
                if scenario == .silent { XCTAssertTrue(captured.first?.contains("SilentStage") == true) }
                #else
                XCTAssertTrue(captured.isEmpty)
                #endif
            }
        }
    }

    func testRemovalAndClearPreserveRawTypesAndInvalidateOrderedCache() async throws {
        let trace = Trace()
        let builder = PipelineBuilder(handler: RecordingHandler<UnscopedCommand>(trace: trace))
        await builder.with(RecordingStage("ordinary", priority: .authentication, trace: trace), order: .observability)
        await builder.with(ReplayStage(trace: trace), order: .authentication)
        let pipeline = try await builder.build()
        let types = await pipeline.middlewareTypes
        let hasReplay = await pipeline.hasMiddleware(ofType: ReplayStage.self)
        let details = await pipeline.getMiddlewareDetails()
        XCTAssertEqual(types, ["ReplayStage", "RecordingStage"])
        XCTAssertTrue(hasReplay)
        XCTAssertEqual(details.map { ObjectIdentifier($0.type) }, [ObjectIdentifier(ReplayStage.self), ObjectIdentifier(RecordingStage.self)])
        _ = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
        XCTAssertEqual(trace.take(), ["replay", "ordinary", "handler", "ordinary", "handler"])

        let removed = await pipeline.removeMiddleware(ofType: ReplayStage.self)
        XCTAssertEqual(removed, 1)
        try await pipeline.addMiddleware(RecordingStage("new", priority: .authentication, trace: trace))
        _ = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
        XCTAssertEqual(trace.take(), ["new", "ordinary", "handler"])

        await pipeline.clearMiddlewares()
        _ = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
        XCTAssertEqual(trace.take(), ["handler"])
        let count = await pipeline.middlewareCount
        XCTAssertEqual(count, 0)
    }

    func testEqualPrioritySurvivorsPrecedeNewAdditionsAfterRemoval() async throws {
        let trace = Trace()
        let builder = PipelineBuilder(handler: RecordingHandler<UnscopedCommand>(trace: trace))
        await builder.with(ScopedStage(trace: trace), order: .processing)
        await builder.with(ScopedStage(trace: trace), order: .processing)
        await builder.with(RecordingStage("first", priority: .custom, trace: trace), order: .processing)
        await builder.with(ScopedStage(trace: trace), order: .processing)
        await builder.with(RecordingStage("second", priority: .custom, trace: trace), order: .processing)
        let pipeline = try await builder.build()
        _ = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
        XCTAssertEqual(trace.take(), ["first", "second", "handler"])

        let removed = await pipeline.removeMiddleware(ofType: ScopedStage.self)
        XCTAssertEqual(removed, 3)
        try await pipeline.addMiddleware(RecordingStage("third", priority: .processing, trace: trace))
        _ = try await pipeline.execute(UnscopedCommand(), context: CommandContext())
        XCTAssertEqual(trace.items, ["first", "second", "third", "handler"])
    }

    private func execute<C: Command>(
        _ command: C,
        stages: [any Middleware],
        route: ChainRoute,
        trace: Trace
    ) async throws -> String where C.Result == String {
        let handler = RecordingHandler<C>(trace: trace)
        switch route {
        case .builder:
            let builder = PipelineBuilder(handler: handler)
            for stage in stages { await builder.with(stage, order: .processing) }
            let pipeline = try await builder.build()
            return try await pipeline.execute(command, context: CommandContext())
        case .array, .contiguousArray:
            let final: @Sendable (C, CommandContext) async throws -> String = { command, context in
                try await handler.handle(command, context: context)
            }
            let chain = route == .array
                ? MiddlewareChainBuilder.build(middlewares: stages, insertCancellationChecks: true, final: final)
                : MiddlewareChainBuilder.build(middlewares: ContiguousArray(stages), insertCancellationChecks: true, final: final)
            return try await chain(command, CommandContext())
        }
    }
}

private enum AdditionFamily: CaseIterable {
    case withOne, withArray, addMiddleware, addMiddlewares, explicitOrder
    case withAuthentication, addAuthentication, withAuthorization, addAuthorization
    case withRateLimiting, addRateLimiting, withLogging, addLogging

    var isBatch: Bool { self == .withArray || self == .addMiddlewares }

    func add(_ stages: [RecordingStage], to builder: PipelineBuilder<UnscopedCommand, RecordingHandler<UnscopedCommand>>) async {
        switch self {
        case .withOne: await builder.with(stages[0])
        case .withArray: await builder.with(stages)
        case .addMiddleware: await builder.addMiddleware(stages[0])
        case .addMiddlewares: await builder.addMiddlewares(stages)
        case .explicitOrder: await builder.with(stages[0], order: .authentication)
        case .withAuthentication: await builder.withAuthentication(stages[0])
        case .addAuthentication: await builder.addAuthentication(stages[0])
        case .withAuthorization: await builder.withAuthorization(stages[0])
        case .addAuthorization: await builder.addAuthorization(stages[0])
        case .withRateLimiting: await builder.withRateLimiting(stages[0])
        case .addRateLimiting: await builder.addRateLimiting(stages[0])
        case .withLogging: await builder.withLogging(stages[0])
        case .addLogging: await builder.addLogging(stages[0])
        }
    }
}

private enum ChainRoute: CaseIterable { case builder, array, contiguousArray }
private enum AdditionScenario: CaseIterable { case uniqueMixedPriorities, uniqueEqualPriorities, duplicate }
private enum ReplayKind: CaseIterable { case unconditional, conditional, scoped }
private enum GuardScenario: CaseIterable { case suppressed, silent, rejecting, doubleNext }
private enum FixtureError: Error { case denied, unexpectedResultType }
private protocol TestScope: Command {}
private struct ScopedCommand: TestScope { typealias Result = String }
private struct UnscopedCommand: Command { typealias Result = String }

private final class Trace: Sendable {
    private let storage = Mutex<[String]>([])
    func add(_ value: String) { storage.withLock { $0.append(value) } }
    var items: [String] { storage.withLock { $0 } }
    func take() -> [String] {
        storage.withLock { values in
            defer { values.removeAll() }
            return values
        }
    }
}

private struct RecordingHandler<C: Command>: CommandHandler where C.Result == String {
    let trace: Trace
    func handle(_ command: C, context: CommandContext) async throws -> String {
        trace.add("handler")
        return "handled"
    }
}

private final class RecordingStage: Middleware {
    let id: String
    let priority: ExecutionPriority
    let trace: Trace
    init(_ id: String, priority: ExecutionPriority, trace: Trace) {
        self.id = id
        self.priority = priority
        self.trace = trace
    }
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add(id)
        return try await next(command, context)
    }
}

private struct RejectingStage: Middleware {
    let priority = ExecutionPriority.authentication
    let trace: Trace
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add("reject")
        throw FixtureError.denied
    }
}

private struct ConditionalStage: ConditionalMiddleware {
    let active: Bool
    let trace: Trace
    func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool { active }
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add("conditional")
        return try await next(command, context)
    }
}

private struct ScopedStage: ScopedMiddleware {
    typealias Scope = any TestScope
    let trace: Trace
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add("scoped")
        return try await next(command, context)
    }
}

private struct ReplayStage: UnsafeMiddleware {
    let trace: Trace
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add("replay")
        _ = try await next(command, context)
        return try await next(command, context)
    }
}

private struct ConditionalReplayStage: ConditionalMiddleware, UnsafeMiddleware {
    let active: Bool
    let trace: Trace
    func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool { active }
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add("replay")
        _ = try await next(command, context)
        return try await next(command, context)
    }
}

private struct ScopedReplayStage: ScopedMiddleware, UnsafeMiddleware {
    typealias Scope = any TestScope
    let trace: Trace
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add("replay")
        _ = try await next(command, context)
        return try await next(command, context)
    }
}

private struct GuardedReplayStage: Middleware {
    let trace: Trace
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add("guarded-replay")
        _ = try await next(command, context)
        return try await next(command, context)
    }
}

private struct SuppressedStage: NextGuardWarningSuppressing {
    let trace: Trace
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add("short-circuit")
        guard let result = "cached" as? T.Result else { throw FixtureError.unexpectedResultType }
        return result
    }
}

private struct SilentStage: Middleware {
    let trace: Trace
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        trace.add("short-circuit")
        guard let result = "cached" as? T.Result else { throw FixtureError.unexpectedResultType }
        return result
    }
}
