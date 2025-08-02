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
        // Modular libraries
        .library(
            name: "PipelineKitCore",
            targets: ["PipelineKitCore"]
        ),
        .library(
            name: "PipelineKitMiddleware",
            targets: ["PipelineKitMiddleware"]
        ),
        .library(
            name: "PipelineKitSecurity",
            targets: ["PipelineKitSecurity"]
        ),
        .library(
            name: "PipelineKitObservability",
            targets: ["PipelineKitObservability"]
        ),
        // Test support library - only for use in tests
        .library(
            name: "PipelineKitTestSupport",
            targets: ["PipelineKitTestSupport"]
        ),
        // Stress test support library
        .library(
            name: "StressTestSupport",
            targets: ["StressTestSupport"]
        ),
        // Benchmark executable - not included in release builds
        // Benchmarks temporarily disabled during modularization
        // .executable(
        //     name: "PipelineKitBenchmarks",
        //     targets: ["PipelineKitBenchmarks"]
        // ),
        // Command plugins for test execution
        .plugin(
            name: "test-unit",
            targets: ["TestUnitCommand"]
        ),
        .plugin(
            name: "test-stress",
            targets: ["TestStressCommand"]
        ),
        .plugin(
            name: "test-stress-tsan",
            targets: ["TestStressTSANCommand"]
        ),
        .plugin(
            name: "test-integration",
            targets: ["TestIntegrationCommand"]
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
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        // swift-docc-plugin 1.3.0 - For documentation generation
        // Security: No known vulnerabilities
        // License: Apache-2.0
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")
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
                .product(name: "Atomics", package: "swift-atomics"),
                // Re-export all modular libraries
                "PipelineKitCore",
                "PipelineKitMiddleware",
                "PipelineKitSecurity",
                "PipelineKitObservability"
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
        .target(
            name: "StressTestSupport",
            dependencies: [
                "PipelineKit",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "VerifyChanges",
            dependencies: ["PipelineKit"]
        ),
        // Benchmarks temporarily disabled during modularization
        // .executableTarget(
        //     name: "PipelineKitBenchmarks",
        //     dependencies: ["PipelineKit"],
        //     path: "Sources/PipelineKitBenchmarks",
        //     exclude: ["README.md", "PHASE1-SUMMARY.md"]
        // ),
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
        .testTarget(
            name: "StressTestCore",
            dependencies: ["PipelineKit", "PipelineKitTestSupport", "StressTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "StressTestIntegration",
            dependencies: ["PipelineKit", "PipelineKitTestSupport", "StressTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        
        // MARK: - Modular Targets
        
        // Core module - Foundation with no dependencies on other PipelineKit modules
        .target(
            name: "PipelineKitCore",
            dependencies: [
                "PipelineMacros",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport")
            ]
        ),
        
        // Security module - Depends on Core
        .target(
            name: "PipelineKitSecurity",
            dependencies: ["PipelineKitCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport")
            ]
        ),
        
        // Observability module - Depends on Core
        .target(
            name: "PipelineKitObservability",
            dependencies: ["PipelineKitCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport")
            ]
        ),
        
        // Middleware module - Depends on Core, Security, and Observability
        .target(
            name: "PipelineKitMiddleware",
            dependencies: [
                "PipelineKitCore",
                "PipelineKitSecurity",
                "PipelineKitObservability"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport")
            ]
        ),
        
        // MARK: - Command Plugins
        
        // Plugin for running unit tests only
        .plugin(
            name: "TestUnitCommand",
            capability: .command(
                intent: .custom(verb: "test-unit", description: "Run unit tests only"),
                permissions: []
            )
        ),
        
        // Plugin for running stress tests
        .plugin(
            name: "TestStressCommand",
            capability: .command(
                intent: .custom(verb: "test-stress", description: "Run stress tests"),
                permissions: []
            )
        ),
        
        // Plugin for running stress tests with Thread Sanitizer
        .plugin(
            name: "TestStressTSANCommand",
            capability: .command(
                intent: .custom(verb: "test-stress-tsan", description: "Run stress tests with Thread Sanitizer"),
                permissions: []
            )
        ),
        
        // Plugin for running integration tests
        .plugin(
            name: "TestIntegrationCommand",
            capability: .command(
                intent: .custom(verb: "test-integration", description: "Run integration tests only"),
                permissions: []
            )
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
