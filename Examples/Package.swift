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
        // StatsDExample and OTLPExample are intentionally NOT wired up as targets here:
        // see Examples/Sources/StatsDExample and Examples/Sources/OTLPExample — both hit
        // the deep-failure rule (APIs the shipped package no longer has) and are pending
        // a controller decision on rewrite vs. removal. See task-6-report.md.
        .executableTarget(
            name: "MetricsSamplingExample",
            dependencies: [.product(name: "PipelineKitObservability", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "MetricsAggregationExample",
            dependencies: [.product(name: "PipelineKitObservability", package: "PipelineKit")]
        ),
        // TypeSafeMetricsExample is intentionally NOT wired up as a target here: see
        // Examples/Sources/TypeSafeMetricsExample — hits the deep-failure rule (APIs the
        // shipped package no longer has) and is pending a controller decision. See
        // task-6-report.md.
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
