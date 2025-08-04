import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class ExecutionPriorityTests: XCTestCase {
    
    func testExecutionPriorityValues() {
        // Verify the simplified priorities are properly ordered
        XCTAssertEqual(ExecutionPriority.authentication.rawValue, 100)
        XCTAssertEqual(ExecutionPriority.validation.rawValue, 200)
        XCTAssertEqual(ExecutionPriority.preProcessing.rawValue, 300)
        XCTAssertEqual(ExecutionPriority.processing.rawValue, 400)
        XCTAssertEqual(ExecutionPriority.postProcessing.rawValue, 500)
        XCTAssertEqual(ExecutionPriority.errorHandling.rawValue, 600)
        XCTAssertEqual(ExecutionPriority.custom.rawValue, 1000)
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
        let pipeline = AnyStandardPipeline(handler: TestHandler())
        
        // Add middleware in non-sequential order
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: ExecutionPriority.postProcessing, tracker: tracker)
        )
        
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: ExecutionPriority.authentication, tracker: tracker)
        )
        
        try await pipeline.addMiddleware(
            OrderTrackingMiddleware(order: ExecutionPriority.validation, tracker: tracker)
        )
        
        let context = CommandContext.test()
        _ = try await pipeline.execute(TestCommand(), context: context)
        
        let executionOrder = await tracker.get()
        
        // Verify execution order matches priority order
        // Lower priority values execute first (higher priority)
        XCTAssertEqual(executionOrder, [.authentication, .validation, .postProcessing])
    }
}
