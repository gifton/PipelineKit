import XCTest
@testable import PipelineKit
import PipelineKitCore

final class DynamicRoutingGenerationTests: XCTestCase {
    func testCompletedReplacementAppliesToEveryLaterSelection() async throws {
        for mutation in HandlerMutation.allCases {
            let pipeline = DynamicPipeline()
            let gate = HandlerSelectionGate()
            await pipeline.register(RoutingCommand.self, handler: RoutingHandler(label: "A", gate: gate))

            try await withHeldSend(pipeline, gate: gate, expected: "A") {
                switch mutation {
                case .replace:
                    let replaced = await pipeline.replace(RoutingCommand.self, with: RoutingHandler(label: "B"))
                    XCTAssertTrue(replaced)
                case .overwrite:
                    await pipeline.register(RoutingCommand.self, handler: RoutingHandler(label: "B"))
                case .removeThenRegister:
                    let removed = await pipeline.unregister(RoutingCommand.self)
                    XCTAssertTrue(removed)
                    await pipeline.register(RoutingCommand.self, handler: RoutingHandler(label: "B"))
                case .clearThenRegister:
                    await pipeline.clear()
                    await pipeline.register(RoutingCommand.self, handler: RoutingHandler(label: "B"))
                }
                try await assertLaterSelections(pipeline, equal: "B", scenario: String(describing: mutation))
            }
            try await assertLaterSelections(pipeline, equal: "B", scenario: "after A settled: \(mutation)")
        }
    }

    func testConsecutiveReplacementsPreserveEachSelectedHandler() async throws {
        let pipeline = DynamicPipeline()
        let gateA = HandlerSelectionGate()
        let gateB = HandlerSelectionGate()
        await pipeline.register(RoutingCommand.self, handler: RoutingHandler(label: "A", gate: gateA))

        try await withHeldSend(pipeline, gate: gateA, expected: "A") {
            let replacedA = await pipeline.replace(RoutingCommand.self, with: RoutingHandler(label: "B", gate: gateB))
            XCTAssertTrue(replacedA)
            try await assertLaterSelections(pipeline, equal: "B", scenario: "first replacement")

            try await withHeldSend(pipeline, gate: gateB, expected: "B") {
                let replacedB = await pipeline.replace(RoutingCommand.self, with: RoutingHandler(label: "C"))
                XCTAssertTrue(replacedB)
                try await assertLaterSelections(pipeline, equal: "C", scenario: "A and B still held")
            }
            try await assertLaterSelections(pipeline, equal: "C", scenario: "B settled, A still held")
        }
        try await assertLaterSelections(pipeline, equal: "C", scenario: "A and B settled")
    }

    func testMiddlewareInvalidationPreservesCompletedReplacement() async throws {
        let scenarios: [(MiddlewareMutation, String)] = [
            (.add, "B|new|old"),
            (.addMultiple, "B|second|first|old"),
            (.clear, "B")
        ]
        for (mutation, expected) in scenarios {
            let pipeline = DynamicPipeline()
            let gate = HandlerSelectionGate()
            await pipeline.register(RoutingCommand.self, handler: RoutingHandler(label: "A", gate: gate))
            try await pipeline.addMiddleware(RoutingSuffix(suffix: "|old"))

            try await withHeldSend(pipeline, gate: gate, expected: "A|old") {
                let replaced = await pipeline.replace(RoutingCommand.self, with: RoutingHandler(label: "B"))
                XCTAssertTrue(replaced)
                try await assertLaterSelections(pipeline, equal: "B|old", scenario: "before middleware mutation")
                switch mutation {
                case .add:
                    try await pipeline.addMiddleware(RoutingSuffix(suffix: "|new"))
                case .addMultiple:
                    try await pipeline.addMiddlewares([RoutingSuffix(suffix: "|first"), RoutingSuffix(suffix: "|second")])
                case .clear:
                    await pipeline.clearMiddlewares()
                }
                try await assertLaterSelections(pipeline, equal: expected, scenario: String(describing: mutation))
            }
            try await assertLaterSelections(pipeline, equal: expected, scenario: "after old middleware settled")
        }
    }

