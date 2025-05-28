// Recommended Package.swift with exact version pinning:

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
        .library(
            name: "PipelineKit",
            targets: ["PipelineKit"]),
    ],
    dependencies: [
        // Pin to exact version for reproducible builds
        // swift-syntax 510.0.3 - Last audited: $(date +%Y-%m-%d)
        // Security: No known vulnerabilities
        // License: Apache-2.0
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "510.0.3"),
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
            dependencies: ["PipelineMacros"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "PipelineKitTests",
            dependencies: ["PipelineKit"],
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
    ]
)
