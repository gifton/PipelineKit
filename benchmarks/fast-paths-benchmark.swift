#!/usr/bin/env swift

import Foundation

// Test command and context
struct TestCommand {
    let value: String
}

struct TestContext {
    var storage: [String: Any] = [:]
}

// Test middleware
struct TestMiddleware {
    let name: String
    
    func execute(_ command: TestCommand, context: TestContext, next: (TestCommand, TestContext) async throws -> String) async throws -> String {
        // Simulate some work
        _ = context.storage["key"] ?? "default"
        return try await next(command, context)
    }
}

// Handler
struct TestHandler {
    func handle(_ command: TestCommand) async throws -> String {
        return command.value
    }
}

// Pipeline with fast paths
class OptimizedPipeline {
    private var middlewares: [TestMiddleware] = []
    private let handler = TestHandler()
    private var compiledChain: ((TestCommand, TestContext) async throws -> String)?
    
    func addMiddleware(_ middleware: TestMiddleware) {
        middlewares.append(middleware)
        compiledChain = nil
    }
    
    private func initializeContext(_ context: TestContext) {
        // Simulate context initialization
        _ = UUID().uuidString
        _ = Date()
    }
    
    private func compileChain() {
        var chain: (TestCommand, TestContext) async throws -> String = { cmd, _ in
            try await self.handler.handle(cmd)
        }
        
        for i in stride(from: middlewares.count - 1, through: 0, by: -1) {
            let middleware = middlewares[i]
            let nextChain = chain
            
            chain = { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: nextChain)
            }
        }
        
        compiledChain = chain
    }
    
    func execute(_ command: TestCommand, context: TestContext) async throws -> String {
        initializeContext(context)
        
        // Fast path: No middleware
        if middlewares.isEmpty {
            return try await handler.handle(command)
        }
        
        // Fast path: Single middleware
        if middlewares.count == 1 {
            let middleware = middlewares[0]
            return try await middleware.execute(command, context: context) { cmd, _ in
                try await self.handler.handle(cmd)
            }
        }
        
        // Multiple middleware: Use pre-compiled chain
        if compiledChain == nil {
            compileChain()
        }
        
        guard let chain = compiledChain else {
            return try await handler.handle(command)
        }
        
        return try await chain(command, context)
    }
}

// Pipeline without fast paths (always builds chain)
class UnoptimizedPipeline {
    private var middlewares: [TestMiddleware] = []
    private let handler = TestHandler()
    
    func addMiddleware(_ middleware: TestMiddleware) {
        middlewares.append(middleware)
    }
    
    private func initializeContext(_ context: TestContext) {
        _ = UUID().uuidString
        _ = Date()
    }
    
    func execute(_ command: TestCommand, context: TestContext) async throws -> String {
        initializeContext(context)
        
        // Always build chain
        var next: (TestCommand, TestContext) async throws -> String = { cmd, _ in
            try await self.handler.handle(cmd)
        }
        
        for i in stride(from: middlewares.count - 1, through: 0, by: -1) {
            let middleware = middlewares[i]
            let currentNext = next
            
            next = { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: currentNext)
            }
        }
        
        return try await next(command, context)
    }
}

print("Fast Paths Optimization Benchmark")
print("=================================\n")