    func testUnregisterAloneRejectsLaterSelectionsWhileOldHandlerFinishes() async throws {
        let pipeline = DynamicPipeline()
        let gate = HandlerSelectionGate()
        await pipeline.register(RoutingCommand.self, handler: RoutingHandler(label: "A", gate: gate))

        try await withHeldSend(pipeline, gate: gate, expected: "A") {
            let removed = await pipeline.unregister(RoutingCommand.self)
            XCTAssertTrue(removed)
            for _ in 0..<4 {
                try await assertMissingHandler(pipeline)
            }
        }
        try await assertMissingHandler(pipeline)
        let removedAgain = await pipeline.unregister(RoutingCommand.self)
        XCTAssertFalse(removedAgain)
    }

    func testRegistrationPoliciesAndTypeIdentityRemainUnchanged() async throws {
        let pipeline = DynamicPipeline()
        let replacedAbsent = await pipeline.replace(RoutingCommand.self, with: RoutingHandler(label: "A"))
        XCTAssertFalse(replacedAbsent)
        try await assertLaterSelections(pipeline, equal: "A", scenario: "replace inserts missing")

        do {
            try await pipeline.registerOnce(RoutingCommand.self, handler: RoutingHandler(label: "duplicate"))
            XCTFail("registerOnce must reject duplicates")
        } catch let error as PipelineError {
            guard case .pipelineNotConfigured(let reason) = error else {
                return XCTFail("Expected pipelineNotConfigured, got \(error)")
            }
            XCTAssertEqual(reason, "Handler already registered for RoutingCommand")
        }
        try await assertLaterSelections(pipeline, equal: "A", scenario: "rejected duplicate leaves A")

        await pipeline.register(OtherRoutingCommand.self, handler: OtherRoutingHandler())
        let types = await pipeline.registeredCommandTypes
        XCTAssertEqual(Set(types), Set([
            String(describing: ObjectIdentifier(RoutingCommand.self)),
            String(describing: ObjectIdentifier(OtherRoutingCommand.self))
        ]))
        let other = try await pipeline.send(OtherRoutingCommand(), retryPolicy: .none)
        XCTAssertEqual(other, 42)
        await pipeline.register(RoutingCommand.self, handler: RoutingHandler(label: "B"))
        try await assertLaterSelections(pipeline, equal: "B", scenario: "register overwrites")

        await pipeline.clear()
        let hasHandler = await pipeline.hasHandler(for: RoutingCommand.self)
        let clearedTypes = await pipeline.registeredCommandTypes
        XCTAssertFalse(hasHandler)
        XCTAssertTrue(clearedTypes.isEmpty)
        try await assertMissingHandler(pipeline)
        try await pipeline.registerOnce(RoutingCommand.self, handler: RoutingHandler(label: "C"))
        try await assertLaterSelections(pipeline, equal: "C", scenario: "registerOnce inserts missing")
    }

    func testRegistryPreservesOverwriteInsertionAndRemovalPolicies() async throws {
        let registry = HandlerRegistry()
        let replacedAbsent = await registry.replace(RoutingCommand.self, with: RoutingHandler(label: "A"))
        XCTAssertFalse(replacedAbsent)
        let duplicate = await registry.insertIfAbsent(RoutingCommand.self, handler: RoutingHandler(label: "duplicate"))
        XCTAssertFalse(duplicate)
        let original = await registry.handler(for: RoutingCommand.self) as? AnyCommandHandler<RoutingCommand>
        let originalValue = try await XCTUnwrap(original).handle(RoutingCommand(), context: CommandContext())
        XCTAssertEqual(originalValue, "A")

        await registry.register(RoutingCommand.self, handler: RoutingHandler(label: "B"))
        let replaced = await registry.replace(RoutingCommand.self, with: RoutingHandler(label: "C"))
        XCTAssertTrue(replaced)
        let insertedOther = await registry.insertIfAbsent(OtherRoutingCommand.self, handler: OtherRoutingHandler())
        XCTAssertTrue(insertedOther)
        let count = await registry.count
        XCTAssertEqual(count, 2)

        let removed = await registry.removeHandler(for: RoutingCommand.self) as? AnyCommandHandler<RoutingCommand>
        let removedValue = try await XCTUnwrap(removed).handle(RoutingCommand(), context: CommandContext())
        XCTAssertEqual(removedValue, "C")
        let missing = await registry.handler(for: RoutingCommand.self)
        let removedAgain = await registry.removeHandler(for: RoutingCommand.self)
        XCTAssertNil(missing)
        XCTAssertNil(removedAgain)
        let hasOther = await registry.hasHandler(for: OtherRoutingCommand.self)
        XCTAssertTrue(hasOther)

        await registry.removeAllHandlers()
        let emptyCount = await registry.count
        let emptyTypes = await registry.registeredCommandTypes
        let removedOther = await registry.hasHandler(for: OtherRoutingCommand.self)
        XCTAssertEqual(emptyCount, 0)
        XCTAssertTrue(emptyTypes.isEmpty)
        XCTAssertFalse(removedOther)
    }

