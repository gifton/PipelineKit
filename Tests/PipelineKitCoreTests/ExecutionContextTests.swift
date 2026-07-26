import XCTest
@testable import PipelineKitCore

final class ExecutionContextTests: XCTestCase {
    private func makeTrace() -> TraceMetadata {
        TraceMetadata(commandID: UUID(), correlationID: "corr-1", userID: "user-1")
    }

    func testCurrentIsNilOutsideAnyBinding() {
        XCTAssertNil(ExecutionContext.current)
    }

    func testBindingIsVisibleAtDepthAndInChildTasks() async throws {
        let trace = makeTrace()

        // Simulates a repository/helper N frames below the handler.
        func deepHelper() -> TraceMetadata? {
            ExecutionContext.current?.trace
        }

        try await ExecutionContext.$current.withValue(ExecutionContext(trace: trace)) {
            XCTAssertEqual(deepHelper(), trace)

            // Structured child tasks inherit task-locals.
            let fromChild = try await withThrowingTaskGroup(of: TraceMetadata?.self) { group -> TraceMetadata? in
                group.addTask { ExecutionContext.current?.trace }
                return try await group.next() ?? nil
            }
            XCTAssertEqual(fromChild, trace)
        }
        XCTAssertNil(ExecutionContext.current, "Binding must unwind after withValue")
    }

    func testDetachedTaskDoesNotInherit() async {
        let trace = makeTrace()
        await ExecutionContext.$current.withValue(ExecutionContext(trace: trace)) {
            let seenInDetached = await Task.detached { ExecutionContext.current }.value
            XCTAssertNil(seenInDetached, "Task.detached must not inherit task-locals (documented sharp edge)")
        }
    }

    func testTraceMetadataIsCodable() throws {
        let trace = makeTrace()
        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(TraceMetadata.self, from: data)
        XCTAssertEqual(decoded, trace)
    }
}
