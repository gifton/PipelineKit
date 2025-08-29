import PackagePlugin
import Foundation

@main
struct TestUnitCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        // Get the swift executable URL
        let swiftExec = try context.tool(named: "swift").url
        
        // Print header
        print("🧪 Running Unit Tests")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        
        // Build arguments for swift test - run all unit tests except integration
        var args = ["test", "--filter", "PipelineKitCoreTests|PipelineKitTests|PipelineKitSecurityTests|PipelineKitResilienceTests|PipelineKitCacheTests|PipelineKitPoolingTests|PipelineKitObservabilityTests"]
        
        // Add parallel flag unless explicitly disabled
        if !arguments.contains("--disable-parallel") {
            args.append("--parallel")
        }
        
        // Add any other arguments passed to the plugin
        args.append(contentsOf: arguments.filter { $0 != "--disable-parallel" })
        
        // Create and run the process
        let process = Process()
        process.executableURL = swiftExec
        process.arguments = args
        process.currentDirectoryURL = context.package.directoryURL
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                print("\n✅ Unit tests passed!")
            } else {
                print("\n❌ Unit tests failed with exit code: \(process.terminationStatus)")
                throw PluginError.testsFailed(exitCode: process.terminationStatus)
            }
        } catch let error as PluginError {
            throw error
        } catch {
            print("\n❌ Failed to run tests: \(error)")
            throw PluginError.processLaunchFailed(error)
        }
    }
}

enum PluginError: Error, CustomStringConvertible {
    case testsFailed(exitCode: Int32)
    case processLaunchFailed(Error)
    
    var description: String {
        switch self {
        case .testsFailed(let exitCode):
            return "Tests failed with exit code \(exitCode)"
        case .processLaunchFailed(let error):
            return "Failed to launch test process: \(error)"
        }
    }
}