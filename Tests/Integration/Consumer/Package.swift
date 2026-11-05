// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "PipelineKit", path: "../../..")],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: ["PipelineKit", "PipelineKitSecurity", "PipelineKitCache", "PipelineKitResilience", "PipelineKitObservability", "PipelineKitPooling"].map {
                .product(name: $0, package: "PipelineKit")
            }
        )
    ]
)
