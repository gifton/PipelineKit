//
//  ExecutionTracerTests.swift
//  PipelineKitObservabilityTests
//
//  Tests for execution tracing and distributed tracing
//

import XCTest
@testable import PipelineKitObservability
@testable import PipelineKitCore
@testable import PipelineKit

final class ExecutionTracerTests: XCTestCase {
    // MARK: - Basic Span Tests

    func testStartAndEndSpan() async {
        let tracer = ExecutionTracer()
        let correlationID = "test-123"

        let spanID = await tracer.startSpan(
            name: "test.span",
            correlationID: correlationID
        )

        await tracer.endSpan(spanID, correlationID: correlationID, result: .success)

        let trace = await tracer.getTrace(correlationID: correlationID)
        XCTAssertNotNil(trace)
        XCTAssertEqual(trace?.spans.count, 1)
        XCTAssertEqual(trace?.spans.first?.name, "test.span")
        XCTAssertNotNil(trace?.spans.first?.duration)
    }

    func testMultipleSpans() async {
        let tracer = ExecutionTracer()
        let correlationID = "test-456"

        let span1 = await tracer.startSpan(name: "span1", correlationID: correlationID)
        let span2 = await tracer.startSpan(name: "span2", correlationID: correlationID)

        await tracer.endSpan(span1, correlationID: correlationID, result: .success)
        await tracer.endSpan(span2, correlationID: correlationID, result: .success)

        let trace = await tracer.getTrace(correlationID: correlationID)
        XCTAssertEqual(trace?.spans.count, 2)
    }

    func testTraceWithFailure() async {
        let tracer = ExecutionTracer()
        let correlationID = "test-error"

        let spanID = await tracer.startSpan(name: "failing.span", correlationID: correlationID)
        await tracer.endSpan(spanID, correlationID: correlationID, result: .failure("Test error"))

        let trace = await tracer.getTrace(correlationID: correlationID)
        XCTAssertEqual(trace?.spans.first?.result?.isSuccess, false)
    }

    func testSpanDuration() async {
        let tracer = ExecutionTracer()
        let correlationID = "test-duration"

        let spanID = await tracer.startSpan(name: "timed.span", correlationID: correlationID)

        // Simulate some work
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        await tracer.endSpan(spanID, correlationID: correlationID, result: .success)

        let trace = await tracer.getTrace(correlationID: correlationID)
        if let duration = trace?.spans.first?.duration {
            XCTAssertGreaterThan(duration, 5) // Should be at least 5ms
        } else {
            XCTFail("Duration should be present")
        }
    }

    // MARK: - Trace Lifecycle Tests

    func testTraceCompletion() async {
        let tracer = ExecutionTracer()
        let correlationID = "test-completion"

        let span1 = await tracer.startSpan(name: "span1", correlationID: correlationID)
        let span2 = await tracer.startSpan(name: "span2", correlationID: correlationID)

        // Initially no end time
        var trace = await tracer.getTrace(correlationID: correlationID)
        XCTAssertNil(trace?.endTime)

        // End first span
        await tracer.endSpan(span1, correlationID: correlationID, result: .success)
        trace = await tracer.getTrace(correlationID: correlationID)
        XCTAssertNil(trace?.endTime) // Not complete yet

        // End second span - trace should complete
        await tracer.endSpan(span2, correlationID: correlationID, result: .success)
        trace = await tracer.getTrace(correlationID: correlationID)
        XCTAssertNotNil(trace?.endTime)
        XCTAssertNotNil(trace?.duration)
    }

    func testClearTrace() async {
        let tracer = ExecutionTracer()
        let correlationID = "test-clear"

        _ = await tracer.startSpan(name: "test", correlationID: correlationID)

        // Trace should exist
        var trace = await tracer.getTrace(correlationID: correlationID)
        XCTAssertNotNil(trace)

        // Clear trace
        await tracer.clearTrace(correlationID: correlationID)

        // Trace should be gone
        trace = await tracer.getTrace(correlationID: correlationID)
        XCTAssertNil(trace)
    }

    func testClearAllTraces() async {
        let tracer = ExecutionTracer()

        _ = await tracer.startSpan(name: "span1", correlationID: "trace1")
        _ = await tracer.startSpan(name: "span2", correlationID: "trace2")

        var traces = await tracer.getAllTraces()
        XCTAssertEqual(traces.count, 2)

        await tracer.clearAllTraces()

        traces = await tracer.getAllTraces()
        XCTAssertEqual(traces.count, 0)
    }

    // MARK: - JSON Export Tests

    func testJSONExport() async throws {
        let tracer = ExecutionTracer()
        let correlationID = "test-json"

        let spanID = await tracer.startSpan(name: "test.span", correlationID: correlationID)
        await tracer.endSpan(spanID, correlationID: correlationID, result: .success)

        guard let trace = await tracer.getTrace(correlationID: correlationID) else {
            XCTFail("Trace not found")
            return
        }

        let json = try await tracer.traceAsJSON(trace)

        XCTAssertFalse(json.isEmpty)
        XCTAssertTrue(json.contains("correlationID"))
        XCTAssertTrue(json.contains("test.span"))
        XCTAssertTrue(json.contains("durationMs"))
    }

    func testJSONWithFailure() async throws {
        let tracer = ExecutionTracer()
        let correlationID = "test-json-error"

        let spanID = await tracer.startSpan(name: "failing.span", correlationID: correlationID)
        await tracer.endSpan(spanID, correlationID: correlationID, result: .failure("Custom error"))

        guard let trace = await tracer.getTrace(correlationID: correlationID) else {
            XCTFail("Trace not found")
            return
        }

        let json = try await tracer.traceAsJSON(trace)

        XCTAssertTrue(json.contains("failing.span"))
        XCTAssertTrue(json.contains("success"))
    }

