import XCTest
@testable import PipelineKit

final class ExecutionPriorityTests: XCTestCase {
    
    func testExecutionPriorityValues() {
        // Verify that orders are properly spaced
        XCTAssertEqual(ExecutionPriority.correlation.rawValue, 10)
        XCTAssertEqual(ExecutionPriority.authentication.rawValue, 100)
        XCTAssertEqual(ExecutionPriority.authorization.rawValue, 200)
        XCTAssertEqual(ExecutionPriority.validation.rawValue, 300)
        XCTAssertEqual(ExecutionPriority.rateLimiting.rawValue, 400)
        XCTAssertEqual(ExecutionPriority.logging.rawValue, 500)
        XCTAssertEqual(ExecutionPriority.caching.rawValue, 600)
        XCTAssertEqual(ExecutionPriority.errorHandling.rawValue, 700)
        XCTAssertEqual(ExecutionPriority.responseTransformation.rawValue, 800)
        XCTAssertEqual(ExecutionPriority.transaction.rawValue, 900)
        XCTAssertEqual(ExecutionPriority.custom.rawValue, 1000)
    }
    
    func testMiddlewareCategories() {
        // Test category assignment
        XCTAssertEqual(ExecutionPriority.correlation.category, "Pre-Processing")
        XCTAssertEqual(ExecutionPriority.authentication.category, "Security")
        XCTAssertEqual(ExecutionPriority.validation.category, "Validation & Sanitization")
        XCTAssertEqual(ExecutionPriority.rateLimiting.category, "Traffic Control")
        XCTAssertEqual(ExecutionPriority.logging.category, "Observability")
        XCTAssertEqual(ExecutionPriority.caching.category, "Enhancement")
        XCTAssertEqual(ExecutionPriority.errorHandling.category, "Error Handling")
        XCTAssertEqual(ExecutionPriority.responseTransformation.category, "Post-Processing")
        XCTAssertEqual(ExecutionPriority.transaction.category, "Transaction Management")
        XCTAssertEqual(ExecutionPriority.custom.category, "Custom")
    }
    
    func testCategoryFiltering() {
        // Test getting all middleware of a specific category
        let securityMiddleware = ExecutionPriority.category(.security)
        XCTAssertTrue(securityMiddleware.contains(.authentication))
        XCTAssertTrue(securityMiddleware.contains(.authorization))
        XCTAssertTrue(securityMiddleware.contains(.rbac))
        XCTAssertFalse(securityMiddleware.contains(.validation))
        
        let observabilityMiddleware = ExecutionPriority.category(.observability)
        XCTAssertTrue(observabilityMiddleware.contains(.logging))
        XCTAssertTrue(observabilityMiddleware.contains(.monitoring))
        XCTAssertTrue(observabilityMiddleware.contains(.metrics))
        XCTAssertFalse(observabilityMiddleware.contains(.caching))
    }
    
    func testOrderingHelpers() {
        // Test between helper
        let betweenAuthAndAuthz = ExecutionPriority.between(.authentication, and: .authorization)
        XCTAssertEqual(betweenAuthAndAuthz, 150) // (100 + 200) / 2
        
        let betweenValidationAndRate = ExecutionPriority.between(.validation, and: .rateLimiting)
        XCTAssertEqual(betweenValidationAndRate, 350) // (300 + 400) / 2
        
        // Test before helper
        let beforeAuth = ExecutionPriority.before(.authentication)
        XCTAssertEqual(beforeAuth, 99)
        
        // Test after helper
        let afterLogging = ExecutionPriority.after(.logging)
        XCTAssertEqual(afterLogging, 501)
    }
    
    func testAllCasesCompleteness() {
        // Verify all cases are included
        let allCases = ExecutionPriority.allCases
        
        // Check we have the expected number of cases
        XCTAssertEqual(allCases.count, 51) // Count all the cases we defined
        
        // Verify no duplicates
        let uniqueCases = Set(allCases)
        XCTAssertEqual(uniqueCases.count, allCases.count)
        
        // Verify all categories have at least one middleware
        for category in MiddlewareCategory.allCases {
            let middlewareInCategory = ExecutionPriority.category(category)
            XCTAssertFalse(middlewareInCategory.isEmpty, "Category \(category) should have middleware")
        }
    }
    
    func testMiddlewareOrderBuilder() {
        // Test that PriorityPipeline orders middleware correctly
        // This indirectly tests the internal MiddlewareOrderBuilder
        
        // The PriorityPipelineWithOrdering test below already covers this functionality
        // by verifying that middleware executes in priority order
    }
    
    func testPriorityPipelineWithOrdering() async throws {
        // Test command and handler
        struct TestCommand: Command {
            typealias Result = String
        }
        
        struct TestHandler: CommandHandler {
            typealias CommandType = TestCommand
            func handle(_ command: TestCommand) async throws -> String {
                return "Handled"
            }
        }
        
        // Middleware that tracks execution order
        struct OrderTrackingMiddleware: Middleware {
            let order: ExecutionPriority
            let tracker: TestActor<[ExecutionPriority]>
            
            var priority: ExecutionPriority {
                return order
            }
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                await tracker.append(order)
                return try await next(command, context)
            }
        }
        
        let tracker = TestActor<[ExecutionPriority]>([])
        let pipeline = PriorityPipeline(handler: TestHandler())
        
        // Add middleware in non-sequential order
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: ExecutionPriority.logging, tracker: tracker)
        )
        
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: ExecutionPriority.authentication, tracker: tracker)
        )
        
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: ExecutionPriority.validation, tracker: tracker)
        )
        
        let context = await CommandContext.test()
        _ = try await pipeline.execute(TestCommand(), context: context)
        
        let executionOrder = await tracker.get()
        
        // Verify execution order matches priority order
        // Lower priority values execute first (higher priority)
        XCTAssertEqual(executionOrder, [.authentication, .validation, .logging])
    }
}

// Helper actor for tests
actor TestActor<T: Sendable>: Sendable {
    private var value: T
    
    init(_ value: T) {
        self.value = value
    }
    
    func get() -> T {
        value
    }
    
    func append(_ element: ExecutionPriority) where T == [ExecutionPriority] {
        value.append(element)
    }
}
