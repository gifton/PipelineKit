import XCTest
@testable import PipelineKit

final class MiddlewareOrderTests: XCTestCase {
    
    func testMiddlewareOrderValues() {
        // Verify that orders are properly spaced
        XCTAssertEqual(MiddlewareOrder.correlation.rawValue, 10)
        XCTAssertEqual(MiddlewareOrder.authentication.rawValue, 100)
        XCTAssertEqual(MiddlewareOrder.authorization.rawValue, 200)
        XCTAssertEqual(MiddlewareOrder.validation.rawValue, 300)
        XCTAssertEqual(MiddlewareOrder.rateLimiting.rawValue, 400)
        XCTAssertEqual(MiddlewareOrder.logging.rawValue, 500)
        XCTAssertEqual(MiddlewareOrder.caching.rawValue, 600)
        XCTAssertEqual(MiddlewareOrder.errorHandling.rawValue, 700)
        XCTAssertEqual(MiddlewareOrder.responseTransformation.rawValue, 800)
        XCTAssertEqual(MiddlewareOrder.transaction.rawValue, 900)
        XCTAssertEqual(MiddlewareOrder.custom.rawValue, 1000)
    }
    
    func testMiddlewareCategories() {
        // Test category assignment
        XCTAssertEqual(MiddlewareOrder.correlation.category, "Pre-Processing")
        XCTAssertEqual(MiddlewareOrder.authentication.category, "Security")
        XCTAssertEqual(MiddlewareOrder.validation.category, "Validation & Sanitization")
        XCTAssertEqual(MiddlewareOrder.rateLimiting.category, "Traffic Control")
        XCTAssertEqual(MiddlewareOrder.logging.category, "Observability")
        XCTAssertEqual(MiddlewareOrder.caching.category, "Enhancement")
        XCTAssertEqual(MiddlewareOrder.errorHandling.category, "Error Handling")
        XCTAssertEqual(MiddlewareOrder.responseTransformation.category, "Post-Processing")
        XCTAssertEqual(MiddlewareOrder.transaction.category, "Transaction Management")
        XCTAssertEqual(MiddlewareOrder.custom.category, "Custom")
    }
    
    func testCategoryFiltering() {
        // Test getting all middleware of a specific category
        let securityMiddleware = MiddlewareOrder.category(.security)
        XCTAssertTrue(securityMiddleware.contains(.authentication))
        XCTAssertTrue(securityMiddleware.contains(.authorization))
        XCTAssertTrue(securityMiddleware.contains(.rbac))
        XCTAssertFalse(securityMiddleware.contains(.validation))
        
        let observabilityMiddleware = MiddlewareOrder.category(.observability)
        XCTAssertTrue(observabilityMiddleware.contains(.logging))
        XCTAssertTrue(observabilityMiddleware.contains(.monitoring))
        XCTAssertTrue(observabilityMiddleware.contains(.metrics))
        XCTAssertFalse(observabilityMiddleware.contains(.caching))
    }
    
    func testOrderingHelpers() {
        // Test between helper
        let betweenAuthAndAuthz = MiddlewareOrder.between(.authentication, and: .authorization)
        XCTAssertEqual(betweenAuthAndAuthz, 150) // (100 + 200) / 2
        
        let betweenValidationAndRate = MiddlewareOrder.between(.validation, and: .rateLimiting)
        XCTAssertEqual(betweenValidationAndRate, 350) // (300 + 400) / 2
        
        // Test before helper
        let beforeAuth = MiddlewareOrder.before(.authentication)
        XCTAssertEqual(beforeAuth, 99)
        
        // Test after helper
        let afterLogging = MiddlewareOrder.after(.logging)
        XCTAssertEqual(afterLogging, 501)
    }
    
    func testAllCasesCompleteness() {
        // Verify all cases are included
        let allCases = MiddlewareOrder.allCases
        
        // Check we have the expected number of cases
        XCTAssertEqual(allCases.count, 51) // Count all the cases we defined
        
        // Verify no duplicates
        let uniqueCases = Set(allCases)
        XCTAssertEqual(uniqueCases.count, allCases.count)
        
        // Verify all categories have at least one middleware
        for category in MiddlewareCategory.allCases {
            let middlewareInCategory = MiddlewareOrder.category(category)
            XCTAssertFalse(middlewareInCategory.isEmpty, "Category \(category) should have middleware")
        }
    }
    
    func testMiddlewareOrderBuilder() {
        var builder = MiddlewareOrderBuilder()
        
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
            let order: MiddlewareOrder
            let tracker: TestActor<[MiddlewareOrder]>
            
            func execute<T: Command>(
                _ command: T,
                metadata: CommandMetadata,
                next: @Sendable (T, CommandMetadata) async throws -> T.Result
            ) async throws -> T.Result {
                await tracker.append(order)
                return try await next(command, metadata)
            }
        }
        
        let tracker = TestActor<[MiddlewareOrder]>([])
        let pipeline = PriorityPipeline(handler: TestHandler())
        
        // Add middleware in non-sequential order
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: MiddlewareOrder.logging, tracker: tracker),
            priority: MiddlewareOrder.logging.rawValue
        )
        
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: MiddlewareOrder.authentication, tracker: tracker),
            priority: MiddlewareOrder.authentication.rawValue
        )
        
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: MiddlewareOrder.validation, tracker: tracker),
            priority: MiddlewareOrder.validation.rawValue
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
    
    func append(_ element: MiddlewareOrder) where T == [MiddlewareOrder] {
        value.append(element)
    }
}