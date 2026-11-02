import Foundation
import XCTest
import PipelineKit
@testable import PipelineKitSecurity

final class SecurityPolicySizeTests: XCTestCase {
    func testEquivalentStringPayloadCannotBypassLimitThroughArrays() async throws {
        try await assertBoundary(PayloadCommand(payload: "abcdefgh"), bytes: 8)
        try await assertBoundary(PayloadCommand(payload: ["abcd", "efgh"]), bytes: 8)
        try await assertBoundary(PayloadCommand(payload: [["ab", "cd"], ["ef", "gh"]]), bytes: 8)
        try await assertBoundary(PayloadCommand(payload: [Envelope(value: "abcd"), Envelope(value: "efgh")]), bytes: 8)
    }

    func testSupportedLeavesHaveSameSizeInEveryContainerShape() async throws {
        let scalarBytes = MemoryLayout<Any>.size
        try await assertLeafShapes("é😀", bytes: 6)
        try await assertLeafShapes(Data([0, 1, 2, 3, 4]), bytes: 5)
        try await assertLeafShapes(Int(1), bytes: scalarBytes)
        try await assertLeafShapes(Int8(1), bytes: scalarBytes)
        try await assertLeafShapes(Int16(1), bytes: scalarBytes)
        try await assertLeafShapes(Int32(1), bytes: scalarBytes)
        try await assertLeafShapes(Int64(1), bytes: scalarBytes)
        try await assertLeafShapes(UInt(1), bytes: scalarBytes)
        try await assertLeafShapes(UInt8(1), bytes: scalarBytes)
        try await assertLeafShapes(UInt16(1), bytes: scalarBytes)
        try await assertLeafShapes(UInt32(1), bytes: scalarBytes)
        try await assertLeafShapes(UInt64(1), bytes: scalarBytes)
        try await assertLeafShapes(Float(1), bytes: scalarBytes)
        try await assertLeafShapes(Double(1), bytes: scalarBytes)
        try await assertLeafShapes(true, bytes: scalarBytes)
        try await assertLeafShapes(UUID(), bytes: scalarBytes)
        try await assertLeafShapes(Date(timeIntervalSince1970: 0), bytes: scalarBytes)
    }

    func testMixedNestedPayloadCountsEachLeafOnce() async throws {
        let payload = MixedPayload(
            text: "é😀", data: Data([0, 1, 2]), numbers: [7, 8],
            nested: Envelope(value: ["ab", "c"]), optional: "xyz"
        )
        // 6 UTF-8 bytes + 3 data bytes + two scalar charges + 3 + 3.
        try await assertBoundary(PayloadCommand(payload: payload), bytes: 15 + 2 * MemoryLayout<Any>.size)
    }

    func testEmptyAndAbsentPayloadsFitZeroLimit() async throws {
        try await assertAccepted(PayloadCommand(payload: ""), maxSize: 0)
        try await assertAccepted(PayloadCommand(payload: Data()), maxSize: 0)
        try await assertAccepted(PayloadCommand(payload: [Int]()), maxSize: 0)
        try await assertAccepted(PayloadCommand(payload: ["", ""]), maxSize: 0)
        try await assertAccepted(PayloadCommand(payload: Optional<String>.none), maxSize: 0)
        try await assertAccepted(PayloadCommand(payload: [Optional<Int>.none]), maxSize: 0)
        try await assertAccepted(PayloadCommand(payload: Optional<Optional<Data>>.some(nil)), maxSize: 0)
    }

    func testDeeplyNestedOptionalContainersRetainTheirLeafSize() async throws {
        var present = NestedPayload.value("é😀")
        var absent = NestedPayload.value(nil)
        defer {
            dismantle(&present)
            dismantle(&absent)
        }
        for _ in 0..<128 {
            present = .container([present])
            absent = .container([absent])
        }
        try await assertBoundary(PayloadCommand(payload: present), bytes: 6)
        try await assertAccepted(PayloadCommand(payload: absent), maxSize: 0)
    }

