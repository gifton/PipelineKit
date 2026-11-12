# Installation Guide

Install PipelineKit with Swift Package Manager, either through Xcode or a
`Package.swift` manifest. The package manifest defines the module graph and external
dependencies required to build the library.

These instructions target **0.6.0**. Published tags are listed on the
[releases page](https://github.com/gifton/PipelineKit/releases). Follow the
[0.6.0 migration guide](../migrations/release-readiness.md) when upgrading from 0.5.4.

## Requirements

- Swift 6.2 or later
- Xcode 26.0 or later (for Xcode integration)
- macOS 26.0+ / iOS 26.0+ / tvOS 26.0+ / watchOS 26.0+ / visionOS 26.0+

## Swift Package Manager (Recommended)

### Xcode Integration

1. Open your project in Xcode
2. Go to **File** → **Add Package Dependencies...**
3. Enter the repository URL:
   ```
   https://github.com/gifton/PipelineKit.git
   ```
4. Choose a version range from 0.6.0 up to, but excluding, 0.7.0
5. Click **Add Package**
6. Select the products you want to add to your targets

### Package.swift

Add PipelineKit to your `Package.swift` manifest:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YourPackage",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/gifton/PipelineKit.git", "0.6.0"..<"0.7.0")
    ],
    targets: [
        .target(
            name: "YourTarget",
            dependencies: [
                .product(name: "PipelineKit", package: "PipelineKit"),
                .product(name: "PipelineKitResilience", package: "PipelineKit")
            ]
        ),
        .testTarget(
            name: "YourTargetTests",
            dependencies: ["YourTarget"]
        )
    ]
)
```

`PipelineKit` provides the pipeline APIs. Add the `PipelineKitResilience` product
for the retry example in the [basic usage tutorial](../tutorials/basic-usage.md),
and import `PipelineKitResilience` in files that use it. Add other products only as
needed, such as `PipelineKitSecurity`, `PipelineKitCache`, or
`PipelineKitObservability`.

### Version Requirements

You can specify version requirements in several ways:

```swift
// Exact version
.package(url: "...", exact: "0.6.0")

// Version range
.package(url: "...", "0.6.0"..<"0.7.0")

// From version (allows source-breaking 0.7.0 and later minors)
.package(url: "...", from: "0.6.0")

// Up to next major (also allows source-breaking minors)
.package(url: "...", .upToNextMajor(from: "0.6.0"))

// Up to next minor
.package(url: "...", .upToNextMinor(from: "0.6.0"))

// Branch
.package(url: "...", branch: "main")

// Commit
.package(url: "...", revision: "abc123")
```

## Command Line

### Clone and Build

```bash
# Clone the repository
git clone https://github.com/gifton/PipelineKit.git
cd PipelineKit

# Build the package
swift build

# Run tests
swift test

# Build for release
swift build -c release
```

### Using as a Dependency

Create a new Swift package that depends on PipelineKit:

```bash
mkdir MyApp
cd MyApp
swift package init --type executable

# Edit Package.swift to add PipelineKit dependency
# Then resolve dependencies
swift package resolve
swift build
```

## Local Package Checkout

For local development, clone the repository and add the checkout as a local Swift
package. A manifest can reference the checkout by path:

```swift
.package(path: "../PipelineKit")
```

Keep the product dependencies shown above. Copying `Sources/PipelineKit` into an
application target is unsupported: that directory depends on sibling targets such
as `PipelineKitCore` and external packages declared in the root manifest.

## Verification

After installation, verify PipelineKit is working:

```swift
import PipelineKit

let context = CommandContext()
print("PipelineKit installed successfully!")
```

## Updating

### Swift Package Manager

Update to the latest version:

```bash
swift package update
```

Or in Xcode:
1. Navigate to your project settings
2. Select "Package Dependencies"
3. Select PipelineKit
4. Click "Update to Latest Package Versions"

## Platform-Specific Notes

### Linux

PipelineKit builds on Linux. Ensure you have Swift 6.2+ installed. Some transports (e.g., UDP via Network framework) may require alternative backends on non‑Apple platforms:

```bash
# Ubuntu - install Swift 6.2+
# See https://swift.org/download/

# Using Docker
docker run --rm -it swift:6.2
```

## Troubleshooting

### "No such module 'PipelineKit'"

1. Ensure the package is properly added to your target dependencies
2. Clean build folder: **Product** → **Clean Build Folder** (⇧⌘K)
3. Resolve packages: **File** → **Packages** → **Resolve Package Versions**

### "Package.resolved file is corrupted"

```bash
rm Package.resolved
swift package resolve
```

### "Cannot find package"

Ensure you have internet connectivity and the repository URL is correct.

## Next Steps

- Write a first pipeline: [README](../../README.md#a-first-pipeline)
- Work through the [basic usage tutorial](../tutorials/basic-usage.md)
- Run the programs in [Examples](../../Examples/README.md)