    private func assertLaterSelections(_ pipeline: DynamicPipeline, equal expected: String, scenario: String) async throws {
        // Join each batch before returning to the caller, which may still hold an older send.
        for _ in 0..<2 {
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<3 {
                    group.addTask { try await pipeline.send(RoutingCommand(), retryPolicy: .none) }
                }
                for try await result in group {
                    XCTAssertEqual(result, expected, scenario)
                }
            }
        }
    }

    private func assertMissingHandler(_ pipeline: DynamicPipeline) async throws {
        do {
            _ = try await pipeline.send(RoutingCommand(), retryPolicy: .none)
            XCTFail("Expected handlerNotFound")
        } catch let error as PipelineError {
            guard case .handlerNotFound = error else {
                return XCTFail("Expected handlerNotFound, got \(error)")
            }
        }
    }

    private func withHeldSend(
        _ pipeline: DynamicPipeline,
        gate: HandlerSelectionGate,
        expected: String,
        operation: () async throws -> Void
    ) async throws {
        let held = Task { @concurrent in
            let result: Result<String, any Error>
            do {
                result = .success(try await pipeline.send(RoutingCommand(hold: true), retryPolicy: .none))
            } catch {
                result = .failure(error)
            }
            await gate.markSettled()
            return result
        }
        let entered = await gate.waitForEntryOrSettlement()
        XCTAssertTrue(entered, "Old handler must acknowledge selection before mutation")
        do {
            if entered { try await operation() }
        } catch {
            await gate.release()
            _ = await held.value
            throw error
        }
        await gate.release()
        let result = await held.value
        XCTAssertEqual(try result.get(), expected)
        let settled = await gate.isFullySettled
        XCTAssertTrue(settled)
    }
}

private enum HandlerMutation: CaseIterable {
    case replace, overwrite, removeThenRegister, clearThenRegister
}

private enum MiddlewareMutation {
    case add, addMultiple, clear
}

private struct RoutingCommand: Command {
    typealias Result = String
    var hold = false
}

private struct OtherRoutingCommand: Command {
    typealias Result = Int
}

private struct RoutingHandler: CommandHandler {
    let label: String
    var gate: HandlerSelectionGate?

    func handle(_ command: RoutingCommand, context: CommandContext) async throws -> String {
        if command.hold, let gate { await gate.enterAndWait() }
        return label
    }
}

private struct OtherRoutingHandler: CommandHandler {
    func handle(_ command: OtherRoutingCommand, context: CommandContext) async throws -> Int { 42 }
}

private struct RoutingSuffix: Middleware {
    let suffix: String
    let priority: ExecutionPriority = .custom

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let result = try await next(command, context)
        if let value = result as? String, let transformed = (value + suffix) as? T.Result {
            return transformed
        }
        return result
    }
}

// This gate runs inside the selected handler, after chain publication. It verifies
// in-flight snapshot behavior, not the old cross-actor lookup/publication schedule.
private actor HandlerSelectionGate {
    private var entered = false
    private var released = false
    private var releaseObserved = false
    private var settled = false
    private var entryWaiter: CheckedContinuation<Bool, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        entryWaiter?.resume(returning: true)
        entryWaiter = nil
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        releaseObserved = true
    }

    func waitForEntryOrSettlement() async -> Bool {
        if entered { return true }
        if settled { return false }
        return await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func markSettled() {
        settled = true
        entryWaiter?.resume(returning: false)
        entryWaiter = nil
    }

    var isFullySettled: Bool {
        entered && released && releaseObserved && settled && entryWaiter == nil && releaseWaiter == nil
    }
}
