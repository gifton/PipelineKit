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
            name: "PipelineKitCache",
            targets: ["PipelineKitCache"]
        ),
        .library(
            name: "PipelineKitPooling",
            targets: ["PipelineKitPooling"]
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
        // Command plugins for test execution
        .plugin(
            name: "test-unit",
            targets: ["TestUnitCommand"]
        ),
    ],
    dependencies: [
        // swift-atomics 1.2.0 - For lock-free atomic operations
        // Security: No known vulnerabilities
        // License: Apache-2.0
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        // swift-log - Cross-platform logging facade
        // Security: No known vulnerabilities
        // License: Apache-2.0
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        // swift-docc-plugin 1.3.0 - For documentation generation
        // Security: No known vulnerabilities
        // License: Apache-2.0
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "PipelineKit",
            dependencies: [
                "PipelineKitCore",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Logging", package: "swift-log")
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
            dependencies: ["PipelineKit", "PipelineKitSecurity"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        // Core module tests - Tests for PipelineKitCore foundation types
        .testTarget(
            name: "PipelineKitCoreTests",
            dependencies: [
                "PipelineKitCore",
                "PipelineKitTestSupport",
                "PipelineKitResilience",
                "PipelineKitObservability"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        // PipelineKit tests - Tests for higher-level pipeline features
        .testTarget(
            name: "PipelineKitTests",
            dependencies: ["PipelineKit", "PipelineKitTestSupport"],
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
        // Cache module tests
        .testTarget(
            name: "PipelineKitCacheTests",
            dependencies: ["PipelineKitCache", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        // Pooling module tests
        .testTarget(
            name: "PipelineKitPoolingTests",
            dependencies: ["PipelineKitPooling", "PipelineKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Performance test suite - XCTest based benchmarks
        .testTarget(
            name: "PipelineKitPerformanceTests",
            dependencies: [
                "PipelineKitCore",
                "PipelineKitResilience", 
                "PipelineKitSecurity",
                "PipelineKitCache",
                "PipelineKitPooling",
                "PipelineKitObservability",
                "PipelineKitTestSupport"
            ],
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
        
        // Security module - Depends on Kit
        .target(
            name: "PipelineKitSecurity",
            dependencies: ["PipelineKit", "PipelineKitResilience"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Resilience module - Circuit breakers, retry, rate limiting
        // Internal targets for parallel compilation
        .target(
            name: "_ResilienceFoundation",
            dependencies: [
                "PipelineKit",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            path: "Sources/PipelineKitResilienceFoundation",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .target(
            name: "_ResilienceCore",
            dependencies: [
                "PipelineKit",
                "_ResilienceFoundation",
                "PipelineKitObservability"
            ],
            path: "Sources/PipelineKitResilienceCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .target(
            name: "_RateLimiting",
            dependencies: [
                "PipelineKit",
                "_ResilienceFoundation"
            ],
            path: "Sources/PipelineKitResilienceRateLimiting",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .target(
            name: "_CircuitBreaker",
            dependencies: [
                "PipelineKit",
                "_ResilienceFoundation"
            ],
            path: "Sources/PipelineKitResilienceCircuitBreaker",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        // Public umbrella target
        .target(
            name: "PipelineKitResilience",
            dependencies: [
                "_ResilienceFoundation",
                "_ResilienceCore",
                "_RateLimiting",
                "_CircuitBreaker"
            ],
            path: "Sources/PipelineKitResilience",
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
                "PipelineKit",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Cache module - Caching middleware and protocols
        .target(
            name: "PipelineKitCache",
            dependencies: [
                "PipelineKit",
                "PipelineKitCore"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        
        // Pooling module - Object pooling and resource management
        .target(
            name: "PipelineKitPooling",
            dependencies: [
                "PipelineKitCore",
                "PipelineKitResilience",
                .product(name: "Atomics", package: "swift-atomics")
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
        
    ]
)
