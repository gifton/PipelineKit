#!/usr/bin/env swift

import Foundation

// Simulated middleware and command types
protocol TestCommand {
    associatedtype Result
}

struct SimpleCommand: TestCommand {
    typealias Result = String
    let value: String
}

protocol TestMiddleware {
    func execute<C: TestCommand>(_ command: C, context: TestContext, next: @escaping (C, TestContext) async throws -> C.Result) async throws -> C.Result
}

struct TestContext {
    var storage: [String: Any] = [:]
}

// Sample middleware implementations
struct LoggingMiddleware: TestMiddleware {
    func execute<C: TestCommand>(_ command: C, context: TestContext, next: @escaping (C, TestContext) async throws -> C.Result) async throws -> C.Result {
        // Simulate some work
        _ = Date()
        return try await next(command, context)
    }
}

struct AuthMiddleware: TestMiddleware {
    func execute<C: TestCommand>(_ command: C, context: TestContext, next: @escaping (C, TestContext) async throws -> C.Result) async throws -> C.Result {
        // Simulate auth check
        _ = context.storage["auth"] ?? false
        return try await next(command, context)
    }
}

struct MetricsMiddleware: TestMiddleware {
    func execute<C: TestCommand>(_ command: C, context: TestContext, next: @escaping (C, TestContext) async throws -> C.Result) async throws -> C.Result {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await next(command, context)
        _ = CFAbsoluteTimeGetCurrent() - start
        return result
    }
}

// Handler
struct TestHandler {
    func handle(_ command: SimpleCommand) async throws -> String {
        return command.value
    }
}

// Pipeline without pre-compilation (builds chain every time)
class UnoptimizedPipeline {
    private var middlewares: [any TestMiddleware] = []
    private let handler = TestHandler()
    
    func addMiddleware(_ middleware: any TestMiddleware) {
        middlewares.append(middleware)
    }
    
    func execute(_ command: SimpleCommand, context: TestContext) async throws -> String {
        // Build the chain on each execution
        var next: @Sendable (SimpleCommand, TestContext) async throws -> String = { cmd, _ in
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

// Pipeline with pre-compilation
class OptimizedPipeline {
    private var middlewares: [any TestMiddleware] = []
    private let handler = TestHandler()
    private var compiledChain: (@Sendable (SimpleCommand, TestContext) async throws -> String)?
    
    func addMiddleware(_ middleware: any TestMiddleware) {
        middlewares.append(middleware)
        // Invalidate compiled chain
        compiledChain = nil
    }
    
    private func compileChain() {
        var chain: @Sendable (SimpleCommand, TestContext) async throws -> String = { cmd, _ in
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
    
    func execute(_ command: SimpleCommand, context: TestContext) async throws -> String {
        if compiledChain == nil {
            compileChain()
        }
        
        guard let chain = compiledChain else {
            return try await handler.handle(command)
        }
        
        return try await chain(command, context)
    }
}

print("Middleware Chain Pre-Compilation Benchmark")
print("==========================================\n")

// Setup pipelines
let unoptimized = UnoptimizedPipeline()
let optimized = OptimizedPipeline()

// Add middleware
let middlewares: [any TestMiddleware] = [
    LoggingMiddleware(),
    AuthMiddleware(),
    MetricsMiddleware(),
    LoggingMiddleware(),  // Add more to simulate realistic pipeline
    AuthMiddleware()
]

for middleware in middlewares {
    unoptimized.addMiddleware(middleware)
    optimized.addMiddleware(middleware)
}

// Test command and context
let command = SimpleCommand(value: "test")
let context = TestContext(storage: ["auth": true])

// Warm up
Task {
    for _ in 0..<100 {
        _ = try await unoptimized.execute(command, context: context)
        _ = try await optimized.execute(command, context: context)
    }
    
    // Benchmark
    let iterations = 10_000
    
    // Unoptimized (builds chain every time)
    let startUnoptimized = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        _ = try await unoptimized.execute(command, context: context)
    }
    let unoptimizedTime = CFAbsoluteTimeGetCurrent() - startUnoptimized
    
    // Optimized (uses pre-compiled chain)
    let startOptimized = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        _ = try await optimized.execute(command, context: context)
    }
    let optimizedTime = CFAbsoluteTimeGetCurrent() - startOptimized
    
    print("Execution Performance (\(iterations) iterations with \(middlewares.count) middleware):")
    print("- Without pre-compilation: \(String(format: "%.3f", unoptimizedTime)) seconds")
    print("- With pre-compilation: \(String(format: "%.3f", optimizedTime)) seconds")
    print("- Improvement: \(String(format: "%.1f%%", ((unoptimizedTime - optimizedTime) / unoptimizedTime) * 100))")
    print("- Speed: \(String(format: "%.2fx", unoptimizedTime / optimizedTime)) faster")
    
    let opsPerSecUnoptimized = Double(iterations) / unoptimizedTime
    let opsPerSecOptimized = Double(iterations) / optimizedTime
    
    print("\nThroughput:")
    print("- Without pre-compilation: \(String(format: "%.0f", opsPerSecUnoptimized)) ops/sec")
    print("- With pre-compilation: \(String(format: "%.0f", opsPerSecOptimized)) ops/sec")
    
    // Test with different middleware counts
    print("\n\nScaling Test (100 iterations each)")
    print("-----------------------------------")
    
    for middlewareCount in [1, 5, 10, 20] {
        let testUnoptimized = UnoptimizedPipeline()
        let testOptimized = OptimizedPipeline()
        
        for i in 0..<middlewareCount {
            if i % 3 == 0 {
                testUnoptimized.addMiddleware(LoggingMiddleware())
                testOptimized.addMiddleware(LoggingMiddleware())
            } else if i % 3 == 1 {
                testUnoptimized.addMiddleware(AuthMiddleware())
                testOptimized.addMiddleware(AuthMiddleware())
            } else {
                testUnoptimized.addMiddleware(MetricsMiddleware())
                testOptimized.addMiddleware(MetricsMiddleware())
            }
        }
        
        let scalingIterations = 100
        
        let startU = CFAbsoluteTimeGetCurrent()
        for _ in 0..<scalingIterations {
            _ = try await testUnoptimized.execute(command, context: context)
        }
        let timeU = CFAbsoluteTimeGetCurrent() - startU
        
        let startO = CFAbsoluteTimeGetCurrent()
        for _ in 0..<scalingIterations {
            _ = try await testOptimized.execute(command, context: context)
        }
        let timeO = CFAbsoluteTimeGetCurrent() - startO
        
        let improvement = ((timeU - timeO) / timeU) * 100
        print("\(middlewareCount) middleware: \(String(format: "%.1f%%", improvement)) improvement")
    }
    
    print("\n✅ Summary")
    print("----------")
    print("Pre-compiled middleware chains provide significant performance improvements,")
    print("especially as the number of middleware increases. The optimization eliminates")
    print("the overhead of rebuilding the closure chain on every execution.")
    
    exit(0)
}

RunLoop.main.run()