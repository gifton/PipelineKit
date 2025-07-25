import Foundation
import PipelineKit
import PipelineKitTests

// Test to measure the actual performance of PreCompiledPipeline
@main
struct TestOptimizedPerformance {
    static func main() async throws {
        let handler = MockCommandHandler()
        let middleware: [any Middleware] = [
            MockAuthenticationMiddleware(),
            MockValidationMiddleware(),
            MockLoggingMiddleware(),
            MockMetricsMiddleware()
        ]
        
        // Create both pipelines
        let standardPipeline = try await PipelineBuilder(handler: handler)
            .with(middleware)
            .build()
        
        let optimizedPipeline = try await PipelineBuilder(handler: handler)
            .with(middleware)
            .buildOptimized()
        
        let command = MockCommand(value: 42)
        let context = CommandContext(metadata: StandardCommandMetadata(userId: "test"))
        
        // Warm up
        print("Warming up...")
        for _ in 0..<100 {
            _ = try await standardPipeline.execute(command, context: context)
            _ = try await optimizedPipeline.execute(command, context: context)
        }
        
        // Run multiple test iterations
        var standardTimes: [Double] = []
        var optimizedTimes: [Double] = []
        
        for iteration in 1...5 {
            print("\nIteration \(iteration):")
            
            // Measure standard pipeline
            let standardStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<10000 {
                _ = try await standardPipeline.execute(command, context: context)
            }
            let standardTime = CFAbsoluteTimeGetCurrent() - standardStart
            standardTimes.append(standardTime)
            
            // Measure optimized pipeline
            let optimizedStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<10000 {
                _ = try await optimizedPipeline.execute(command, context: context)
            }
            let optimizedTime = CFAbsoluteTimeGetCurrent() - optimizedStart
            optimizedTimes.append(optimizedTime)
            
            let improvement = ((standardTime - optimizedTime) / standardTime) * 100
            print("  Standard:  \(String(format: "%.3f", standardTime))s")
            print("  Optimized: \(String(format: "%.3f", optimizedTime))s")
            print("  Improvement: \(String(format: "%.1f", improvement))%")
        }
        
        // Calculate averages
        let avgStandard = standardTimes.reduce(0, +) / Double(standardTimes.count)
        let avgOptimized = optimizedTimes.reduce(0, +) / Double(optimizedTimes.count)
        let avgImprovement = ((avgStandard - avgOptimized) / avgStandard) * 100
        
        print("\nAverage Results:")
        print("  Standard:  \(String(format: "%.3f", avgStandard))s")
        print("  Optimized: \(String(format: "%.3f", avgOptimized))s")
        print("  Average Improvement: \(String(format: "%.1f", avgImprovement))%")
        
        // Test with different middleware counts
        print("\n\nTesting with different middleware counts:")
        
        for count in [1, 2, 4, 8, 16] {
            let testMiddleware = (0..<count).map { _ in MockLoggingMiddleware() }
            
            let stdPipeline = try await PipelineBuilder(handler: handler)
                .with(testMiddleware)
                .build()
            
            let optPipeline = try await PipelineBuilder(handler: handler)
                .with(testMiddleware)
                .buildOptimized()
            
            // Warm up
            for _ in 0..<10 {
                _ = try await stdPipeline.execute(command, context: context)
                _ = try await optPipeline.execute(command, context: context)
            }
            
            // Measure
            let stdStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5000 {
                _ = try await stdPipeline.execute(command, context: context)
            }
            let stdTime = CFAbsoluteTimeGetCurrent() - stdStart
            
            let optStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5000 {
                _ = try await optPipeline.execute(command, context: context)
            }
            let optTime = CFAbsoluteTimeGetCurrent() - optStart
            
            let improvement = ((stdTime - optTime) / stdTime) * 100
            print("\n\(count) middleware:")
            print("  Standard:  \(String(format: "%.3f", stdTime))s")
            print("  Optimized: \(String(format: "%.3f", optTime))s")
            print("  Improvement: \(String(format: "%.1f", improvement))%")
        }
        
        // Check optimization stats
        if let stats = optimizedPipeline.getOptimizationStats() {
            print("\n\nOptimization Statistics:")
            print("  Middleware count: \(stats.middlewareCount)")
            print("  Optimizations applied: \(stats.optimizationsApplied)")
            print("  Applied: \(stats.appliedOptimizations)")
            print("  Estimated improvement: \(stats.estimatedImprovement)%")
        }
    }
}