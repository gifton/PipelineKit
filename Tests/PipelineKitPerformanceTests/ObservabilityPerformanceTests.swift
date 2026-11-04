import XCTest
import PipelineKitCore
import PipelineKitObservability

final class ObservabilityPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if targetEnvironment(simulator)
        throw XCTSkip("Performance measurements are not meaningful on emulated simulator runners")
        #endif
    }

    func testObservabilitySetupPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Setup performance")

            Task {
                let context = CommandContext()
                await context.setupObservability(.production)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 1.0)
        }
    }

    func testObservabilitySystemPerformance() async throws {
        let context = CommandContext()
        await context.setupObservability(.production)

        measure {
            let expectation = XCTestExpectation(description: "Performance test")

            Task {
                // Record many metrics rapidly
                for i in 0..<1000 {
                    await context.recordCounter(
                        name: "perf.counter",
                        value: Double(i),
                        tags: ["index": "\(i)"]
                    )
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }
}
