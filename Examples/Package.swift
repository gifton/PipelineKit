// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PipelineKitExamples",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "BasicExample",
            dependencies: [
                .product(name: "PipelineKit", package: "PipelineKit")
            ]
        ),
        .executableTarget(
            name: "AdvancedExample",
            dependencies: [
                .product(name: "PipelineKit", package: "PipelineKit")
            ]
        )
    ]
)