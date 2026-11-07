// swift-tools-version: 6.2
import Foundation
import PackageDescription

let sourceRoot = ProcessInfo.processInfo.environment["PIPELINEKIT_BENCHMARK_SOURCE_ROOT"] ?? "../../.."
let package = Package(
    name: "PipelineKitBenchmark",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "PipelineKit", path: sourceRoot)],
    targets: [.executableTarget(name: "PipelineKitBenchmark", dependencies: [
        .product(name: "PipelineKit", package: "PipelineKit"),
        .product(name: "PipelineKitResilience", package: "PipelineKit"),
        .product(name: "PipelineKitObservability", package: "PipelineKit")
    ], path: "Sources/Benchmark", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")])],
    swiftLanguageModes: [.v6]
)
