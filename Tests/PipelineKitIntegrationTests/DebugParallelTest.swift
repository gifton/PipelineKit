import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class DebugParallelTest: XCTestCase {
    // Define context key outside of function
    private struct DebugTestKey: ContextKey {
        typealias Value = String
    }
    
    func testDebugParallelExecution() async throws {
        print("Starting test...")
        
        // Create a middleware that modifies context like the failing test
        struct ContextSettingMiddleware: Middleware {
            let key: String
            let value: String
            let priority = ExecutionPriority.custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                print("ContextSettingMiddleware executing for key: \(key)")
                
                // Set value in context
                context.set("\(key):\(value)", for: DebugTestKey.self)
                
                // Don't call next for side effects - throw the expected error
                print("About to throw middlewareShouldNotCallNext for key: \(key)")
                throw ParallelExecutionError.middlewareShouldNotCallNext
            }
        }
        
        // Test with multiple middleware
        let wrapper = ParallelMiddlewareWrapper(
            middlewares: [
                ContextSettingMiddleware(key: "MW1", value: "value1"),
                ContextSettingMiddleware(key: "MW2", value: "value2"),
                ContextSettingMiddleware(key: "MW3", value: "value3")
            ],
            strategy: .sideEffectsWithMerge
        )
        
        let command = MockCommand(value: 42)
        let context = CommandContext()
        
        do {
            let result = try await wrapper.execute(command, context: context) { _, _ in
                print("Next handler called")
                return "Success"
            }
            print("Result: \(result)")
        } catch {
            print("Error caught: \(error)")
            throw error
        }
    }
}