    func testDeepAcyclicReferencesRetainTheirLeafSizes() async throws {
        let nodes = (0..<1_024).map { _ in CycleNode(text: "x") }
        for index in 0..<(nodes.count - 1) {
            nodes[index].next = nodes[index + 1]
        }
        defer { for node in nodes { node.next = nil } }
        try await assertBoundary(PayloadCommand(payload: nodes[0]), bytes: 1_024)
    }

    func testInheritedStoredPropertiesContributeSize() async throws {
        try await assertBoundary(BaseCommand(text: "abc"), bytes: 3)
        let command = DerivedCommand(text: "abc", suffix: "defg")
        try await assertBoundary(command, bytes: 7)
        try await assertBoundary(PayloadCommand(payload: [command, command]), bytes: 14)
    }

    func testInheritedStringPropertiesAreValidated() async {
        let restricted = SecurityPolicy(
            maxCommandSize: Int.max, allowHTML: true, strictValidation: true,
            maxStringLength: 2, allowedCharacters: CharacterSet().inverted
        )
        let middleware = SecurityPolicyMiddleware(policy: restricted)
        do {
            _ = try await middleware.execute(DerivedCommand(text: "abcd", suffix: ""), context: CommandContext()) { _, _ in
                XCTFail("An invalid inherited string reached the handler")
                return 1
            }
            XCTFail("Expected inherited string validation")
        } catch PipelineError.securityPolicy(reason: .stringTooLong(let field, let length, let limit)) {
            XCTAssertEqual(field, "text")
            XCTAssertEqual(length, 4)
            XCTAssertEqual(limit, 2)
        } catch {
            XCTFail("Unexpected rejection: \(error)")
        }
    }

    func testSizeRejectionStopsBeforeLaterPayloadReflection() async throws {
        let command = PayloadCommand(payload: OversizedThenUnvisited(oversized: ["abcd"], tail: UnvisitedPayload()))
        await assertRejected(command, maxSize: 3, reportedSize: 4)
    }

    func testExtremePolicyLimitsDoNotWrap() async throws {
        await assertRejected(PayloadCommand(payload: ""), maxSize: Int.min, reportedSize: 0)
        try await assertAccepted(PayloadCommand(payload: ["é😀"]), maxSize: Int.max)
    }

    func testBudgetRejectsOverflowEvenWhenLimitIsIntMax() throws {
        var budget = SecurityCommandSizeBudget(limit: Int.max)
        try budget.add(Int.max - 1)
        try budget.add(1)
        XCTAssertEqual(budget.size, Int.max)
        XCTAssertThrowsError(try budget.add(1)) { error in
            guard case PipelineError.securityPolicy(reason: .commandTooLarge(let size, let limit)) = error else {
                return XCTFail("Unexpected rejection: \(error)")
            }
            XCTAssertEqual(size, Int.max)
            XCTAssertEqual(limit, Int.max)
        }
    }

    func testRepeatedReferenceOccurrencesEachContributeSize() async throws {
        let shared = SharedPayload(text: "abcd")
        try await assertBoundary(PayloadCommand(payload: [shared, shared]), bytes: 8)
        try await assertBoundary(PayloadCommand(payload: Envelope(value: [shared, shared])), bytes: 8)
    }

    func testDirectAndIndirectReferenceCyclesRejectBeforeHandler() async {
        for indirect in [false, true] {
            let root = CycleNode(text: "root")
            let child = indirect ? CycleNode(text: "child") : root
            root.next = child
            child.next = root
            await assertCycleRejected(PayloadCommand(payload: root))
            root.next = nil
            child.next = nil
        }
    }

    func testInheritedReferenceCycleRejectsBeforeHandler() async {
        let node = DerivedCycleNode(text: "")
        node.next = node
        defer { node.next = nil }
        await assertCycleRejected(PayloadCommand(payload: node))
    }

    func testStringValidationAlsoRejectsAReferenceCycle() async {
        // This fixture exposes its cycle only after the size pass has completed.
        await assertCycleRejected(PayloadCommand(payload: DeferredCycle()))
    }

