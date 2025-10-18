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
        .watchOS(.v10),
        .visionOS(.v1)
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
        // swift-crypto - CryptoKit-compatible APIs for non-Apple platforms
        // Security: Maintained by Apple, used for Linux compatibility
        // License: Apache-2.0
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.4.0"),
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
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ],
            linkerSettings: [
                // Week 1 Optimization: Link Accelerate framework for vectorized operations
                .linkedFramework("Accelerate", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))
            ]
        ),
        .target(
            name: "PipelineKitTestSupport",
            dependencies: ["PipelineKit", "PipelineKitSecurity"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        // Core module tests - Tests for PipelineKitCore foundation types
        .testTarget(
            name: "PipelineKitCoreTests",
            dependencies: [
                "PipelineKitCore",
                "PipelineKitTestSupport",
                "PipelineKitResilience",
                "PipelineKitObservability",
                "PipelineKitPooling"  // Added for TestTeardownObserver
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
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ],
            linkerSettings: [
                // Week 1 Optimization: Link Accelerate framework (critical for MemoryProfiler statistics)
                .linkedFramework("Accelerate", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))
            ]
        ),
        
        // Security module - Depends on Kit
        .target(
            name: "PipelineKitSecurity",
            dependencies: [
                "PipelineKit",
                "PipelineKitResilience",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
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
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
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
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
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
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
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
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
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
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
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
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ],
            linkerSettings: [
                // Week 1 Optimization: Link Accelerate framework for metrics calculations
                .linkedFramework("Accelerate", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))
            ]
        ),
        
        // Cache module - Caching middleware and protocols
        .target(
            name: "PipelineKitCache",
            dependencies: [
                "PipelineKit",
                "PipelineKitCore",
                "PipelineKitObservability"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
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
                // Week 1 Optimization: Future-proof with Swift 6 upcoming features
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ],
            linkerSettings: [
                // Week 1 Optimization: Link Accelerate framework for pool metrics
                .linkedFramework("Accelerate", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))
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
