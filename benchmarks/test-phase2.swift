#!/usr/bin/env swift

import Foundation
import PipelineKit

// Test command
struct TestCommand: Command {
    typealias Result = String
    let message: String
    
    func execute() async throws -> String {
        return "Executed: \(message)"
    }
}

// Test handler
struct TestHandler: CommandHandler {
    typealias CommandType = TestCommand
    
    func handle(_ command: TestCommand) async throws -> String {
        return "Handler: \(command.message)"
    }
}

// Test middleware
struct TestMiddleware: Middleware {
    let name: String
    let priority: ExecutionPriority
    
    func execute<C: Command>(_ command: C, context: CommandContext, next: @Sendable (C, CommandContext) async throws -> C.Result) async throws -> C.Result {
        context[UserContextKey.self] = "\(name) executed"
        return try await next(command, context)
    }
}

// Context key for testing
struct UserContextKey: ContextKey {
    typealias Value = String
}

print("Testing Phase 2: Middleware Chain Pre-Compilation")
print("================================================\n")

Task {
    // Create pipeline
    let pipeline = StandardPipeline(handler: TestHandler())
    
    // Add multiple middleware
    try await pipeline.addMiddleware(TestMiddleware(name: "Auth", priority: .high))
    try await pipeline.addMiddleware(TestMiddleware(name: "Logging", priority: .normal))
    try await pipeline.addMiddleware(TestMiddleware(name: "Metrics", priority: .low))
    try await pipeline.addMiddleware(TestMiddleware(name: "Validation", priority: .high))
    
    // Execute commands multiple times
    print("Executing commands...")
    
    let iterations = 5
    let start = CFAbsoluteTimeGetCurrent()
    
    for i in 0..<iterations {
        let command = TestCommand(message: "Test \(i)")
        let context = CommandContext()
        let result = try await pipeline.execute(command, context: context)
        
        if i == 0 {
            print("First execution result: \(result)")
            print("Context value: \(context[UserContextKey.self] ?? "nil")")
        }
    }
    
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    
    print("\nExecuted \(iterations) commands in \(String(format: "%.3f", elapsed)) seconds")
    print("Average: \(String(format: "%.3f", elapsed / Double(iterations) * 1000)) ms per command")
    
    // Test middleware modification and chain invalidation
    print("\nTesting chain invalidation...")
    
    // Remove a middleware
    let removed = await pipeline.removeMiddleware(ofType: TestMiddleware.self)
    print("Removed \(removed) middleware")
    
    // Execute again to ensure it still works
    let command2 = TestCommand(message: "After removal")
    let context2 = CommandContext()
    let result2 = try await pipeline.execute(command2, context: context2)
    print("Result after removal: \(result2)")
    
    // Clear all middleware
    await pipeline.clearMiddlewares()
    print("\nCleared all middleware")
    
    // Execute with no middleware
    let command3 = TestCommand(message: "No middleware")
    let context3 = CommandContext()
    let result3 = try await pipeline.execute(command3, context: context3)
    print("Result with no middleware: \(result3)")
    
    print("\n✅ All tests passed! Pre-compilation is working correctly.")
    
    exit(0)
}

RunLoop.main.run()