    func testCustomValidatorCanAcceptCyclicContent() async throws {
        let node = CycleNode(text: "oversized")
        node.next = node
        defer { node.next = nil }
        try await assertAccepted(CustomCycleCommand(payload: node), maxSize: 0)
    }

    func testCustomValidatorTakesPrecedenceOverReflectedSize() async throws {
        let command = CustomCommand(payload: String(repeating: "a", count: 100), rejection: nil)
        try await assertAccepted(command, maxSize: 0)
    }

    func testCustomValidatorErrorIsPreservedRegardlessOfStrictMode() async throws {
        let failure = CustomRejection()
        for strict in [true, false] {
            let middleware = SecurityPolicyMiddleware(policy: policy(maxSize: 0, strict: strict))
            do {
                _ = try await middleware.execute(CustomCommand(payload: "oversized", rejection: failure), context: CommandContext()) { _, _ in
                    XCTFail("A rejected custom validation must not reach the handler")
                    return 1
                }
                XCTFail("Expected the custom rejection")
            } catch {
                XCTAssertTrue((error as? CustomRejection) === failure)
            }
        }
    }

    func testNonStrictPolicySkipsReflection() async throws {
        let middleware = SecurityPolicyMiddleware(policy: policy(maxSize: 0, strict: false))
        let result = try await middleware.execute(PayloadCommand(payload: ["oversized"]), context: CommandContext()) { _, _ in 1 }
        XCTAssertEqual(result, 1)
    }
}

private extension SecurityPolicySizeTests {
    struct PayloadCommand<Payload: Sendable>: Command {
        typealias Result = Int
        let payload: Payload
    }

    struct Envelope<Value: Sendable>: Sendable {
        let value: Value
    }

    indirect enum NestedPayload: Sendable {
        case value(String?)
        case container([NestedPayload?])
    }

    func dismantle(_ payload: inout NestedPayload) {
        while case .container(let children) = payload, let child = children.first ?? nil {
            payload = child
        }
    }

    struct MixedPayload: Sendable {
        let text: String
        let data: Data
        let numbers: [Int]
        let nested: Envelope<[String]>
        let optional: String?
    }

    struct OversizedThenUnvisited: Sendable {
        let oversized: [String]
        let tail: UnvisitedPayload
    }

    struct UnvisitedPayload: Sendable, CustomReflectable {
        var customMirror: Mirror {
            XCTFail("Size rejection must stop before reflecting later fields")
            return Mirror(self, children: [:])
        }
    }

    final class CustomRejection: Error, Sendable {}

    final class SharedPayload: Sendable {
        let text: String
        init(text: String) { self.text = text }
    }

    // These command fixtures have only immutable stored properties.
    class BaseCommand: Command, @unchecked Sendable {
        typealias Result = Int
        let text: String
        init(text: String) { self.text = text }
    }

    final class DerivedCommand: BaseCommand, @unchecked Sendable {
        let suffix: String
        init(text: String, suffix: String) {
            self.suffix = suffix
            super.init(text: text)
        }
    }

    // testDirectAndIndirectReferenceCyclesRejectBeforeHandler and
    // testCustomValidatorCanAcceptCyclicContent configure and clear links around
    // the awaited execute call; no other task receives these test nodes.
    class CycleNode: @unchecked Sendable {
        let text: String
        var next: CycleNode?
        init(text: String) { self.text = text }
    }

    final class DerivedCycleNode: CycleNode, @unchecked Sendable {}

    final class DeferredCycle: @unchecked Sendable, CustomReflectable {
        private let lock = NSLock()
        // Every access to reflectionCount is protected by lock in customMirror.
        private var reflectionCount = 0

        var customMirror: Mirror {
            lock.lock()
            defer { lock.unlock() }
            reflectionCount += 1
            // Bound the fixture's recursive exposure so a missing cycle guard
            // fails an assertion instead of exhausting the test runner's stack.
            if reflectionCount == 1 || reflectionCount > 4 {
                return Mirror(self, children: [:], displayStyle: .class)
            }
            return Mirror(self, children: ["cycle": self], displayStyle: .class)
        }
    }

