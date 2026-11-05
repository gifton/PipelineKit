import Foundation
import XCTest
import PipelineKit
import PipelineKitTestSupport

final class TimeoutTesterNumericBoundaryTests: XCTestCase {
    /// Each selected input runs in an isolated process supervised by the numeric driver.
    func testNumericConfigurationProbe() async {
        let environment = ProcessInfo.processInfo.environment
        guard let entry = environment["PIPELINEKIT_NUMERIC_ENTRY"],
              let raw = environment["PIPELINEKIT_NUMERIC_VALUE"], let value = Double(raw) else { return }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_REACHED\n".utf8))
        let task = Task {
            // Cancellation avoids sleeping for accepted large durations. Argument
            // validation must still execute before the sleep or timeout race.
            withUnsafeCurrentTask { $0?.cancel() }
            let tester = TimeoutTester()
            do {
                switch entry {
                case "test-support-timeout": _ = try await tester.withTimeout(value) { 1 }
                case "test-support-expect": _ = await tester.expectTimeout(within: value) { 1 }
                case "test-support-delay": try await tester.operation(withDelay: value)
                case "test-support-after": try await tester.operationThatWillTimeout(after: value)
                case "test-support-before": try await tester.operationThatCompletesJustInTime(before: value)
                case "test-support-run": try await tester.runWithTimeout(value)
                default: XCTFail("Unknown test support numeric probe \(entry)")
                }
            } catch is CancellationError {
                // The duration was validated; the deliberately cancelled sleep settled.
            } catch PipelineError.cancelled {
                // The duration was validated; the deliberately cancelled race settled.
            } catch {
                XCTFail("Unexpected probe error: \(error)")
            }
        }
        await task.value
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_ACCEPTED\n".utf8))
    }
}
