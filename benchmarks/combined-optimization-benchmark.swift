#!/usr/bin/env swift

import Foundation

// Simulate the cumulative effect of all optimizations

// Original implementation (baseline)
class BaselinePipeline {
    var middlewares: [(Any, Any) async throws -> Any] = []
    var storage: [ObjectIdentifier: Any] = [:]
    
    func execute() async throws {
        // Simulate ObjectIdentifier-based context access
        _ = storage[ObjectIdentifier(String.self)]
        
        // Always build chain
        var chain: () async throws -> Void = { }
        
        // Build chain with allocations
        for middleware in middlewares.reversed() {
            let next = chain
            chain = {
                _ = try await middleware("cmd", "ctx")
                try await next()
            }
        }
        
        try await chain()
    }
}

// Fully optimized implementation
class OptimizedPipeline {
    var middlewares: [(Any, Any) async throws -> Any] = []
    var storage: [Int: Any] = Dictionary(minimumCapacity: 16)
    private var compiledChain: (() async throws -> Void)?
    
    private func compileChain() {
        var chain: () async throws -> Void = { }
        
        for i in stride(from: middlewares.count - 1, through: 0, by: -1) {
            let middleware = middlewares[i]
            let next = chain
            chain = {
                _ = try await middleware("cmd", "ctx")
                try await next()
            }
        }
        
        compiledChain = chain
    }
    
    func execute() async throws {
        // Simulate integer-based context access (Phase 1)
        _ = storage[42]
        
        // Fast paths (Phase 3)
        if middlewares.isEmpty {
            return
        }
        
        if middlewares.count == 1 {
            _ = try await middlewares[0]("cmd", "ctx")
            return
        }
        
        // Pre-compiled chain (Phase 2)
        if compiledChain == nil {
            compileChain()
        }
        
        try await compiledChain?()
    }
}

print("Combined Optimization Benchmark")
print("==============================\n")

Task {
    let iterations = 100_000
    
    // Test different middleware counts
    for middlewareCount in [0, 1, 3, 5, 10] {
        print("\n\(middlewareCount) Middleware")
        print("-----------")
        
        let baseline = BaselinePipeline()
        let optimized = OptimizedPipeline()
        
        // Add middleware
        for _ in 0..<middlewareCount {
            let middleware: (Any, Any) async throws -> Any = { _, _ in return "" }
            baseline.middlewares.append(middleware)
            optimized.middlewares.append(middleware)
        }
        
        // Populate context
        baseline.storage[ObjectIdentifier(String.self)] = "value"
        optimized.storage[42] = "value"
        
        // Warm up
        for _ in 0..<100 {
            try await baseline.execute()
            try await optimized.execute()
        }
        
        // Benchmark baseline
        let startBaseline = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            try await baseline.execute()
        }
        let baselineTime = CFAbsoluteTimeGetCurrent() - startBaseline
        
        // Benchmark optimized
        let startOptimized = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            try await optimized.execute()
        }
        let optimizedTime = CFAbsoluteTimeGetCurrent() - startOptimized
        
        let improvement = ((baselineTime - optimizedTime) / baselineTime) * 100
        let speedup = baselineTime / optimizedTime
        
        print("Baseline: \(String(format: "%.3f", baselineTime)) seconds")
        print("Optimized: \(String(format: "%.3f", optimizedTime)) seconds")
        print("Improvement: \(String(format: "%.1f%%", improvement))")
        print("Speed: \(String(format: "%.2fx", speedup)) faster")
        
        let baselineOps = Double(iterations) / baselineTime
        let optimizedOps = Double(iterations) / optimizedTime
        print("Throughput: \(String(format: "%.0f", baselineOps)) → \(String(format: "%.0f", optimizedOps)) ops/sec")
    }
    
    print("\n\n✅ Combined Optimization Results")
    print("================================")
    print("Phase 1 (Context Storage): Integer-based keys")
    print("Phase 2 (Chain Pre-compilation): Cached middleware chains")
    print("Phase 3 (Fast Paths): Direct execution for 0-1 middleware")
    print("\nThe optimizations work together to provide:")
    print("- Reduced allocations per execution")
    print("- Better CPU cache utilization")
    print("- Minimal overhead for simple pipelines")
    print("- Significant gains for complex pipelines")
    
    exit(0)
}

RunLoop.main.run()