// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "PipelineKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10)
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
            name: "PipelineKitSecurity",
            targets: ["PipelineKitSecurity"]
        ),
        .library(
            name: "PipelineKitResilience",
            targets: ["PipelineKitResilience"]
        ),
        .library(
            name: "PipelineKitStorage",
            targets: ["PipelineKitStorage"]
        ),
        .library(
            name: "PipelineKitObservability",
            targets: ["PipelineKitObservability"]
        ),
        // Benchmark support library
        .library(
            name: "PipelineKitBenchmark",
            targets: ["PipelineKitBenchmark"]
        ),
        // Test support library - only for use in tests
        .library(
            name: "PipelineKitTestSupport",
            targets: ["PipelineKitTestSupport"]
        ),
        // Command plugins for test execution
        .plugin(
            name: "test-unit",
            targets: ["TestUnitCommand"]
        ),
        .plugin(
            name: "benchmark",
            targets: ["BenchmarkCommand"]
        ),
    ],
    dependencies: [
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
        .target(
            name: "PipelineKit",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                // Re-export all modular libraries
                "PipelineKitCore",
                "PipelineKitSecurity",
                "PipelineKitResilience",
                "PipelineKitObservability",
                "PipelineKitStorage"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                // Enable System Programming Interface for internal module boundaries
                .enableExperimentalFeature("AccessLevelOnImport"),
                // Enable @testable imports in debug builds
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .target(
            name: "PipelineKitTestSupport",
            dependencies: ["PipelineKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        // Unified benchmark executable
        .executableTarget(
            name: "Benchmarks",
            dependencies: ["PipelineKit", "PipelineKitBenchmark"],
            path: "Sources/Benchmarks"
        ),
        // Core module tests
        .testTarget(
            name: "PipelineKitCoreTests",
            dependencies: ["PipelineKitCore", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        // Security module tests
        .testTarget(
            name: "PipelineKitSecurityTests",
            dependencies: ["PipelineKitSecurity", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        // Resilience module tests
        .testTarget(
            name: "PipelineKitResilienceTests",
            dependencies: ["PipelineKitResilience", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        // Observability module tests
        .testTarget(
            name: "PipelineKitObservabilityTests",
            dependencies: ["PipelineKitObservability", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        // Caching module tests
        .testTarget(
            name: "PipelineKitStorageTests",
            dependencies: ["PipelineKitStorage", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // MARK: - Modular Targets
        
        // Core module - Foundation with no dependencies on other PipelineKit modules
        .target(
            name: "PipelineKitCore",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Security module - Depends on Core
        .target(
            name: "PipelineKitSecurity",
            dependencies: ["PipelineKitCore", "PipelineKitResilience"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Resilience module - Circuit breakers, retry, rate limiting
        .target(
            name: "PipelineKitResilience",
            dependencies: ["PipelineKitCore", "PipelineKitObservability"],
            exclude: ["Documentation"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Observability module - Unified events and metrics system
        .target(
            name: "PipelineKitObservability",
            dependencies: [
                "PipelineKitCore",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Storage module - Memory management and caching combined
        .target(
            name: "PipelineKitStorage",
            dependencies: [
                "PipelineKitCore",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Benchmark module - High-performance benchmarking utilities
        .target(
            name: "PipelineKitBenchmark",
            dependencies: [],
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
        
        
        // Plugin for running benchmarks
        .plugin(
            name: "BenchmarkCommand",
            capability: .command(
                intent: .custom(verb: "benchmark", description: "Run performance benchmarks"),
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
// 3. **Observability** (Sources/PipelineKitObservability/)
//    - Event-driven observability
//    - Type-safe metric recording
//    - Statistical accumulators
//    - Prometheus exporter
//    - Visualization tools
//
// 4. **Extensions** (Sources/PipelineKit/Resilience/, Testing/, Middleware/*)
//    - Caching middleware
//    - Rate limiting
//    - Resilience patterns
//    - Testing utilities
//
// Future versions may split these into separate Swift packages for better modularity.