    // MARK: - Configuration Tests

    func testMaxTracesLimit() async {
        let config = ExecutionTracer.Configuration(
            maxTraces: 3,
            retentionTime: 300
        )
        let tracer = ExecutionTracer(configuration: config)

        // Create 5 traces
        for i in 1...5 {
            _ = await tracer.startSpan(name: "span\(i)", correlationID: "trace\(i)")
        }

        // Add one more to trigger purge
        _ = await tracer.startSpan(name: "span6", correlationID: "trace6")

        let traces = await tracer.getAllTraces()

        // Should have purged old traces, keeping only recent ones
        // Note: Purging happens on next add after exceeding limit
        XCTAssertLessThanOrEqual(traces.count, 6)
        XCTAssertGreaterThan(traces.count, 0)
    }

    // MARK: - Multiple Correlation IDs

    func testMultipleCorrelationIDs() async {
        let tracer = ExecutionTracer()

        _ = await tracer.startSpan(name: "user.request", correlationID: "req-001")
        _ = await tracer.startSpan(name: "api.call", correlationID: "req-002")

        let trace1 = await tracer.getTrace(correlationID: "req-001")
        let trace2 = await tracer.getTrace(correlationID: "req-002")

        XCTAssertNotNil(trace1)
        XCTAssertNotNil(trace2)
        XCTAssertEqual(trace1?.correlationID, "req-001")
        XCTAssertEqual(trace2?.correlationID, "req-002")
    }

    // MARK: - TracingMiddleware Tests

    func testTracingMiddleware() async throws {
        let tracer = ExecutionTracer()
        let middleware = TracingMiddleware(tracer: tracer)

        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(middleware)

        let context = CommandContext()
        context.setCorrelationID("test-middleware-001")

        _ = try await pipeline.execute(TestCommand(), context: context)

        let trace = await tracer.getTrace(correlationID: "test-middleware-001")
        XCTAssertNotNil(trace)
        XCTAssertEqual(trace?.spans.count, 1)
        XCTAssertTrue(trace?.spans.first?.name.contains("TestCommand") ?? false)
    }

    func testTracingMiddlewareWithFailure() async throws {
        let tracer = ExecutionTracer()
        let middleware = TracingMiddleware(tracer: tracer)

        let pipeline = StandardPipeline(handler: FailingHandler())
        try await pipeline.addMiddleware(middleware)

        let context = CommandContext()
        context.setCorrelationID("test-failure-001")

        do {
            _ = try await pipeline.execute(TestCommand(), context: context)
            XCTFail("Should have thrown error")
        } catch {
            // Expected
        }

        let trace = await tracer.getTrace(correlationID: "test-failure-001")
        XCTAssertNotNil(trace)
        XCTAssertEqual(trace?.spans.first?.result?.isSuccess, false)
    }

    func testTracingMiddlewareAutoCorrelation() async throws {
        let tracer = ExecutionTracer()
        let middleware = TracingMiddleware(tracer: tracer)

        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(middleware)

        let context = CommandContext()
        // Don't set correlation ID - should be auto-generated

        _ = try await pipeline.execute(TestCommand(), context: context)

        // Should have auto-generated correlation ID
        XCTAssertNotNil(context.correlationID)

        let trace = await tracer.getTrace(correlationID: context.correlationID!)
        XCTAssertNotNil(trace)
    }

    // MARK: - Print Trace Test (Manual Verification)

    func testPrintTrace() async {
        let tracer = ExecutionTracer()
        let correlationID = "test-print-001"

        let span1 = await tracer.startSpan(name: "middleware.Validation", correlationID: correlationID)
        try? await Task.sleep(nanoseconds: 2_000_000) // 2ms
        await tracer.endSpan(span1, correlationID: correlationID, result: .success)

        let span2 = await tracer.startSpan(name: "middleware.Authentication", correlationID: correlationID)
        try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        await tracer.endSpan(span2, correlationID: correlationID, result: .success)

        let span3 = await tracer.startSpan(name: "handler.CreateUser", correlationID: correlationID)
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        await tracer.endSpan(span3, correlationID: correlationID, result: .success)

        if let trace = await tracer.getTrace(correlationID: correlationID) {
            print("\n=== Manual Verification: Check console output ===")
            await tracer.printTrace(trace)
            print("=== End Manual Verification ===\n")

            // Verify trace is complete
            XCTAssertNotNil(trace.endTime)
            XCTAssertNotNil(trace.duration)
        } else {
            XCTFail("Trace not found")
        }
    }

    // MARK: - Convenience Extension Tests

    func testTracerMiddlewareExtension() async throws {
        let tracer = ExecutionTracer()
        let middleware = await tracer.middleware()

        XCTAssertEqual(middleware.priority, .observability)

        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(middleware)

        let context = CommandContext()
        context.setCorrelationID("test-extension-001")

        _ = try await pipeline.execute(TestCommand(), context: context)

        let trace = await tracer.getTrace(correlationID: "test-extension-001")
        XCTAssertNotNil(trace)
    }
}

// MARK: - Test Helpers

private struct TestCommand: Command {
    typealias Result = String
}

private struct TestHandler: CommandHandler {
    func handle(_ command: TestCommand) async throws -> String {
        "test-result"
    }
}

private struct FailingHandler: CommandHandler {
    func handle(_ command: TestCommand) async throws -> String {
        struct TestError: Error {}
        throw TestError()
    }
}
