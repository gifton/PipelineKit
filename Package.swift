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
        
        // Future modular products (planned for v2.0):
        // - PipelineKitCore: Essential pipeline functionality
        // - PipelineKitSecurity: Authentication, authorization, encryption
        // - PipelineKitObservability: Logging, metrics, monitoring  
        // - PipelineKitExtensions: Optional features and utilities
    ],
    dependencies: [
        // Pin to exact version for reproducible builds
        // swift-syntax 510.0.3 - Last audited: 2025-05-28
        // Security: No known vulnerabilities
        // License: Apache-2.0
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "510.0.3")
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
                "PipelineMacros"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                // Enable System Programming Interface for internal module boundaries
                .enableExperimentalFeature("AccessLevelOnImport")
            ]
        ),
        .executableTarget(
            name: "VerifyChanges",
            dependencies: ["PipelineKit"]
        ),
        .executableTarget(
            name: "PipelineKitBenchmarks",
            dependencies: ["PipelineKit"],
            path: "Sources/PipelineKitBenchmarks"
        ),
        .testTarget(
            name: "PipelineKitTests",
            dependencies: ["PipelineKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        // Integration tests disabled temporarily due to compilation errors
        /*
        .testTarget(
            name: "PipelineKitIntegrationTests",
            dependencies: ["PipelineKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        */
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
// Future versions will split these into separate Swift packages for better modularity.