import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class CommandContextForkTests: XCTestCase {
    // MARK: - Test Keys
    
    private struct TestKey: ContextKey {
        typealias Value = String
    }
    
    private struct CounterKey: ContextKey {
        typealias Value = Int
    }
    
    @available(*, deprecated, message: "Test-only key with non-Sendable value type")
    private struct DataKey: ContextKey {
        typealias Value = [String: Any]
    }
    
    // MARK: - Fork Tests
    
    func testContextForkCreatesIndependentCopy() {
        // Given
        let original = CommandContext()
        original.set("original", for: TestKey.self)
        original.set(42, for: CounterKey.self)
        
        // When
        let forked = original.fork()
        
        // Then - Forked has same values
        XCTAssertEqual(forked.get(TestKey.self), "original")
        XCTAssertEqual(forked.get(CounterKey.self), 42)
        
        // When - Modify forked
        forked.set("forked", for: TestKey.self)
        forked.set(99, for: CounterKey.self)
        
        // Then - Original unchanged
        XCTAssertEqual(original.get(TestKey.self), "original")
        XCTAssertEqual(original.get(CounterKey.self), 42)
        
        // And - Forked has new values
        XCTAssertEqual(forked.get(TestKey.self), "forked")
        XCTAssertEqual(forked.get(CounterKey.self), 99)
    }
    
    func testContextForkSharesMetadata() {
        // Given
        let metadata = StandardCommandMetadata(userId: "test-user")
        let original = CommandContext(metadata: metadata)
        
        // When
        let forked = original.fork()
        
        // Then - Both have same metadata
        XCTAssertEqual(original.commandMetadata.userId, "test-user")
        XCTAssertEqual(forked.commandMetadata.userId, "test-user")
        // Note: CommandMetadata is a protocol, not necessarily a class, so we can't use ===
    }
    
    // MARK: - Merge Tests
    
    func testContextMergeUpdatesValues() {
        // Given
        let context1 = CommandContext()
        context1.set("value1", for: TestKey.self)
        context1.set(10, for: CounterKey.self)
        
        let context2 = CommandContext()
        context2.set("value2", for: TestKey.self)
        context2.set(["key": "value"], for: DataKey.self)
        
        // When
        context1.merge(from: context2)
        
        // Then
        XCTAssertEqual(context1.get(TestKey.self), "value2") // Overwritten
        XCTAssertEqual(context1.get(CounterKey.self), 10) // Unchanged
        XCTAssertEqual(context1.get(DataKey.self)?["key"] as? String, "value") // Added
    }
    
    func testContextMergeDoesNotAffectSource() {
        // Given
        let source = CommandContext()
        source.set("source", for: TestKey.self)
        
        let target = CommandContext()
        target.set("target", for: TestKey.self)
        
        // When
        target.merge(from: source)
        
        // Then
        XCTAssertEqual(source.get(TestKey.self), "source") // Source unchanged
        XCTAssertEqual(target.get(TestKey.self), "source") // Target updated
    }
    
    // MARK: - Parallel Execution Tests
    
    func testParallelContextModificationWithForking() async {
        // Given
        let original = CommandContext()
        original.set(0, for: CounterKey.self)
        
        // When - Parallel modifications on forked contexts
        await withTaskGroup(of: Void.self) { group in
            for i in 1...100 {
                group.addTask {
                    let forked = original.fork()
                    let current = forked.get(CounterKey.self) ?? 0
                    forked.set(current + i, for: CounterKey.self)
                    // Forked context is discarded - no race condition
                }
            }
        }
        
        // Then - Original unchanged
        XCTAssertEqual(original.get(CounterKey.self), 0)
    }
    
    func testParallelMiddlewareWithContextForking() async throws {
        // Given
        let handler = MockCommandHandler()
        
        // Create middleware that modifies context
        let middleware1 = ContextModifyingMiddleware(key: "MW1", value: "value1")
        let middleware2 = ContextModifyingMiddleware(key: "MW2", value: "value2")
        let middleware3 = ContextModifyingMiddleware(key: "MW3", value: "value3")
        
        // Create parallel wrapper
        let parallelWrapper = ParallelMiddlewareWrapper(
            middlewares: [middleware1, middleware2, middleware3],
            strategy: .sideEffectsWithMerge
        )
        
        let pipeline = try await PipelineBuilder(handler: handler)
            .with(parallelWrapper)
            .build()
        
        let command = MockCommand(value: 42)
        let context = CommandContext()
        
        // When
        _ = try await pipeline.execute(command, context: context)
        
        // Then - All middleware changes are merged
        XCTAssertEqual(context.get(MW1Key.self), "value1")
        XCTAssertEqual(context.get(MW2Key.self), "value2")
        XCTAssertEqual(context.get(MW3Key.self), "value3")
    }
}

// MARK: - Test Middleware

// Context keys for each middleware
private struct MW1Key: ContextKey {
    typealias Value = String
}

private struct MW2Key: ContextKey {
    typealias Value = String
}

private struct MW3Key: ContextKey {
    typealias Value = String
}

private struct ContextModifyingMiddleware: Middleware {
    let key: String
    let value: String
    let priority = ExecutionPriority.custom
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Set value in context based on key name
        switch key {
        case "MW1":
            context.set(value, for: MW1Key.self)
        case "MW2":
            context.set(value, for: MW2Key.self)
        case "MW3":
            context.set(value, for: MW3Key.self)
        default:
            fatalError("Unknown key: \(key)")
        }
        
        // Don't call next for side effects
        throw ParallelExecutionError.middlewareShouldNotCallNext
    }
}
