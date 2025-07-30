// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "PipelineKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        // Main library containing all functionality
        .library(
            name: "PipelineKit",
            targets: ["PipelineKit"]
        ),
        // Test support library - only for use in tests
        .library(
            name: "PipelineKitTestSupport",
            targets: ["PipelineKitTestSupport"]
        ),
        // Benchmark executable - not included in release builds
        .executable(
            name: "PipelineKitBenchmarks",
            targets: ["PipelineKitBenchmarks"]
        ),
        // Stress test demonstration
        .executable(
            name: "StressTestDemo",
            targets: ["StressTestDemo"]
        ),
        // Metric aggregation demonstration
        .executable(
            name: "AggregationDemo",
            targets: ["AggregationDemo"]
        ),
        // Metric export demonstration
        .executable(
            name: "ExportDemo",
            targets: ["ExportDemo"]
        ),
        // Resource tracking demonstration
        .executable(
            name: "ResourceTrackingDemo",
            targets: ["ResourceTrackingDemo"]
        ),
    ],
    dependencies: [
        // Pin to exact version for reproducible builds
        // swift-syntax 510.0.3 - Last audited: 2025-05-28
        // Security: No known vulnerabilities
        // License: Apache-2.0
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "510.0.3"),
        // swift-atomics 1.2.0 - For lock-free atomic operations
        // Security: No known vulnerabilities
        // License: Apache-2.0
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        .macro(
            name: "PipelineMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax")
            ]
        ),
        .target(
            name: "PipelineKit",
            dependencies: [
                "PipelineMacros",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                // Enable System Programming Interface for internal module boundaries
                .enableExperimentalFeature("AccessLevelOnImport")
            ]
        ),
        .target(
            name: "PipelineKitTestSupport",
            dependencies: ["PipelineKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "VerifyChanges",
            dependencies: ["PipelineKit"]
        ),
        .executableTarget(
            name: "PipelineKitBenchmarks",
            dependencies: ["PipelineKit"],
            path: "Sources/PipelineKitBenchmarks",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "PipelineKitTests",
            dependencies: ["PipelineKit", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "PipelineMacrosTests",
            dependencies: [
                "PipelineMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "StressTestDemo",
            dependencies: ["PipelineKit"]
        ),
        .executableTarget(
            name: "MetricBufferDemo",
            dependencies: ["PipelineKit"]
        ),
        .executableTarget(
            name: "AggregationDemo",
            dependencies: ["PipelineKit"]
        ),
        .executableTarget(
            name: "ExportDemo",
            dependencies: ["PipelineKit"]
        ),
        .executableTarget(
            name: "ResourceTrackingDemo",
            dependencies: ["PipelineKit"]
        ),
        .testTarget(
            name: "StressTestCore",
            dependencies: ["PipelineKit", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "StressTestTSan",
            dependencies: ["PipelineKit", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-sanitize=thread"], .when(configuration: .debug))
            ],
            linkerSettings: [
                .unsafeFlags(["-sanitize=thread"], .when(configuration: .debug))
            ]
        ),
    ]
)

// MARK: - Module Structure Documentation
//
// PipelineKit is logically organized into four modules:
//
// 1. **Core** (Sources/PipelineKit/Core/, Pipeline/, Bus/)
//    - Essential protocols and types
//    - Pipeline implementations
//    - Command bus functionality
//    - Basic middleware
//
// 2. **Security** (Sources/PipelineKit/Security/, Middleware/Authentication/, Middleware/Authorization/)
//    - Authentication and authorization
//    - Encryption services
//    - Audit logging
//    - Security policies
//
// 3. **Observability** (Sources/PipelineKit/Observability/, Middleware/Metrics/)
//    - Pipeline observers
//    - Metrics collection
//    - Logging and monitoring
//    - Visualization tools
//
// 4. **Extensions** (Sources/PipelineKit/Resilience/, Testing/, Middleware/*)
//    - Caching middleware
//    - Rate limiting
//    - Resilience patterns
//    - Testing utilities
//
// Future versions may split these into separate Swift packages for better modularity.
