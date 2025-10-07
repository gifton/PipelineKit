import XCTest
@testable import PipelineKitCore

final class ExecutionPriorityTests: XCTestCase {
    // MARK: - Enum Case Tests
    
    func testAllCasesHaveCorrectRawValues() {
        XCTAssertEqual(ExecutionPriority.authentication.rawValue, 100)
        XCTAssertEqual(ExecutionPriority.validation.rawValue, 200)
        XCTAssertEqual(ExecutionPriority.resilience.rawValue, 250)
        XCTAssertEqual(ExecutionPriority.preProcessing.rawValue, 300)
        XCTAssertEqual(ExecutionPriority.monitoring.rawValue, 350)
        XCTAssertEqual(ExecutionPriority.processing.rawValue, 400)
        XCTAssertEqual(ExecutionPriority.postProcessing.rawValue, 500)
        XCTAssertEqual(ExecutionPriority.errorHandling.rawValue, 600)
        XCTAssertEqual(ExecutionPriority.observability.rawValue, 700)
        XCTAssertEqual(ExecutionPriority.custom.rawValue, 1000)
    }
    
    func testCaseIterableConformance() {
        let allCases = ExecutionPriority.allCases
        XCTAssertEqual(allCases.count, 10)
        
        // Verify all cases are present
        XCTAssertTrue(allCases.contains(.authentication))
        XCTAssertTrue(allCases.contains(.validation))
        XCTAssertTrue(allCases.contains(.resilience))
        XCTAssertTrue(allCases.contains(.preProcessing))
        XCTAssertTrue(allCases.contains(.monitoring))
        XCTAssertTrue(allCases.contains(.processing))
        XCTAssertTrue(allCases.contains(.postProcessing))
        XCTAssertTrue(allCases.contains(.errorHandling))
        XCTAssertTrue(allCases.contains(.observability))
        XCTAssertTrue(allCases.contains(.custom))
    }
    
    func testPriorityOrdering() {
        // Verify priorities are in expected order
        XCTAssertLessThan(ExecutionPriority.authentication.rawValue,
                         ExecutionPriority.validation.rawValue)
        XCTAssertLessThan(ExecutionPriority.validation.rawValue,
                         ExecutionPriority.resilience.rawValue)
        XCTAssertLessThan(ExecutionPriority.resilience.rawValue,
                         ExecutionPriority.preProcessing.rawValue)
        XCTAssertLessThan(ExecutionPriority.preProcessing.rawValue,
                         ExecutionPriority.monitoring.rawValue)
        XCTAssertLessThan(ExecutionPriority.monitoring.rawValue,
                         ExecutionPriority.processing.rawValue)
        XCTAssertLessThan(ExecutionPriority.processing.rawValue,
                         ExecutionPriority.postProcessing.rawValue)
        XCTAssertLessThan(ExecutionPriority.postProcessing.rawValue,
                         ExecutionPriority.errorHandling.rawValue)
        XCTAssertLessThan(ExecutionPriority.errorHandling.rawValue,
                         ExecutionPriority.observability.rawValue)
        XCTAssertLessThan(ExecutionPriority.observability.rawValue,
                         ExecutionPriority.custom.rawValue)
    }
    
    // MARK: - Between Method Tests
    
    func testBetweenMethodWithAdjacentPriorities() {
        let result = ExecutionPriority.between(.authentication, and: .validation)
        XCTAssertEqual(result, 150) // (100 + 200) / 2
        
        let result2 = ExecutionPriority.between(.processing, and: .postProcessing)
        XCTAssertEqual(result2, 450) // (400 + 500) / 2
    }
    
    func testBetweenMethodWithReverseOrder() {
        // Should handle reversed arguments correctly
        let result1 = ExecutionPriority.between(.validation, and: .authentication)
        let result2 = ExecutionPriority.between(.authentication, and: .validation)
        XCTAssertEqual(result1, result2)
        XCTAssertEqual(result1, 150)
    }
    
    func testBetweenMethodWithSamePriority() {
        let result = ExecutionPriority.between(.processing, and: .processing)
        XCTAssertEqual(result, ExecutionPriority.processing.rawValue)
    }
    
