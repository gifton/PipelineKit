//
//  PipelineRegistryTests.swift
//  PipelineKit
//
//  Tests for PipelineRegistry and PipelineKey.
//

import XCTest
@testable import PipelineKit
@testable import PipelineKitCore
import PipelineKitTestSupport

// MARK: - Test Commands and Handlers

struct RegistryTestCommand: Command {
    typealias Result = String
    let value: String

    func execute() async throws -> String { value }
}

struct AnotherRegistryCommand: Command {
    typealias Result = Int
    let value: Int

    func execute() async throws -> Int { value }
}

final class RegistryTestHandler: CommandHandler {
    typealias CommandType = RegistryTestCommand

    func handle(_ command: RegistryTestCommand) async throws -> String {
        command.value
    }
}

final class AnotherRegistryHandler: CommandHandler {
    typealias CommandType = AnotherRegistryCommand

    func handle(_ command: AnotherRegistryCommand) async throws -> Int {
        command.value
    }
}

// MARK: - PipelineKey Tests

final class PipelineKeyTests: XCTestCase {

    func testDefaultKeyHasDefaultName() {
        let key = PipelineKey<RegistryTestCommand>.default
        XCTAssertEqual(key.name, "default")
    }

    func testCustomKeyHasCustomName() {
        let key = PipelineKey<RegistryTestCommand>("custom")
        XCTAssertEqual(key.name, "custom")
    }

    func testKeysWithSameNameAreEqual() {
        let key1 = PipelineKey<RegistryTestCommand>("test")
        let key2 = PipelineKey<RegistryTestCommand>("test")
        XCTAssertEqual(key1, key2)
    }

    func testKeysWithDifferentNamesAreNotEqual() {
        let key1 = PipelineKey<RegistryTestCommand>("test1")
        let key2 = PipelineKey<RegistryTestCommand>("test2")
        XCTAssertNotEqual(key1, key2)
    }

    func testKeyHashable() {
        var set: Set<PipelineKey<RegistryTestCommand>> = []
        set.insert(PipelineKey("one"))
        set.insert(PipelineKey("two"))
        set.insert(PipelineKey("one")) // Duplicate

        XCTAssertEqual(set.count, 2)
    }

    func testKeyDescription() {
        let key = PipelineKey<RegistryTestCommand>("myKey")
        XCTAssertTrue(key.description.contains("myKey"))
        XCTAssertTrue(key.description.contains("RegistryTestCommand"))
    }
}

// MARK: - PipelineRegistry Tests

final class PipelineRegistryTests: XCTestCase {

    var registry: PipelineRegistry!

    override func setUp() async throws {
        try await super.setUp()
        registry = PipelineRegistry()
    }

    override func tearDown() async throws {
        registry = nil
        try await super.tearDown()
    }

    // MARK: - Registration Tests

