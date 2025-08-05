// swift-tools-version: 5.10
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
        // Test support library - only for use in tests
        .library(
            name: "PipelineKitTestSupport",
            targets: ["PipelineKitTestSupport"]
        ),
        // Stress test support library
        .library(
            name: "StressTesting",
            targets: ["StressTesting"]
        ),
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
                "PipelineKitMiddleware",
                "PipelineKitSecurity"
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
        .target(
            name: "StressTesting",
            dependencies: [
                "PipelineKit",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        // Unified benchmark runner
        .executableTarget(
            name: "PipelineKitBenchmarks",
            dependencies: ["PipelineKit"],
            path: "Sources/PipelineKitBenchmarks"
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
        // Middleware module tests
        .testTarget(
            name: "PipelineKitMiddlewareTests",
            dependencies: ["PipelineKitMiddleware", "PipelineKitTestSupport"],
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
        // Integration tests - tests that span multiple modules
        .testTarget(
            name: "PipelineKitIntegrationTests",
            dependencies: ["PipelineKit", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "StressTestCore",
            dependencies: ["PipelineKit", "PipelineKitTestSupport", "StressTesting"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "StressTestIntegration",
            dependencies: ["PipelineKit", "PipelineKitTestSupport", "StressTesting"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
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
            dependencies: ["PipelineKitCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Middleware module - Depends on Core and Security
        .target(
            name: "PipelineKitMiddleware",
            dependencies: [
                "PipelineKitCore",
                "PipelineKitSecurity"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
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
