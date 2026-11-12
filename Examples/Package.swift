// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PipelineKitExamples",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    dependencies: [
        .package(name: "PipelineKit", path: "..")
    ],
    targets: [
        .executableTarget(
            name: "BasicExample",
            dependencies: [.product(name: "PipelineKit", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "MiddlewareStackExample",
            dependencies: [
                .product(name: "PipelineKit", package: "PipelineKit"),
                .product(name: "PipelineKitResilience", package: "PipelineKit")
            ]
        ),
        .executableTarget(
            name: "BatchIngestExample",
            dependencies: [
                .product(name: "PipelineKit", package: "PipelineKit"),
                .product(name: "PipelineKitResilience", package: "PipelineKit"),
                .product(name: "PipelineKitObservability", package: "PipelineKit")
            ]
        ),
        .executableTarget(
            name: "StatsDExportExample",
            dependencies: [.product(name: "PipelineKitObservability", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "TypeSafeEncryptionExample",
            dependencies: [
                .product(name: "PipelineKit", package: "PipelineKit"),
                .product(name: "PipelineKitCore", package: "PipelineKit"),
                .product(name: "PipelineKitSecurity", package: "PipelineKit")
            ]
        )
    ]
)
