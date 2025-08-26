import PackagePlugin
import Foundation

@main
struct BenchmarkCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        // Get the swift executable URL
        let swiftExec = try context.tool(named: "swift").url
        
        // Print header
        print("📊 Running PipelineKit Benchmarks")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        
        // Parse command line arguments
        var benchmarkArgs: [String] = []
        var buildConfiguration = "release"
        var filter: String? = nil
        var quick = false
        var verbose = false
        
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--debug":
                buildConfiguration = "debug"
            case "--quick", "-q":
                quick = true
                benchmarkArgs.append("--quick")
            case "--filter", "-f":
                i += 1
                if i < arguments.count {
                    filter = arguments[i]
                    benchmarkArgs.append(arguments[i])
                }
            case "--verbose", "-v":
                verbose = true
            case "--help", "-h":
                printHelp()
                return
            default:
                // Pass through any other arguments
                benchmarkArgs.append(arguments[i])
            }
            i += 1
        }
        
        // Build the benchmark executable
        print("🔨 Building benchmarks (\(buildConfiguration) mode)...")
        let buildProcess = Process()
        buildProcess.executableURL = swiftExec
        buildProcess.arguments = ["build", "--product", "PipelineKitBenchmarks", "-c", buildConfiguration]
        buildProcess.currentDirectoryURL = context.package.directoryURL
        
        // Disable jemalloc to avoid CI dependency issues
        var environment = ProcessInfo.processInfo.environment
        environment["BENCHMARK_DISABLE_JEMALLOC"] = "1"
        buildProcess.environment = environment
        
        if verbose {
            buildProcess.arguments?.append("-v")
        }
        
        do {
            try buildProcess.run()
            buildProcess.waitUntilExit()
            
            if buildProcess.terminationStatus != 0 {
                print("\n❌ Build failed with exit code: \(buildProcess.terminationStatus)")
                throw PluginError.buildFailed(exitCode: buildProcess.terminationStatus)
            }
        } catch let error as PluginError {
            throw error
        } catch {
            print("\n❌ Failed to build benchmarks: \(error)")
            throw PluginError.processLaunchFailed(error)
        }
        
        // Run the benchmark executable
        print("\n🏃 Running benchmarks...")
        if let filter = filter {
            print("   Filter: \(filter)")
        }
        if quick {
            print("   Mode: Quick")
        }
        print("")
        
        let benchmarkURL = context.package.directoryURL.appending(components: ".build", buildConfiguration, "PipelineKitBenchmarks")
        let benchmarkProcess = Process()
        benchmarkProcess.executableURL = benchmarkURL
        benchmarkProcess.arguments = benchmarkArgs
        benchmarkProcess.currentDirectoryURL = context.package.directoryURL
        benchmarkProcess.environment = environment
        
        // Capture output for potential analysis
        let outputPipe = Pipe()
        benchmarkProcess.standardOutput = outputPipe
        benchmarkProcess.standardError = FileHandle.standardError
        
        do {
            try benchmarkProcess.run()
            
            // Read and display output in real-time
            let outputHandle = outputPipe.fileHandleForReading
            outputHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.count > 0 {
                    if let output = String(data: data, encoding: .utf8) {
                        print(output, terminator: "")
                    }
                }
            }
            
            benchmarkProcess.waitUntilExit()
            outputHandle.readabilityHandler = nil
            
            if benchmarkProcess.terminationStatus == 0 {
                print("\n✅ Benchmarks completed successfully!")
            } else {
                print("\n❌ Benchmarks failed with exit code: \(benchmarkProcess.terminationStatus)")
                throw PluginError.benchmarksFailed(exitCode: benchmarkProcess.terminationStatus)
            }
        } catch let error as PluginError {
            throw error
        } catch {
            print("\n❌ Failed to run benchmarks: \(error)")
            throw PluginError.processLaunchFailed(error)
        }
    }
    
    func printHelp() {
        print("""
        PipelineKit Benchmark Plugin
        
        Usage: swift package benchmark [options] [benchmark-name]
        
        Options:
          --debug              Build in debug mode (default: release)
          --quick, -q          Run in quick mode (fewer iterations)
          --filter, -f <name>  Filter benchmarks by name
          --verbose, -v        Verbose build output
          --help, -h           Show this help message
        
        Examples:
          swift package benchmark
          swift package benchmark --quick
          swift package benchmark --filter BackPressure
          swift package benchmark CommandContext
        """)
    }
}

enum PluginError: Error, CustomStringConvertible {
    case buildFailed(exitCode: Int32)
    case benchmarksFailed(exitCode: Int32)
    case processLaunchFailed(Error)
    
    var description: String {
        switch self {
        case .buildFailed(let exitCode):
            return "Build failed with exit code \(exitCode)"
        case .benchmarksFailed(let exitCode):
            return "Benchmarks failed with exit code \(exitCode)"
        case .processLaunchFailed(let error):
            return "Failed to launch process: \(error)"
        }
    }
}