    func testBetweenMethodWithNonAdjacentPriorities() {
        let result = ExecutionPriority.between(.authentication, and: .processing)
        XCTAssertEqual(result, 250) // (100 + 400) / 2
        
        let result2 = ExecutionPriority.between(.validation, and: .observability)
        XCTAssertEqual(result2, 450) // (200 + 700) / 2
    }
    
    func testBetweenMethodWithCustomPriority() {
        let result = ExecutionPriority.between(.processing, and: .custom)
        XCTAssertEqual(result, 700) // (400 + 1000) / 2
    }
    
    // MARK: - Before Method Tests
    
    func testBeforeMethod() {
        XCTAssertEqual(ExecutionPriority.before(.authentication), 99)
        XCTAssertEqual(ExecutionPriority.before(.validation), 199)
        XCTAssertEqual(ExecutionPriority.before(.processing), 399)
        XCTAssertEqual(ExecutionPriority.before(.custom), 999)
    }
    
    func testBeforeMethodDoesNotCreateConflicts() {
        // Verify that before() creates values that don't conflict with existing priorities
        let beforeValidation = ExecutionPriority.before(.validation)
        XCTAssertGreaterThan(beforeValidation, ExecutionPriority.authentication.rawValue)
        XCTAssertLessThan(beforeValidation, ExecutionPriority.validation.rawValue)
    }
    
    // MARK: - After Method Tests
    
    func testAfterMethod() {
        XCTAssertEqual(ExecutionPriority.after(.authentication), 101)
        XCTAssertEqual(ExecutionPriority.after(.validation), 201)
        XCTAssertEqual(ExecutionPriority.after(.processing), 401)
        XCTAssertEqual(ExecutionPriority.after(.custom), 1001)
    }
    
    func testAfterMethodDoesNotCreateConflicts() {
        // Verify that after() creates values that don't conflict with existing priorities
        let afterAuthentication = ExecutionPriority.after(.authentication)
        XCTAssertGreaterThan(afterAuthentication, ExecutionPriority.authentication.rawValue)
        XCTAssertLessThan(afterAuthentication, ExecutionPriority.validation.rawValue)
    }
    
    // MARK: - Description Tests
    
    func testDescriptionForAllCases() {
        XCTAssertEqual(ExecutionPriority.authentication.description, "Authentication")
        XCTAssertEqual(ExecutionPriority.validation.description, "Validation")
        XCTAssertEqual(ExecutionPriority.resilience.description, "Resilience")
        XCTAssertEqual(ExecutionPriority.preProcessing.description, "Pre-Processing")
        XCTAssertEqual(ExecutionPriority.monitoring.description, "Monitoring")
        XCTAssertEqual(ExecutionPriority.processing.description, "Processing")
        XCTAssertEqual(ExecutionPriority.postProcessing.description, "Post-Processing")
        XCTAssertEqual(ExecutionPriority.errorHandling.description, "Error Handling")
        XCTAssertEqual(ExecutionPriority.observability.description, "Observability")
        XCTAssertEqual(ExecutionPriority.custom.description, "Custom")
    }
    
    // MARK: - Sorting Tests
    
    func testSortingByPriority() {
        let unsorted: [ExecutionPriority] = [
            .custom,
            .authentication,
            .processing,
            .validation,
            .postProcessing
        ]
        
        let sorted = unsorted.sorted { $0.rawValue < $1.rawValue }
        
        XCTAssertEqual(sorted, [
            .authentication,
            .validation,
            .processing,
            .postProcessing,
            .custom
        ])
    }
    
    func testSortingWithCustomPriorities() {
        struct PrioritizedItem {
            let name: String
            let priority: Int
        }
        
        let items = [
            PrioritizedItem(name: "Auth", priority: ExecutionPriority.authentication.rawValue),
            PrioritizedItem(name: "BeforeProcessing", priority: ExecutionPriority.before(.processing)),
            PrioritizedItem(name: "Processing", priority: ExecutionPriority.processing.rawValue),
            PrioritizedItem(name: "AfterProcessing", priority: ExecutionPriority.after(.processing)),
            PrioritizedItem(name: "PostProcessing", priority: ExecutionPriority.postProcessing.rawValue)
        ]
        
        let sorted = items.sorted { $0.priority < $1.priority }
        
        XCTAssertEqual(sorted.map { $0.name }, [
            "Auth",
            "BeforeProcessing",
            "Processing",
            "AfterProcessing",
            "PostProcessing"
        ])
    }
    
