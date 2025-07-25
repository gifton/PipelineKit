import Foundation
import PipelineKit
@testable import PipelineKitTests

// Minimal test to identify PreCompiledPipeline performance regression
@main
struct TestPreCompiledRegression {
    static func main() async throws {
        let handler = MockCommandHandler()
        let command = MockCommand(value: 42)
        
        // Test with different middleware counts
        for middlewareCount in [0, 1, 2, 3, 4, 8] {
            print("\n=== Testing with \(middlewareCount) middleware ===")
            
            let middleware: [any Middleware] = (0..<middlewareCount).map { _ in 
                MockLoggingMiddleware()
            }
            
            // Test 1: StandardPipeline
            let standardPipeline = StandardPipeline(handler: handler, useContextPool: false)
            for mw in middleware {
                try await standardPipeline.addMiddleware(mw)
            }
            
            // Test 2: PreCompiledPipeline (current version with all optimizations)
            let preCompiledPipeline = PreCompiledPipeline(
                handler: handler,
                middleware: middleware,
                options: PipelineOptions()
            )
            
            // Test 3: Simpler PreCompiledPipeline (no context pool)
            let simplePreCompiled = PreCompiledPipelineSimple(
                handler: handler,
                middleware: middleware
            )
            
            // Create contexts without pooling
            let iterations = 10000
            
            // Warm up
            for _ in 0..<100 {
                let ctx = CommandContext(metadata: StandardCommandMetadata())
                _ = try await standardPipeline.execute(command, context: ctx)
                _ = try await preCompiledPipeline.execute(command, context: ctx)
                _ = try await simplePreCompiled.execute(command, context: ctx)
            }
            
            // Measure StandardPipeline
            let stdStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iterations {
                let ctx = CommandContext(metadata: StandardCommandMetadata())
                _ = try await standardPipeline.execute(command, context: ctx)
            }
            let stdTime = CFAbsoluteTimeGetCurrent() - stdStart
            
            // Measure PreCompiledPipeline
            let optStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iterations {
                let ctx = CommandContext(metadata: StandardCommandMetadata())
                _ = try await preCompiledPipeline.execute(command, context: ctx)
            }
            let optTime = CFAbsoluteTimeGetCurrent() - optStart
            
            // Measure Simple PreCompiled
            let simpleStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iterations {
                let ctx = CommandContext(metadata: StandardCommandMetadata())
                _ = try await simplePreCompiled.execute(command, context: ctx)
            }
            let simpleTime = CFAbsoluteTimeGetCurrent() - simpleStart
            
            // Calculate performance differences
            let optRegression = ((optTime - stdTime) / stdTime) * 100
            let simpleRegression = ((simpleTime - stdTime) / stdTime) * 100
            
            print("StandardPipeline:      \(String(format: "%.3f", stdTime))s (baseline)")
            print("PreCompiledPipeline:   \(String(format: "%.3f", optTime))s (\(String(format: "%+.1f", optRegression))%)")
            print("SimplePreCompiled:     \(String(format: "%.3f", simpleTime))s (\(String(format: "%+.1f", simpleRegression))%)")
            
            // Test context pooling overhead separately
            if middlewareCount == 4 {
                print("\n--- Testing context pooling overhead ---")
                
                // Clear pool first
                CommandContextPool.shared.clear()
                
                // Test with pooling
                let poolStart = CFAbsoluteTimeGetCurrent()
                for _ in 0..<iterations {
                    _ = try await preCompiledPipeline.execute(command, metadata: StandardCommandMetadata())
                }
                let poolTime = CFAbsoluteTimeGetCurrent() - poolStart
                
                let poolOverhead = ((poolTime - optTime) / optTime) * 100
                print("With context pooling:  \(String(format: "%.3f", poolTime))s (\(String(format: "%+.1f", poolOverhead))% vs without)")
                
                // Get pool statistics
                let stats = CommandContextPool.shared.getStatistics()
                print("Pool stats: hit rate=\(String(format: "%.1f%%", stats.hitRate * 100)), available=\(stats.currentlyAvailable), in use=\(stats.currentlyInUse)")
            }
        }
        
        // Test specific optimization features
        print("\n\n=== Testing specific optimizations ===")
        
        // Test inlining for small chains
        print("\nTesting inlining (1-3 middleware):")
        for count in 1...3 {
            let mw = (0..<count).map { _ in MockLoggingMiddleware() }
            let pipeline = PreCompiledPipeline(handler: handler, middleware: mw)
            
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<10000 {
                let ctx = CommandContext(metadata: StandardCommandMetadata())
                _ = try await pipeline.execute(command, context: ctx)
            }
            let time = CFAbsoluteTimeGetCurrent() - start
            print("\(count) middleware: \(String(format: "%.3f", time))s")
        }
    }
}

// Simplified PreCompiledPipeline without extra features
final class PreCompiledPipelineSimple<H: CommandHandler>: Pipeline {
    private let handler: H
    private let executionFunc: @Sendable (H.CommandType, CommandContext) async throws -> H.CommandType.Result
    
    init(handler: H, middleware: [any Middleware]) {
        self.handler = handler
        
        // Build execution chain once
        if middleware.isEmpty {
            self.executionFunc = { command, _ in
                try await handler.handle(command)
            }
        } else {
            var next: @Sendable (H.CommandType, CommandContext) async throws -> H.CommandType.Result = { cmd, _ in
                try await handler.handle(cmd)
            }
            
            for mw in middleware.reversed() {
                let previousNext = next
                next = { cmd, ctx in
                    try await mw.execute(cmd, context: ctx, next: previousNext)
                }
            }
            
            self.executionFunc = next
        }
    }
    
    func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        guard let typedCommand = command as? H.CommandType else {
            throw PipelineErrorType.invalidCommandType
        }
        let result = try await executionFunc(typedCommand, context)
        return result as! T.Result
    }
}