import PackagePlugin
import Foundation

@main
struct TestStressTSANCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        // Get the swift executable URL
        let swiftExec = try context.tool(named: "swift").url
        
        // Print header
        print("🔍 Running Stress Tests with Thread Sanitizer")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        print("⚠️  Thread Sanitizer is enabled - tests will run slower.")
        print("ℹ️  This helps detect data races and thread safety issues.")
        print("")
        
        // Build arguments for swift test with TSAN
        var args = [
            "test",
            "--filter", "StressTest",
            "--sanitize=thread"
        ]
        
        // TSAN tests should never run in parallel
        if arguments.contains("--parallel") {
            print("⚠️  Warning: --parallel is ignored when using Thread Sanitizer")
        }
        
        // Add any other arguments passed to the plugin
        args.append(contentsOf: arguments.filter { $0 != "--parallel" })
        
        // Create and run the process
        let process = Process()
        process.executableURL = swiftExec
        process.arguments = args
        process.currentDirectoryURL = context.package.directoryURL
        
        // Set environment for TSAN
        var env = ProcessInfo.processInfo.environment
        env["TSAN_OPTIONS"] = "halt_on_error=1"
        process.environment = env
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                print("\n✅ Stress tests with TSAN passed! No data races detected.")
            } else {
                print("\n❌ TSAN detected issues or tests failed with exit code: \(process.terminationStatus)")
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