    func testRegisterPipelineForCommandType() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())

        await registry.register(pipeline, for: RegistryTestCommand.self)

        let retrieved = await registry.pipeline(for: RegistryTestCommand.self)
        XCTAssertNotNil(retrieved)
    }

    func testRegisterPipelineWithName() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())

        await registry.register(pipeline, for: RegistryTestCommand.self, named: "custom")

        let retrieved = await registry.pipeline(for: RegistryTestCommand.self, named: "custom")
        XCTAssertNotNil(retrieved)
    }

    func testRegisterPipelineWithPipelineKey() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        let key = PipelineKey<RegistryTestCommand>("typed")

        await registry.register(pipeline, for: key)

        let retrieved = await registry.pipeline(for: key)
        XCTAssertNotNil(retrieved)
    }

    func testRegisterMultiplePipelinesForSameCommandType() async {
        let pipeline1 = StandardPipeline(handler: RegistryTestHandler())
        let pipeline2 = StandardPipeline(handler: RegistryTestHandler())

        await registry.register(pipeline1, for: RegistryTestCommand.self, named: "first")
        await registry.register(pipeline2, for: RegistryTestCommand.self, named: "second")

        let names = await registry.pipelineNames(for: RegistryTestCommand.self)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains("first"))
        XCTAssertTrue(names.contains("second"))
    }

    func testRegisterOverwritesPrevious() async {
        let pipeline1 = StandardPipeline(handler: RegistryTestHandler())
        let pipeline2 = StandardPipeline(handler: RegistryTestHandler())

        await registry.register(pipeline1, for: RegistryTestCommand.self)
        await registry.register(pipeline2, for: RegistryTestCommand.self)

        let count = await registry.count
        XCTAssertEqual(count, 1) // Should have overwritten
    }

    // MARK: - Retrieval Tests

    func testRetrieveDefaultPipeline() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        await registry.register(pipeline, for: RegistryTestCommand.self)

        let retrieved = await registry.pipeline(for: RegistryTestCommand.self)
        XCTAssertNotNil(retrieved)
    }

    func testRetrieveNamedPipeline() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        await registry.register(pipeline, for: RegistryTestCommand.self, named: "special")

        let retrieved = await registry.pipeline(for: RegistryTestCommand.self, named: "special")
        XCTAssertNotNil(retrieved)

        // Default should not exist
        let defaultPipeline = await registry.pipeline(for: RegistryTestCommand.self)
        XCTAssertNil(defaultPipeline)
    }

    func testRetrieveWithPipelineKey() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        let key = PipelineKey<RegistryTestCommand>("keyed")
        await registry.register(pipeline, for: key)

        let retrieved = await registry.pipeline(for: key)
        XCTAssertNotNil(retrieved)
    }

    func testRetrieveAllPipelinesForType() async {
        let pipeline1 = StandardPipeline(handler: RegistryTestHandler())
        let pipeline2 = StandardPipeline(handler: RegistryTestHandler())

        await registry.register(pipeline1, for: RegistryTestCommand.self, named: "a")
        await registry.register(pipeline2, for: RegistryTestCommand.self, named: "b")

        let pipelines = await registry.pipelines(for: RegistryTestCommand.self)
        XCTAssertEqual(pipelines.count, 2)
    }

    func testRetrieveNonExistentReturnsNil() async {
        let retrieved = await registry.pipeline(for: RegistryTestCommand.self)
        XCTAssertNil(retrieved)
    }

    // MARK: - Execution Tests

    func testExecuteThroughRegistry() async throws {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        await registry.register(pipeline, for: RegistryTestCommand.self)

        let result = try await registry.execute(RegistryTestCommand(value: "hello"))
        XCTAssertEqual(result, "hello")
    }

    func testExecuteWithNamedPipeline() async throws {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        await registry.register(pipeline, for: RegistryTestCommand.self, named: "worker")

        let result = try await registry.execute(
            RegistryTestCommand(value: "world"),
            using: "worker"
        )
        XCTAssertEqual(result, "world")
    }

    func testExecuteWithPipelineKey() async throws {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        let key = PipelineKey<RegistryTestCommand>("executor")
        await registry.register(pipeline, for: key)

        let result = try await registry.execute(
            RegistryTestCommand(value: "keyed"),
            using: key
        )
        XCTAssertEqual(result, "keyed")
    }

    func testExecuteMissingPipelineThrows() async {
        do {
            _ = try await registry.execute(RegistryTestCommand(value: "test"))
            XCTFail("Expected error to be thrown")
        } catch {
            // Expected
            XCTAssertTrue(error is PipelineError)
        }
    }

    // MARK: - Removal Tests

    func testRemoveDefaultPipeline() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        await registry.register(pipeline, for: RegistryTestCommand.self)

        let removed = await registry.remove(for: RegistryTestCommand.self)
        XCTAssertNotNil(removed)

        let remaining = await registry.pipeline(for: RegistryTestCommand.self)
        XCTAssertNil(remaining)
    }

    func testRemoveNamedPipeline() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        let key = PipelineKey<RegistryTestCommand>("toRemove")
        await registry.register(pipeline, for: key)

        let removed = await registry.remove(for: key)
        XCTAssertNotNil(removed)

        let remaining = await registry.pipeline(for: key)
        XCTAssertNil(remaining)
    }

    func testRemoveAllForCommandType() async {
        let pipeline1 = StandardPipeline(handler: RegistryTestHandler())
        let pipeline2 = StandardPipeline(handler: RegistryTestHandler())

        await registry.register(pipeline1, for: RegistryTestCommand.self, named: "one")
        await registry.register(pipeline2, for: RegistryTestCommand.self, named: "two")

        let removed = await registry.removeAll(for: RegistryTestCommand.self)
        XCTAssertEqual(removed.count, 2)

        let remaining = await registry.pipelines(for: RegistryTestCommand.self)
        XCTAssertEqual(remaining.count, 0)
    }

    func testRemoveAll() async {
        let pipeline1 = StandardPipeline(handler: RegistryTestHandler())
        let pipeline2 = StandardPipeline(handler: AnotherRegistryHandler())

        await registry.register(pipeline1, for: RegistryTestCommand.self)
        await registry.register(pipeline2, for: AnotherRegistryCommand.self)

        await registry.removeAll()

        let count = await registry.count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Introspection Tests

    func testContainsKey() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        let key = PipelineKey<RegistryTestCommand>("check")
        await registry.register(pipeline, for: key)

        let contains = await registry.contains(key)
        XCTAssertTrue(contains)

        let notContains = await registry.contains(PipelineKey<RegistryTestCommand>("other"))
        XCTAssertFalse(notContains)
    }

    func testContainsCommandType() async {
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        await registry.register(pipeline, for: RegistryTestCommand.self)

        let contains = await registry.contains(RegistryTestCommand.self)
        XCTAssertTrue(contains)

        let notContains = await registry.contains(AnotherRegistryCommand.self)
        XCTAssertFalse(notContains)
    }

    func testCount() async {
        let pipeline1 = StandardPipeline(handler: RegistryTestHandler())
        let pipeline2 = StandardPipeline(handler: AnotherRegistryHandler())

        await registry.register(pipeline1, for: RegistryTestCommand.self)
        await registry.register(pipeline2, for: AnotherRegistryCommand.self)

        let count = await registry.count
        XCTAssertEqual(count, 2)
    }

    func testCommandTypeCount() async {
        let pipeline1 = StandardPipeline(handler: RegistryTestHandler())
        let pipeline2 = StandardPipeline(handler: RegistryTestHandler())
        let pipeline3 = StandardPipeline(handler: AnotherRegistryHandler())

        await registry.register(pipeline1, for: RegistryTestCommand.self, named: "one")
        await registry.register(pipeline2, for: RegistryTestCommand.self, named: "two")
        await registry.register(pipeline3, for: AnotherRegistryCommand.self)

        let typeCount = await registry.commandTypeCount
        XCTAssertEqual(typeCount, 2) // Two different command types
    }

    func testStats() async {
        let pipeline1 = StandardPipeline(handler: RegistryTestHandler())
        let pipeline2 = StandardPipeline(handler: RegistryTestHandler())

        await registry.register(pipeline1, for: RegistryTestCommand.self, named: "a")
        await registry.register(pipeline2, for: RegistryTestCommand.self, named: "b")

        let stats = await registry.stats()
        XCTAssertEqual(stats.pipelineCount, 2)
        XCTAssertEqual(stats.commandTypeCount, 1)
        XCTAssertTrue(stats.pipelinesByType.keys.contains("RegistryTestCommand"))
    }

    func testIsEmpty() async {
        var isEmpty = await registry.isEmpty
        XCTAssertTrue(isEmpty)

        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        await registry.register(pipeline, for: RegistryTestCommand.self)

        isEmpty = await registry.isEmpty
        XCTAssertFalse(isEmpty)
    }

    // MARK: - Concurrency Tests

    func testConcurrentRegistration() async {
        let registry = self.registry!

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let pipeline = StandardPipeline(handler: RegistryTestHandler())
                    await registry.register(
                        pipeline,
                        for: RegistryTestCommand.self,
                        named: "pipeline-\(i)"
                    )
                }
            }
        }

        let count = await registry.count
        XCTAssertEqual(count, 10)
    }

    func testConcurrentRetrieval() async {
        let registry = self.registry!
        let pipeline = StandardPipeline(handler: RegistryTestHandler())
        await registry.register(pipeline, for: RegistryTestCommand.self)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let p = await registry.pipeline(for: RegistryTestCommand.self)
                    return p != nil
                }
            }

            for await result in group {
                XCTAssertTrue(result)
            }
        }
    }
}
