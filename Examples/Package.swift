// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PipelineKitExamples",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
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
            name: "AdvancedExample",
            dependencies: [
                .product(name: "PipelineKit", package: "PipelineKit"),
                .product(name: "PipelineKitResilience", package: "PipelineKit")
            ]
        ),
        .executableTarget(
            name: "MetricsSamplingExample",
            dependencies: [.product(name: "PipelineKitObservability", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "MetricsAggregationExample",
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
