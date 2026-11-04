import XCTest
import PipelineKitCore

final class CoreValuePerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if targetEnvironment(simulator)
        throw XCTSkip("Performance measurements are not meaningful on emulated simulator runners")
        #endif
    }

    func testKeyCreationPerformance() {
        measure {
            for i in 0..<10000 {
                _ = ContextKey<String>("key\(i)")
            }
        }
    }

    func testKeyComparisonPerformance() {
        let key1 = ContextKey<String>("test")
        let key2 = ContextKey<String>("test")

        measure {
            for _ in 0..<100000 {
                _ = key1 == key2
            }
        }
    }

    func testPriorityComparisonPerformance() {
        let priority1 = ExecutionPriority.authentication
        let priority2 = ExecutionPriority.processing

        measure {
            for _ in 0..<100000 {
                _ = priority1.rawValue < priority2.rawValue
            }
        }
    }

    func testBetweenMethodPerformance() {
        measure {
            for _ in 0..<100000 {
                _ = ExecutionPriority.between(.authentication, and: .processing)
            }
        }
    }

    func testDescriptionPerformance() {
        let priorities = ExecutionPriority.allCases

        measure {
            for _ in 0..<10000 {
                for priority in priorities {
                    _ = priority.description
                }
            }
        }
    }
}