    // MARK: - Equatable and Hashable Tests
    
    func testEquatable() {
        XCTAssertEqual(ExecutionPriority.authentication, ExecutionPriority.authentication)
        XCTAssertNotEqual(ExecutionPriority.authentication, ExecutionPriority.validation)
    }
    
    func testHashable() {
        var set = Set<ExecutionPriority>()
        set.insert(.authentication)
        set.insert(.validation)
        set.insert(.authentication) // Duplicate
        
        XCTAssertEqual(set.count, 2)
        XCTAssertTrue(set.contains(.authentication))
        XCTAssertTrue(set.contains(.validation))
    }
    
    // MARK: - Sendable Conformance Tests
    
    func testSendableConformance() async {
        // Test that ExecutionPriority can be safely passed between actors
        let actor1 = TestActor()
        let actor2 = TestActor()
        
        let priority = ExecutionPriority.processing
        
        await actor1.setPriority(priority)
        let retrievedPriority = await actor1.getPriority()
        
        await actor2.setPriority(retrievedPriority!)
        let finalPriority = await actor2.getPriority()
        
        XCTAssertEqual(finalPriority, priority)
    }
    
    // MARK: - Use Case Tests
    
    func testMiddlewareOrderingUseCase() {
        // Simulate middleware ordering
        struct MockMiddleware {
            let name: String
            let priority: ExecutionPriority
        }
        
        let middlewares = [
            MockMiddleware(name: "Logger", priority: .observability),
            MockMiddleware(name: "Auth", priority: .authentication),
            MockMiddleware(name: "Validator", priority: .validation),
            MockMiddleware(name: "Cache", priority: .postProcessing),
            MockMiddleware(name: "BusinessLogic", priority: .processing)
        ]
        
        let sorted = middlewares.sorted { $0.priority.rawValue < $1.priority.rawValue }
        
        XCTAssertEqual(sorted.map { $0.name }, [
            "Auth",
            "Validator",
            "BusinessLogic",
            "Cache",
            "Logger"
        ])
    }
    
    func testCustomPriorityInsertion() {
        // Test inserting custom priorities between standard ones
        struct Item {
            let name: String
            let priority: Int
        }
        
        let items = [
            Item(name: "Standard1", priority: ExecutionPriority.authentication.rawValue),
            Item(name: "Custom1", priority: ExecutionPriority.between(.authentication, and: .validation)),
            Item(name: "Standard2", priority: ExecutionPriority.validation.rawValue),
            Item(name: "Custom2", priority: ExecutionPriority.before(.processing)),
            Item(name: "Standard3", priority: ExecutionPriority.processing.rawValue),
            Item(name: "Custom3", priority: ExecutionPriority.after(.processing))
        ]
        
        let sorted = items.sorted { $0.priority < $1.priority }
        
        // Verify ordering
        XCTAssertEqual(sorted[0].name, "Standard1") // 100
        XCTAssertEqual(sorted[1].name, "Custom1")   // 150
        XCTAssertEqual(sorted[2].name, "Standard2") // 200
        XCTAssertEqual(sorted[3].name, "Custom2")   // 399
        XCTAssertEqual(sorted[4].name, "Standard3") // 400
        XCTAssertEqual(sorted[5].name, "Custom3")   // 401
    }
    
    // MARK: - Edge Case Tests
    
    func testIntegerOverflowBoundary() {
        // Test that between() handles edge cases properly
        let veryLargePriority = ExecutionPriority.custom.rawValue
        let smallPriority = ExecutionPriority.authentication.rawValue
        
        // This should not overflow
        let result = (smallPriority + veryLargePriority) / 2
        XCTAssertEqual(result, ExecutionPriority.between(.authentication, and: .custom))
    }
    
    func testNegativePriorityGeneration() {
        // before() on the lowest priority could potentially create negative values
        // Ensure it works correctly
        let beforeAuth = ExecutionPriority.before(.authentication)
        XCTAssertEqual(beforeAuth, 99)
        XCTAssertGreaterThan(beforeAuth, 0) // Still positive
    }
    
    // MARK: - Performance Tests
    
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

// MARK: - Test Helpers

private actor TestActor {
    private var priority: ExecutionPriority?
    
    func setPriority(_ p: ExecutionPriority) {
        priority = p
    }
    
    func getPriority() -> ExecutionPriority? {
        return priority
    }
}