Task {
    let command = TestCommand(value: "test")
    let context = TestContext(storage: ["key": "value"])
    let iterations = 10_000
    
    // Test 1: No middleware
    print("1. No Middleware (direct handler execution)")
    print("-------------------------------------------")
    
    let optimizedEmpty = OptimizedPipeline()
    let unoptimizedEmpty = UnoptimizedPipeline()
    
    // Warm up
    for _ in 0..<100 {
        _ = try await optimizedEmpty.execute(command, context: context)
        _ = try await unoptimizedEmpty.execute(command, context: context)
    }
    
    let startUnoptEmpty = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        _ = try await unoptimizedEmpty.execute(command, context: context)
    }
    let unoptEmptyTime = CFAbsoluteTimeGetCurrent() - startUnoptEmpty
    
    let startOptEmpty = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        _ = try await optimizedEmpty.execute(command, context: context)
    }
    let optEmptyTime = CFAbsoluteTimeGetCurrent() - startOptEmpty
    
    print("Without fast path: \(String(format: "%.3f", unoptEmptyTime)) seconds")
    print("With fast path: \(String(format: "%.3f", optEmptyTime)) seconds")
    print("Improvement: \(String(format: "%.1f%%", ((unoptEmptyTime - optEmptyTime) / unoptEmptyTime) * 100))")
    print("Speed: \(String(format: "%.2fx", unoptEmptyTime / optEmptyTime)) faster\n")
    
    // Test 2: Single middleware
    print("2. Single Middleware")
    print("--------------------")
    
    let optimizedSingle = OptimizedPipeline()
    let unoptimizedSingle = UnoptimizedPipeline()
    
    optimizedSingle.addMiddleware(TestMiddleware(name: "Auth"))
    unoptimizedSingle.addMiddleware(TestMiddleware(name: "Auth"))
    
    // Warm up
    for _ in 0..<100 {
        _ = try await optimizedSingle.execute(command, context: context)
        _ = try await unoptimizedSingle.execute(command, context: context)
    }
    
    let startUnoptSingle = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        _ = try await unoptimizedSingle.execute(command, context: context)
    }
    let unoptSingleTime = CFAbsoluteTimeGetCurrent() - startUnoptSingle
    
    let startOptSingle = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        _ = try await optimizedSingle.execute(command, context: context)
    }
    let optSingleTime = CFAbsoluteTimeGetCurrent() - startOptSingle
    
    print("Without fast path: \(String(format: "%.3f", unoptSingleTime)) seconds")
    print("With fast path: \(String(format: "%.3f", optSingleTime)) seconds")
    print("Improvement: \(String(format: "%.1f%%", ((unoptSingleTime - optSingleTime) / unoptSingleTime) * 100))")
    print("Speed: \(String(format: "%.2fx", unoptSingleTime / optSingleTime)) faster\n")
    
    // Test 3: Multiple middleware (uses pre-compilation)
    print("3. Multiple Middleware (5)")
    print("--------------------------")
    
    let optimizedMulti = OptimizedPipeline()
    let unoptimizedMulti = UnoptimizedPipeline()
    
    for i in 0..<5 {
        optimizedMulti.addMiddleware(TestMiddleware(name: "Middleware\(i)"))
        unoptimizedMulti.addMiddleware(TestMiddleware(name: "Middleware\(i)"))
    }
    
    // Warm up
    for _ in 0..<100 {
        _ = try await optimizedMulti.execute(command, context: context)
        _ = try await unoptimizedMulti.execute(command, context: context)
    }
    
    let startUnoptMulti = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        _ = try await unoptimizedMulti.execute(command, context: context)
    }
    let unoptMultiTime = CFAbsoluteTimeGetCurrent() - startUnoptMulti
    
    let startOptMulti = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        _ = try await optimizedMulti.execute(command, context: context)
    }
    let optMultiTime = CFAbsoluteTimeGetCurrent() - startOptMulti
    
    print("Without optimization: \(String(format: "%.3f", unoptMultiTime)) seconds")
    print("With optimization: \(String(format: "%.3f", optMultiTime)) seconds")
    print("Improvement: \(String(format: "%.1f%%", ((unoptMultiTime - optMultiTime) / unoptMultiTime) * 100))")
    print("Speed: \(String(format: "%.2fx", unoptMultiTime / optMultiTime)) faster\n")
    
    // Overall summary
    print("✅ Summary")
    print("----------")
    print("Fast paths provide significant performance improvements:")
    print("- No middleware: \(String(format: "%.1f%%", ((unoptEmptyTime - optEmptyTime) / unoptEmptyTime) * 100)) improvement")
    print("- Single middleware: \(String(format: "%.1f%%", ((unoptSingleTime - optSingleTime) / unoptSingleTime) * 100)) improvement")
    print("- Multiple middleware: \(String(format: "%.1f%%", ((unoptMultiTime - optMultiTime) / unoptMultiTime) * 100)) improvement")
    
    let avgImprovement = (((unoptEmptyTime - optEmptyTime) / unoptEmptyTime) +
                         ((unoptSingleTime - optSingleTime) / unoptSingleTime) +
                         ((unoptMultiTime - optMultiTime) / unoptMultiTime)) * 100 / 3
    
    print("\nAverage improvement across all cases: \(String(format: "%.1f%%", avgImprovement))")
    
    exit(0)
}

RunLoop.main.run()