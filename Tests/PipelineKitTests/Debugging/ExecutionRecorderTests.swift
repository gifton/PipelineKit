//
//  ExecutionRecorderTests.swift
//  PipelineKit
//
//  Tests for ExecutionRecorder and RecordingMiddleware.
//

import XCTest
@testable import PipelineKit
@testable import PipelineKitCore
import PipelineKitTestSupport

final class ExecutionRecorderTests: XCTestCase {

    var recorder: ExecutionRecorder!

    override func setUp() async throws {
        try await super.setUp()
        recorder = ExecutionRecorder(maxRecords: 100)
    }

    override func tearDown() async throws {
        recorder = nil
        try await super.tearDown()
    }

    // MARK: - Recording Tests

    func testRecordSuccessfulExecution() async {
        let record = ExecutionRecord(
            commandType: "TestCommand",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )

        await recorder.record(record)

        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testRecordFailedExecution() async {
        let record = ExecutionRecord(
            commandType: "TestCommand",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: false,
            errorMessage: "Test error",
            errorType: "TestError"
        )

        await recorder.record(record)

        let failures = await recorder.failures(limit: 10)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.errorMessage, "Test error")
    }

    func testRecordFromDetails() async {
        let record = ExecutionRecord(
            commandType: "MyCommand",
            commandID: UUID(),
            correlationID: "corr-123",
            startTime: Date().addingTimeInterval(-1),
            endTime: Date(),
            succeeded: true,
            middlewareTrace: ["M1", "M2"],
            metadata: ["key": "value"]
        )
        await recorder.record(record)

        let recent = await recorder.recent(limit: 1)
        XCTAssertEqual(recent.first?.commandType, "MyCommand")
        XCTAssertEqual(recent.first?.correlationID, "corr-123")
        XCTAssertEqual(recent.first?.middlewareTrace, ["M1", "M2"])
    }

    // MARK: - Query Tests

