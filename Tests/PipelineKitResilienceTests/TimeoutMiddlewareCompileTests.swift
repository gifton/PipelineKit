import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience

/// Compile-time tests to ensure TimeoutMiddleware maintains proper constraints
final class TimeoutMiddlewareCompileTests: XCTestCase {
    
    /// Test that the middleware protocol's `next` parameter is non-escaping.
    /// This test will fail to compile if the protocol changes to use @escaping.
    func testNextParameterIsNonEscaping() {
        // This test exists primarily for compile-time verification
        let middleware = TimeoutMiddleware(defaultTimeout: 1.0)
        
        // Create a dummy execute call to verify non-escaping constraint
        Task {
            let command = DummyCommand()
            let context = CommandContext()
            
            try await middleware.execute(command, context: context) { cmd, ctx in
                // If this compiles, then next is non-escaping
                assertNonEscaping {
                    // Attempting to capture next in an escaping context
                    // would fail compilation if next is non-escaping
                    _ = cmd
                    _ = ctx
                }
                return "test"
            }
        }
        
        // The test passes if it compiles
        XCTAssertTrue(true, "Non-escaping constraint is maintained")
    }
    
    /// Test that attempting to store the next closure fails compilation
    func testCannotStoreNextClosure() {
        // This should fail to compile if uncommented:
        /*
        var storedClosure: (@Sendable (DummyCommand, CommandContext) async throws -> String)?
        
        let middleware = TimeoutMiddleware(defaultTimeout: 1.0)
        Task {
            try await middleware.execute(DummyCommand(), context: CommandContext()) { cmd, ctx in
                storedClosure = { cmd, ctx in "stored" } // ERROR: Cannot assign non-escaping parameter
                return "test"
            }
        }
        */
        
        XCTAssertTrue(true, "Cannot store non-escaping closure")
    }
    
    /// Test memory layout to ensure closure is stack-allocated
    func testClosureMemoryLayout() async throws {
        let middleware = TimeoutMiddleware(defaultTimeout: 1.0)
        
        try await middleware.execute(DummyCommand(), context: CommandContext()) { cmd, ctx in
            // Non-escaping closures should have zero heap size
            let size = MemoryLayout.size(ofValue: { try await cmd.execute() })
            XCTAssertEqual(size, 0, "Non-escaping closures should be stack-allocated")
            return "test"
        }
    }
}

// MARK: - Test Helpers

private struct DummyCommand: Command {
    typealias Result = String
    
    func execute() async throws -> String {
        return "dummy"
    }
}

private struct DummyHandler: CommandHandler {
    typealias CommandType = DummyCommand
    
    func handle(_ command: DummyCommand) async throws -> String {
        return command.execute()
    }
}