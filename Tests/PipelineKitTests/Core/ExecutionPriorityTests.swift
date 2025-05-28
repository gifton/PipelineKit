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
    
    func testExecutionPriorityBuilder() {
        var builder = ExecutionPriorityBuilder()
        
        // Create test middleware
        struct TestMiddleware: Middleware {
            let name: String
            func execute<T: Command>(
                _ command: T,
                metadata: CommandMetadata,
                next: @Sendable (T, CommandMetadata) async throws -> T.Result
            ) async throws -> T.Result {
                try await next(command, metadata)
            }
        }
        
        // Add middleware in random order
        builder.add(TestMiddleware(name: "Logging"), order: .logging)
        builder.add(TestMiddleware(name: "Auth"), order: .authentication)
        builder.add(TestMiddleware(name: "Validation"), order: .validation)
        builder.add(TestMiddleware(name: "Custom"), priority: 150) // Between auth and authz
        builder.add(TestMiddleware(name: "RateLimit"), order: .rateLimiting)
        
        let sorted = builder.build()
        
        // Verify they're sorted by priority
        XCTAssertEqual(sorted.count, 5)
        XCTAssertEqual(sorted[0].1, 100) // Auth
        XCTAssertEqual(sorted[1].1, 150) // Custom
        XCTAssertEqual(sorted[2].1, 300) // Validation
        XCTAssertEqual(sorted[3].1, 400) // RateLimit
        XCTAssertEqual(sorted[4].1, 500) // Logging
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
            
            func execute<T: Command>(
                _ command: T,
                metadata: CommandMetadata,
                next: @Sendable (T, CommandMetadata) async throws -> T.Result
            ) async throws -> T.Result {
                await tracker.append(order)
                return try await next(command, metadata)
            }
        }
        
        let tracker = TestActor<[ExecutionPriority]>([])
        let pipeline = PriorityPipeline(handler: TestHandler())
        
        // Add middleware in non-sequential order
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: ExecutionPriority.logging, tracker: tracker),
            priority: ExecutionPriority.logging.rawValue
        )
        
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: ExecutionPriority.authentication, tracker: tracker),
            priority: ExecutionPriority.authentication.rawValue
        )
        
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: ExecutionPriority.validation, tracker: tracker),
            priority: ExecutionPriority.validation.rawValue
        )
        
        _ = try await pipeline.execute(TestCommand(), metadata: DefaultCommandMetadata())
        
        let executionOrder = await tracker.get()
        
        // Verify execution order matches priority order
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