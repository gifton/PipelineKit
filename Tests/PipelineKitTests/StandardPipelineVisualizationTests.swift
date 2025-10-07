//
//  StandardPipelineVisualizationTests.swift
//  PipelineKitTests
//
//  Tests for pipeline visualization and introspection
//

import XCTest
@testable import PipelineKit
@testable import PipelineKitCore

final class StandardPipelineVisualizationTests: XCTestCase {
    // MARK: - describe() Tests

    func testDescribeEmptyPipeline() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())

        let description = await pipeline.describe()

        XCTAssertEqual(description.middlewares.count, 0)
        XCTAssertTrue(description.handlerType.contains("TestHandler"))
        XCTAssertTrue(description.commandType.contains("TestCommand"))
    }

    func testDescribePipelineWithSingleMiddleware() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(TestMiddleware(priority: .validation))

        let description = await pipeline.describe()

        XCTAssertEqual(description.middlewares.count, 1)
        XCTAssertEqual(description.middlewares[0].priority, ExecutionPriority.validation.rawValue)
        XCTAssertTrue(description.middlewares[0].name.contains("TestMiddleware"))
    }

    func testDescribePipelineWithMultipleMiddleware() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())

        // Add middleware in random order
        try await pipeline.addMiddleware(TestMiddleware(priority: .preProcessing))
        try await pipeline.addMiddleware(TestMiddleware(priority: .authentication))
        try await pipeline.addMiddleware(TestMiddleware(priority: .validation))

        let description = await pipeline.describe()

        XCTAssertEqual(description.middlewares.count, 3)

        // Middleware should be in priority order (authentication > validation > preProcessing)
        XCTAssertEqual(description.middlewares[0].priority, ExecutionPriority.authentication.rawValue)
        XCTAssertEqual(description.middlewares[1].priority, ExecutionPriority.validation.rawValue)
        XCTAssertEqual(description.middlewares[2].priority, ExecutionPriority.preProcessing.rawValue)
    }

    func testDescribeIncludesFullTypeInformation() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(TestMiddleware(priority: .custom))

        let description = await pipeline.describe()

        XCTAssertEqual(description.middlewares.count, 1)
        let middleware = description.middlewares[0]

        // Should have both short name and full type
        XCTAssertFalse(middleware.name.isEmpty)
        XCTAssertFalse(middleware.fullType.isEmpty)
        XCTAssertTrue(middleware.fullType.contains("TestMiddleware"))
    }

    // MARK: - visualize() Tests

    func testVisualizeEmptyPipeline() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())

        // Should not crash - just outputs to console
        await pipeline.visualize()

        // Manual verification: check console output shows empty pipeline
    }

    func testVisualizePipelineWithMiddleware() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(TestMiddleware(priority: .authentication))
        try await pipeline.addMiddleware(TestMiddleware(priority: .validation))

        // Should not crash and show formatted output
        await pipeline.visualize()

        // Manual verification: check console output shows 2 middleware in tree format
    }

    func testVisualizeWithColors() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(TestMiddleware(priority: .authentication))
        try await pipeline.addMiddleware(TestMiddleware(priority: .validation))

        // Default options (with colors)
        await pipeline.visualize(options: .default)

        // Manual verification: check console shows colored output
    }

    func testVisualizeMinimal() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(TestMiddleware(priority: .authentication))

        // Minimal options (no colors, no emojis)
        await pipeline.visualize(options: .minimal)

        // Manual verification: check console shows plain text
    }

    func testVisualizeCustomOptions() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(TestMiddleware(priority: .authentication))
        try await pipeline.addMiddleware(TestMiddleware(priority: .validation))

        // Custom options
        let options = VisualizationOptions(
            useColors: true,
            useEmojis: true,
            showExecutionOrder: true,
            showSummary: true
        )
        await pipeline.visualize(options: options)

        // Manual verification: check all features enabled
    }

    // MARK: - Integration Tests

    func testVisualizationWithRealMiddleware() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())

        // Add multiple middleware with different priorities
        try await pipeline.addMiddleware(TestMiddleware(priority: .authentication))
        try await pipeline.addMiddleware(TestMiddleware(priority: .validation))
        try await pipeline.addMiddleware(TestMiddleware(priority: .preProcessing))
        try await pipeline.addMiddleware(TestMiddleware(priority: .postProcessing))

        let description = await pipeline.describe()

        // Verify middleware are sorted by priority (lower values execute first)
        XCTAssertEqual(description.middlewares.count, 4)

        // Authentication (100) should be first
        XCTAssertEqual(description.middlewares[0].priority, ExecutionPriority.authentication.rawValue)

        // Validation (200) should be second
        XCTAssertEqual(description.middlewares[1].priority, ExecutionPriority.validation.rawValue)

        // PreProcessing (300) should be third
        XCTAssertEqual(description.middlewares[2].priority, ExecutionPriority.preProcessing.rawValue)

        // PostProcessing (500) should be last
        XCTAssertEqual(description.middlewares[3].priority, ExecutionPriority.postProcessing.rawValue)
    }

    func testDescribeAfterMiddlewareChanges() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())

        // Initial state
        var description = await pipeline.describe()
        XCTAssertEqual(description.middlewares.count, 0)

        // Add middleware
        try await pipeline.addMiddleware(TestMiddleware(priority: .validation))
        description = await pipeline.describe()
        XCTAssertEqual(description.middlewares.count, 1)

        // Add more middleware
        try await pipeline.addMiddleware(TestMiddleware(priority: .authentication))
        description = await pipeline.describe()
        XCTAssertEqual(description.middlewares.count, 2)

        // Clear middleware
        await pipeline.clearMiddlewares()
        description = await pipeline.describe()
        XCTAssertEqual(description.middlewares.count, 0)
    }

    // MARK: - PipelineDescription Tests

    func testPipelineDescriptionIsEquatable() {
        let desc1 = PipelineDescription(
            middlewares: [
                MiddlewareInfo(name: "Test", priority: 100, fullType: "Test.TestMiddleware")
            ],
            handlerType: "TestHandler",
            commandType: "TestCommand"
        )

        let desc2 = PipelineDescription(
            middlewares: [
                MiddlewareInfo(name: "Test", priority: 100, fullType: "Test.TestMiddleware")
            ],
            handlerType: "TestHandler",
            commandType: "TestCommand"
        )

        // Should have same values
        XCTAssertEqual(desc1.middlewares.count, desc2.middlewares.count)
        XCTAssertEqual(desc1.handlerType, desc2.handlerType)
        XCTAssertEqual(desc1.commandType, desc2.commandType)
    }

    func testMiddlewareInfoContainsExpectedFields() {
        let info = MiddlewareInfo(
            name: "ValidationMiddleware",
            priority: 800,
            fullType: "MyApp.ValidationMiddleware"
        )

        XCTAssertEqual(info.name, "ValidationMiddleware")
        XCTAssertEqual(info.priority, 800)
        XCTAssertEqual(info.fullType, "MyApp.ValidationMiddleware")
    }

    // MARK: - JSON Export Tests

    func testToJSONExport() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(TestMiddleware(priority: .authentication))
        try await pipeline.addMiddleware(TestMiddleware(priority: .validation))

        let json = try await pipeline.toJSON(prettyPrinted: true)

        // Should contain valid JSON
        XCTAssertFalse(json.isEmpty)
        XCTAssertTrue(json.contains("middlewares"))
        XCTAssertTrue(json.contains("handlerType"))
        XCTAssertTrue(json.contains("commandType"))
    }

    func testToJSONCompact() async throws {
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(TestMiddleware(priority: .validation))

        let json = try await pipeline.toJSON(prettyPrinted: false)

        // Compact JSON should have no newlines (except in strings)
        let lines = json.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 1) // Single line
    }

    // MARK: - Codable Tests

    func testPipelineDescriptionCodable() throws {
        let original = PipelineDescription(
            middlewares: [
                MiddlewareInfo(name: "TestMiddleware", priority: 100, fullType: "Test.TestMiddleware")
            ],
            handlerType: "TestHandler",
            commandType: "TestCommand"
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Decode from JSON
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PipelineDescription.self, from: data)

        // Verify
        XCTAssertEqual(decoded.middlewares.count, original.middlewares.count)
        XCTAssertEqual(decoded.handlerType, original.handlerType)
        XCTAssertEqual(decoded.commandType, original.commandType)
        XCTAssertEqual(decoded.middlewares.first?.name, "TestMiddleware")
        XCTAssertEqual(decoded.middlewares.first?.priority, 100)
    }

    func testMiddlewareInfoCodable() throws {
        let original = MiddlewareInfo(
            name: "ValidationMiddleware",
            priority: 200,
            fullType: "MyApp.ValidationMiddleware"
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Decode from JSON
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MiddlewareInfo.self, from: data)

        // Verify
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.fullType, original.fullType)
    }
}

// MARK: - Test Helpers

private struct TestMiddleware: Middleware {
    let priority: ExecutionPriority

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        try await next(command, context)
    }
}

private struct TestHandler: CommandHandler {
    func handle(_ command: TestCommand) async throws -> String {
        "test-result"
    }
}

private struct TestCommand: Command {
    typealias Result = String
}