    func testRecentReturnsNewestFirst() async {
        for i in 0..<5 {
            let record = ExecutionRecord(
                commandType: "Command\(i)",
                commandID: UUID(),
                startTime: Date().addingTimeInterval(TimeInterval(i)),
                endTime: Date().addingTimeInterval(TimeInterval(i) + 0.1),
                succeeded: true
            )
            await recorder.record(record)
        }

        let recent = await recorder.recent(limit: 3)

        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent[0].commandType, "Command4") // Newest
        XCTAssertEqual(recent[1].commandType, "Command3")
        XCTAssertEqual(recent[2].commandType, "Command2")
    }

    func testRecentLimitsResults() async {
        for i in 0..<10 {
            let record = ExecutionRecord(
                commandType: "Command\(i)",
                commandID: UUID(),
                startTime: Date(),
                endTime: Date(),
                succeeded: true
            )
            await recorder.record(record)
        }

        let recent = await recorder.recent(limit: 3)
        XCTAssertEqual(recent.count, 3)
    }

    func testQueryByCommandType() async {
        let recordA1 = ExecutionRecord(
            commandType: "TypeA",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(recordA1)

        let recordB = ExecutionRecord(
            commandType: "TypeB",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(recordB)

        let recordA2 = ExecutionRecord(
            commandType: "TypeA",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(recordA2)

        let typeA = await recorder.executions(forCommandType: "TypeA", limit: 10)
        XCTAssertEqual(typeA.count, 2)
    }

    func testQueryFailures() async {
        let success = ExecutionRecord(
            commandType: "Command",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(success)

        await recorder.record(
            commandType: "Command",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            error: TestError.commandFailed
        )

        let failures = await recorder.failures(limit: 10)
        XCTAssertEqual(failures.count, 1)
    }

    func testQuerySuccesses() async {
        let success = ExecutionRecord(
            commandType: "Command",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(success)

        await recorder.record(
            commandType: "Command",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            error: TestError.commandFailed
        )

        let successes = await recorder.successes(limit: 10)
        XCTAssertEqual(successes.count, 1)
    }

    func testQueryByCorrelationID() async {
        let record1 = ExecutionRecord(
            commandType: "Command",
            commandID: UUID(),
            correlationID: "corr-A",
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(record1)

        let record2 = ExecutionRecord(
            commandType: "Command",
            commandID: UUID(),
            correlationID: "corr-B",
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(record2)

        let record3 = ExecutionRecord(
            commandType: "Command",
            commandID: UUID(),
            correlationID: "corr-A",
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(record3)

        let corrA = await recorder.executions(withCorrelationID: "corr-A")
        XCTAssertEqual(corrA.count, 2)
    }

    func testQueryByTimeRange() async {
        let now = Date()
        let past = now.addingTimeInterval(-3600) // 1 hour ago
        let future = now.addingTimeInterval(3600) // 1 hour from now

        let oldRecord = ExecutionRecord(
            commandType: "Old",
            commandID: UUID(),
            startTime: past,
            endTime: past.addingTimeInterval(1),
            succeeded: true
        )
        await recorder.record(oldRecord)

        let currentRecord = ExecutionRecord(
            commandType: "Current",
            commandID: UUID(),
            startTime: now,
            endTime: now.addingTimeInterval(1),
            succeeded: true
        )
        await recorder.record(currentRecord)

        let inRange = await recorder.executions(
            from: now.addingTimeInterval(-60),
            to: future
        )
        XCTAssertEqual(inRange.count, 1)
        XCTAssertEqual(inRange.first?.commandType, "Current")
    }

    func testFindByID() async {
        let recordID = UUID()
        let record = ExecutionRecord(
            id: recordID,
            commandType: "FindMe",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(record)

        let found = await recorder.execution(withID: recordID)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.commandType, "FindMe")
    }

    // MARK: - Bounded Storage Tests

    func testMaxRecordsLimit() async {
        let smallRecorder = ExecutionRecorder(maxRecords: 5)

        for i in 0..<10 {
            await smallRecorder.record(
                commandType: "Command\(i)",
                commandID: UUID(),
                startTime: Date(),
                endTime: Date(),
                error: nil
            )
        }

        let count = await smallRecorder.count
        XCTAssertEqual(count, 5)
    }

    func testOldestEvictedFirst() async {
        let smallRecorder = ExecutionRecorder(maxRecords: 3)

        for i in 0..<5 {
            await smallRecorder.record(
                commandType: "Command\(i)",
                commandID: UUID(),
                startTime: Date(),
                endTime: Date(),
                error: nil
            )
        }

        let all = await smallRecorder.all()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].commandType, "Command2") // Oldest remaining
        XCTAssertEqual(all[2].commandType, "Command4") // Newest
    }

    // MARK: - Statistics Tests

    func testStatsEmpty() async {
        let stats = await recorder.stats()

        XCTAssertEqual(stats.currentRecords, 0)
        XCTAssertEqual(stats.totalRecorded, 0)
        XCTAssertEqual(stats.totalSucceeded, 0)
        XCTAssertEqual(stats.totalFailed, 0)
        XCTAssertEqual(stats.successRate, 1.0)
        XCTAssertNil(stats.averageDuration)
    }

    func testStatsWithRecords() async {
        let successRecord = ExecutionRecord(
            commandType: "A",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(0.1),
            succeeded: true
        )
        await recorder.record(successRecord)

        await recorder.record(
            commandType: "B",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(0.2),
            error: TestError.commandFailed
        )

        let stats = await recorder.stats()

        XCTAssertEqual(stats.currentRecords, 2)
        XCTAssertEqual(stats.totalRecorded, 2)
        XCTAssertEqual(stats.totalSucceeded, 1)
        XCTAssertEqual(stats.totalFailed, 1)
        XCTAssertEqual(stats.commandTypes, 2)
    }

    func testSuccessRateCalculation() async {
        // 3 successes, 1 failure
        for i in 0..<3 {
            let record = ExecutionRecord(
                commandType: "Success\(i)",
                commandID: UUID(),
                startTime: Date(),
                endTime: Date(),
                succeeded: true
            )
            await recorder.record(record)
        }
        await recorder.record(
            commandType: "Failure",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            error: TestError.commandFailed
        )

        let stats = await recorder.stats()
        XCTAssertEqual(stats.successRate, 0.75, accuracy: 0.01)
        XCTAssertEqual(stats.failureRate, 0.25, accuracy: 0.01)
    }

    func testAverageDuration() async {
        // Record with known durations
        let start1 = Date()
        let end1 = start1.addingTimeInterval(0.1)
        let start2 = Date()
        let end2 = start2.addingTimeInterval(0.3)

        let record1 = ExecutionRecord(
            commandType: "A",
            commandID: UUID(),
            startTime: start1,
            endTime: end1,
            succeeded: true
        )
        await recorder.record(record1)

        let record2 = ExecutionRecord(
            commandType: "B",
            commandID: UUID(),
            startTime: start2,
            endTime: end2,
            succeeded: true
        )
        await recorder.record(record2)

        let stats = await recorder.stats()
        XCTAssertNotNil(stats.averageDuration)
        // Average should be ~0.2
        XCTAssertEqual(stats.averageDuration!, 0.2, accuracy: 0.01)
    }

    // MARK: - Management Tests

    func testClear() async {
        let record = ExecutionRecord(
            commandType: "Command",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(record)

        await recorder.clear()

        let count = await recorder.count
        XCTAssertEqual(count, 0)

        // But stats should still reflect historical data
        let stats = await recorder.stats()
        XCTAssertEqual(stats.totalRecorded, 1)
    }

    func testReset() async {
        let record = ExecutionRecord(
            commandType: "Command",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date(),
            succeeded: true
        )
        await recorder.record(record)

        await recorder.reset()

        let count = await recorder.count
        XCTAssertEqual(count, 0)

        // Stats should also be reset
        let stats = await recorder.stats()
        XCTAssertEqual(stats.totalRecorded, 0)
    }

    // MARK: - ExecutionRecord Tests

    func testExecutionRecordDuration() {
        let start = Date()
        let end = start.addingTimeInterval(1.5)

        let record = ExecutionRecord(
            commandType: "Test",
            commandID: UUID(),
            startTime: start,
            endTime: end,
            succeeded: true
        )

        XCTAssertEqual(record.duration, 1.5, accuracy: 0.001)
    }

    func testExecutionRecordDescription() {
        let record = ExecutionRecord(
            commandType: "TestCommand",
            commandID: UUID(),
            startTime: Date(),
            endTime: Date().addingTimeInterval(0.1),
            succeeded: true
        )

        XCTAssertTrue(record.description.contains("OK"))
        XCTAssertTrue(record.description.contains("TestCommand"))
    }

    func testExecutionRecordDebugDescription() {
        let record = ExecutionRecord(
            commandType: "TestCommand",
            commandID: UUID(),
            correlationID: "corr-123",
            startTime: Date(),
            endTime: Date().addingTimeInterval(0.1),
            succeeded: false,
            errorMessage: "Test error",
            errorType: "TestError",
            middlewareTrace: ["M1", "M2"]
        )

        let debug = record.debugDescription
        XCTAssertTrue(debug.contains("TestCommand"))
        XCTAssertTrue(debug.contains("corr-123"))
        XCTAssertTrue(debug.contains("Test error"))
        XCTAssertTrue(debug.contains("TestError"))
        XCTAssertTrue(debug.contains("M1"))
    }

    // MARK: - RecordingMiddleware Tests

    func testRecordingMiddlewareRecordsSuccess() async throws {
        let pipeline = StandardPipeline(handler: TestCommandHandler())
        let recording = RecordingMiddleware(recorder: recorder)
        try await pipeline.addMiddleware(recording)

        _ = try await pipeline.execute(TestCommand(value: "test"))

        let recent = await recorder.recent(limit: 1)
        XCTAssertEqual(recent.count, 1)
        XCTAssertTrue(recent.first?.succeeded ?? false)
    }

    func testRecordingMiddlewareRecordsFailure() async throws {
        let pipeline = StandardPipeline(handler: TestCommandHandler())
        let recording = RecordingMiddleware(recorder: recorder)
        try await pipeline.addMiddleware(recording)

        do {
            _ = try await pipeline.execute(TestCommand(value: "test", shouldFail: true))
            XCTFail("Expected error")
        } catch {
            // Expected
        }

        let recent = await recorder.recent(limit: 1)
        XCTAssertEqual(recent.count, 1)
        XCTAssertFalse(recent.first?.succeeded ?? true)
    }
}
