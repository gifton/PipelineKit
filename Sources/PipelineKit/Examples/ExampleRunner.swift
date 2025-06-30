import Foundation

/// Example runner that executes all PipelineKit examples to validate functionality
public struct ExampleRunner {
    
    /// Runs all examples and reports their status
    public static func runAllExamples() async {
        print("🚀 PipelineKit Example Runner")
        print("============================\n")
        
        var results: [(name: String, success: Bool, error: Error?)] = []
        
        // Run each example and track results
        
        // 1. Macro Examples
        print("📦 Running Macro Examples...")
        do {
            try await runUnifiedMacroExamples()
            results.append(("Macro Examples", true, nil))
            print("✅ Macro Examples completed successfully\n")
        } catch {
            results.append(("Macro Examples", false, error))
            print("❌ Macro Examples failed: \(error)\n")
        }
        
        // 2. Back Pressure Examples
        print("🔄 Running Back Pressure Examples...")
        do {
            try await BackPressureExample.suspendStrategyExample()
            try await BackPressureExample.dropOldestStrategyExample()
            try await BackPressureExample.errorStrategyExample()
            try await BackPressureExample.middlewareExample()
            try await BackPressureExample.monitoringExample()
            results.append(("Back Pressure Examples", true, nil))
            print("✅ Back Pressure Examples completed successfully\n")
        } catch {
            results.append(("Back Pressure Examples", false, error))
            print("❌ Back Pressure Examples failed: \(error)\n")
        }
        
        // 3. DSL Examples
        print("🛠️ Running DSL Examples...")
        do {
            try await DSLExamples.ecommerceOrderPipeline()
            try await DSLExamples.apiGatewayPipeline()
            results.append(("DSL Examples", true, nil))
            print("✅ DSL Examples completed successfully\n")
        } catch {
            results.append(("DSL Examples", false, error))
            print("❌ DSL Examples failed: \(error)\n")
        }
        
        // 4. Execution Priority Examples (documentation only)
        print("📋 Running Execution Priority Examples...")
        ExecutionPriorityExample.demonstrateMiddlewareCategories()
        ExecutionPriorityExample.demonstratePriorityHelpers()
        ExecutionPriorityExample.demonstrateMiddlewareStructure()
        results.append(("Execution Priority Examples", true, nil))
        print("✅ Execution Priority Examples completed successfully\n")
        
        // 5. Observer Examples
        print("👁️ Running Observer Examples...")
        do {
            try await ObserverExamples.consoleObserverExample()
            try await ObserverExamples.memoryObserverExample()
            try await ObserverExamples.metricsObserverExample()
            try await ObserverExamples.compositeObserverExample()
            try await ObserverExamples.conditionalObserverExample()
            try await ObserverExamples.productionSetupExample()
            try await ObserverExamples.observableCommandExample()
            results.append(("Observer Examples", true, nil))
            print("✅ Observer Examples completed successfully\n")
        } catch {
            results.append(("Observer Examples", false, error))
            print("❌ Observer Examples failed: \(error)\n")
        }
        
        // 6. Performance Examples
        print("⚡ Running Performance Examples...")
        await PerformanceExample.runConsoleLoggingExample()
        await PerformanceExample.runAggregatingCollectorExample()
        await PerformanceExample.runContextAccessExample()
        results.append(("Performance Examples", true, nil))
        print("✅ Performance Examples completed successfully\n")
        
        // 7. Security Examples
        print("🔒 Running Security Examples...")
        do {
            try await SecurityExample.demonstrateSecurePipeline()
            SecurityExample.demonstrateExecutionOrder()
            try await SecurityExample.advancedSecurityPipeline()
            results.append(("Security Examples", true, nil))
            print("✅ Security Examples completed successfully\n")
        } catch {
            results.append(("Security Examples", false, error))
            print("❌ Security Examples failed: \(error)\n")
        }
        
        // Summary
        print("\n📊 Example Runner Summary")
        print("========================")
        
        let successCount = results.filter { $0.success }.count
        let totalCount = results.count
        
        for result in results {
            let status = result.success ? "✅" : "❌"
            print("\(status) \(result.name)")
            if let error = result.error {
                print("   Error: \(error)")
            }
        }
        
        print("\nTotal: \(successCount)/\(totalCount) examples passed")
        
        if successCount == totalCount {
            print("\n🎉 All examples completed successfully!")
        } else {
            print("\n⚠️ Some examples failed. Please check the errors above.")
        }
    }
    
    /// Runs a specific example by name
    public static func runExample(named name: String) async throws {
        print("Running example: \(name)\n")
        
        switch name.lowercased() {
        case "macro":
            try await runUnifiedMacroExamples()
        case "backpressure":
            try await BackPressureExample.suspendStrategyExample()
        case "dsl":
            try await DSLExamples.ecommerceOrderPipeline()
        case "priority":
            ExecutionPriorityExample.demonstrateMiddlewareCategories()
        case "observer":
            try await ObserverExamples.consoleObserverExample()
        case "performance":
            await PerformanceExample.runConsoleLoggingExample()
        case "security":
            try await SecurityExample.demonstrateSecurePipeline()
        default:
            print("Unknown example: \(name)")
            print("Available examples: macro, backpressure, dsl, priority, observer, performance, security")
        }
    }
}

// MARK: - Main Entry Point

/// Command-line entry point for running examples
// @main  // Commented out to avoid conflict with test runner
// Note: In a production setup, this would be a separate executable target
// defined in Package.swift with its own main.swift file
struct ExampleRunnerCLI {
    static func main() async {
        let arguments = CommandLine.arguments
        
        if arguments.count > 1 {
            // Run specific example
            let exampleName = arguments[1]
            do {
                try await ExampleRunner.runExample(named: exampleName)
            } catch {
                print("Error running example '\(exampleName)': \(error)")
            }
        } else {
            // Run all examples
            await ExampleRunner.runAllExamples()
        }
    }
}
