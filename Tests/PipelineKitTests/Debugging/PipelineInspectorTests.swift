//
//  PipelineInspectorTests.swift
//  PipelineKit
//
//  Tests for PipelineInspector.
//

import XCTest
@testable import PipelineKit
@testable import PipelineKitCore
import PipelineKitTestSupport

// MARK: - Test Commands and Handlers

struct InspectorTestCommand: Command {
    typealias Result = String
    let value: String

    func execute() async throws -> String { value }
}

final class InspectorTestHandler: CommandHandler {
    typealias CommandType = InspectorTestCommand

    func handle(_ command: InspectorTestCommand) async throws -> String {
        command.value
    }
}

// MARK: - Test Middleware

struct FirstTestMiddleware: Middleware {
    let priority: ExecutionPriority = .authentication

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        try await next(command, context)
    }
}

struct SecondTestMiddleware: Middleware {
    let priority: ExecutionPriority = .validation

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        try await next(command, context)
    }
}

struct ThirdTestMiddleware: Middleware {
    let priority: ExecutionPriority = .postProcessing

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        try await next(command, context)
    }
}

// MARK: - PipelineInspector Tests

final class PipelineInspectorTests: XCTestCase {

    // MARK: - Inspection Tests

    func testInspectEmptyPipeline() async {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())

        let info = await PipelineInspector.inspect(pipeline)

        XCTAssertEqual(info.middlewareCount, 0)
        XCTAssertTrue(info.middlewareTypes.isEmpty)
        XCTAssertEqual(info.commandType, "InspectorTestCommand")
        XCTAssertEqual(info.handlerType, "InspectorTestHandler")
    }

    func testInspectPipelineWithMiddleware() async throws {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline.addMiddleware(FirstTestMiddleware())
        try await pipeline.addMiddleware(SecondTestMiddleware())

        let info = await PipelineInspector.inspect(pipeline)

        XCTAssertEqual(info.middlewareCount, 2)
        XCTAssertEqual(info.middlewareTypes.count, 2)
    }

    func testMiddlewareTypesOrdered() async throws {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())
        // Add in non-priority order
        try await pipeline.addMiddleware(ThirdTestMiddleware())
        try await pipeline.addMiddleware(FirstTestMiddleware())
        try await pipeline.addMiddleware(SecondTestMiddleware())

        let info = await PipelineInspector.inspect(pipeline)

        // Should be ordered by priority (authentication first, then validation, then postProcessing)
        XCTAssertEqual(info.middlewareTypes.count, 3)
        // The first middleware should be authentication (highest priority)
        XCTAssertTrue(info.middlewareTypes[0].contains("FirstTestMiddleware"))
    }

    func testCommandTypeReported() async {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())

        let info = await PipelineInspector.inspect(pipeline)

        XCTAssertEqual(info.commandType, "InspectorTestCommand")
    }

    func testHandlerTypeReported() async {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())

        let info = await PipelineInspector.inspect(pipeline)

        XCTAssertEqual(info.handlerType, "InspectorTestHandler")
    }

    // MARK: - Diagram Tests

    func testDiagramEmptyPipeline() async {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())

        let diagram = await PipelineInspector.diagram(pipeline)

        XCTAssertTrue(diagram.contains("InspectorTestCommand"))
        XCTAssertTrue(diagram.contains("[Handler]"))
        XCTAssertTrue(diagram.contains("[Result]"))
        XCTAssertTrue(diagram.contains("Middleware: 0"))
    }

    func testDiagramWithMiddleware() async throws {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline.addMiddleware(FirstTestMiddleware())
        try await pipeline.addMiddleware(SecondTestMiddleware())

        let diagram = await PipelineInspector.diagram(pipeline)

        XCTAssertTrue(diagram.contains("FirstTestMiddleware"))
        XCTAssertTrue(diagram.contains("SecondTestMiddleware"))
        XCTAssertTrue(diagram.contains("Middleware: 2"))
    }

    func testDiagramFromInfo() async throws {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline.addMiddleware(FirstTestMiddleware())

        let info = await PipelineInspector.inspect(pipeline)
        let diagram = PipelineInspector.diagram(info)

        XCTAssertTrue(diagram.contains("InspectorTestCommand"))
        XCTAssertTrue(diagram.contains("FirstTestMiddleware"))
    }

    // MARK: - Comparison Tests

    func testCompareIdenticalPipelines() async throws {
        let pipeline1 = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline1.addMiddleware(FirstTestMiddleware())

        let pipeline2 = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline2.addMiddleware(FirstTestMiddleware())

        let info1 = await PipelineInspector.inspect(pipeline1)
        let info2 = await PipelineInspector.inspect(pipeline2)

        let comparison = PipelineInspector.compare(info1, info2)
        XCTAssertTrue(comparison.contains("identical"))
    }

    func testCompareDifferentMiddlewareCount() async throws {
        let pipeline1 = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline1.addMiddleware(FirstTestMiddleware())

        let pipeline2 = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline2.addMiddleware(FirstTestMiddleware())
        try await pipeline2.addMiddleware(SecondTestMiddleware())

        let info1 = await PipelineInspector.inspect(pipeline1)
        let info2 = await PipelineInspector.inspect(pipeline2)

        let comparison = PipelineInspector.compare(info1, info2)
        XCTAssertTrue(comparison.contains("Middleware count"))
    }

    func testCompareDifferentMiddlewareTypes() async throws {
        let pipeline1 = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline1.addMiddleware(FirstTestMiddleware())

        let pipeline2 = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline2.addMiddleware(SecondTestMiddleware())

        let info1 = await PipelineInspector.inspect(pipeline1)
        let info2 = await PipelineInspector.inspect(pipeline2)

        let comparison = PipelineInspector.compare(info1, info2)
        XCTAssertTrue(comparison.contains("Only in first") || comparison.contains("Only in second"))
    }

    // MARK: - PipelineInfo Tests

    func testPipelineInfoDescription() async throws {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline.addMiddleware(FirstTestMiddleware())

        let info = await PipelineInspector.inspect(pipeline)

        XCTAssertFalse(info.description.isEmpty)
        XCTAssertTrue(info.description.contains("InspectorTestCommand"))
    }

    func testPipelineInfoDebugDescription() async throws {
        let pipeline = StandardPipeline(handler: InspectorTestHandler())
        try await pipeline.addMiddleware(FirstTestMiddleware())

        let info = await PipelineInspector.inspect(pipeline)

        // debugDescription is the diagram
        XCTAssertTrue(info.debugDescription.contains("[Command]"))
        XCTAssertTrue(info.debugDescription.contains("[Handler]"))
    }
}