    struct CustomCycleCommand: Command, SecurityValidatable {
        typealias Result = Int
        let payload: CycleNode
        func validate(against policy: SecurityPolicy) throws {}
    }

    struct CustomCommand: Command, SecurityValidatable {
        typealias Result = Int
        let payload: String
        let rejection: CustomRejection?

        func validate(against policy: SecurityPolicy) throws {
            XCTAssertEqual(policy.maxCommandSize, 0)
            if let rejection { throw rejection }
        }
    }

    func policy(maxSize: Int, strict: Bool = true) -> SecurityPolicy {
        SecurityPolicy(
            maxCommandSize: maxSize,
            allowHTML: true,
            strictValidation: strict,
            maxStringLength: Int.max,
            allowedCharacters: CharacterSet().inverted
        )
    }

    func assertLeafShapes<Value: Sendable>(
        _ value: Value, bytes: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await assertBoundary(PayloadCommand(payload: value), bytes: bytes, file: file, line: line)
        try await assertBoundary(PayloadCommand(payload: [value]), bytes: bytes, file: file, line: line)
        try await assertBoundary(PayloadCommand(payload: [[value]]), bytes: bytes, file: file, line: line)
        try await assertBoundary(PayloadCommand(payload: Envelope(value: value)), bytes: bytes, file: file, line: line)
        try await assertBoundary(PayloadCommand(payload: Optional.some(value)), bytes: bytes, file: file, line: line)
        try await assertBoundary(PayloadCommand(payload: [Optional.some(value)]), bytes: bytes, file: file, line: line)
        try await assertBoundary(PayloadCommand(payload: Optional.some([value])), bytes: bytes, file: file, line: line)
    }

    func assertBoundary<C: Command>(
        _ command: C, bytes: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws where C.Result == Int {
        try await assertAccepted(command, maxSize: bytes, file: file, line: line)
        await assertRejected(command, maxSize: bytes - 1, reportedSize: bytes, file: file, line: line)
    }

    func assertAccepted<C: Command>(
        _ command: C, maxSize: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws where C.Result == Int {
        let middleware = SecurityPolicyMiddleware(policy: policy(maxSize: maxSize))
        let result = try await middleware.execute(command, context: CommandContext()) { _, _ in 1 }
        XCTAssertEqual(result, 1, file: file, line: line)
    }

    func assertRejected<C: Command>(
        _ command: C, maxSize: Int, reportedSize: Int, file: StaticString = #filePath, line: UInt = #line
    ) async where C.Result == Int {
        let middleware = SecurityPolicyMiddleware(policy: policy(maxSize: maxSize))
        do {
            _ = try await middleware.execute(command, context: CommandContext()) { _, _ in
                XCTFail("Oversized content reached the handler", file: file, line: line)
                return 1
            }
            XCTFail("Expected commandTooLarge", file: file, line: line)
        } catch PipelineError.securityPolicy(reason: .commandTooLarge(let size, let limit)) {
            XCTAssertEqual(size, reportedSize, file: file, line: line)
            XCTAssertEqual(limit, maxSize, file: file, line: line)
        } catch {
            XCTFail("Unexpected rejection: \(error)", file: file, line: line)
        }
    }

    func assertCycleRejected<C: Command>(
        _ command: C, file: StaticString = #filePath, line: UInt = #line
    ) async where C.Result == Int {
        let middleware = SecurityPolicyMiddleware(policy: policy(maxSize: Int.max))
        do {
            _ = try await middleware.execute(command, context: CommandContext()) { _, _ in
                XCTFail("Cyclic content reached the handler", file: file, line: line)
                return 1
            }
            XCTFail("Expected a reference cycle rejection", file: file, line: line)
        } catch PipelineError.securityPolicy(reason: .validationFailed(let reason)) {
            XCTAssertTrue(reason.contains("cycle"), reason, file: file, line: line)
        } catch {
            XCTFail("Unexpected rejection: \(error)", file: file, line: line)
        }
    }
}
