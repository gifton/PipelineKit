# Installation Guide

PipelineKit supports multiple installation methods to fit your workflow.

## Requirements

- Swift 5.10 or later
- Xcode 15.0 or later (for Xcode integration)
- macOS 13.0+ / iOS 17.0+ / tvOS 16.0+ / watchOS 9.0+

## Swift Package Manager (Recommended)

### Xcode Integration

1. Open your project in Xcode
2. Go to **File** ’ **Add Package Dependencies...**
3. Enter the repository URL:
   ```
   https://github.com/yourusername/PipelineKit.git
   ```
4. Choose version requirements (e.g., "Up to Next Major" from 0.1.0)
5. Click **Add Package**
6. Select the products you want to add to your targets

### Package.swift

Add PipelineKit to your `Package.swift` manifest:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YourPackage",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    dependencies: [
        .package(url: "https://github.com/yourusername/PipelineKit.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "YourTarget",
            dependencies: ["PipelineKit"]
        ),
        .testTarget(
            name: "YourTargetTests",
            dependencies: ["YourTarget", "PipelineKit"]
        )
    ]
)
```

### Version Requirements

You can specify version requirements in several ways:

```swift
// Exact version
.package(url: "...", exact: "0.1.0")

// Version range
.package(url: "...", "0.1.0"..<"0.2.0")

// From version
.package(url: "...", from: "0.1.0")

// Up to next major
.package(url: "...", .upToNextMajor(from: "0.1.0"))

// Up to next minor
.package(url: "...", .upToNextMinor(from: "0.1.0"))

// Branch
.package(url: "...", branch: "main")

// Commit
.package(url: "...", revision: "abc123")
```

## Command Line

### Clone and Build

```bash
# Clone the repository
git clone https://github.com/yourusername/PipelineKit.git
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

## CocoaPods

**Note**: CocoaPods support is planned for a future release.

```ruby
# Podfile (Coming Soon)
pod 'PipelineKit', '~> 0.1.0'
```

## Carthage

**Note**: Carthage support is planned for a future release.

```
# Cartfile (Coming Soon)
github "yourusername/PipelineKit" ~> 0.1.0
```

## Manual Installation

While not recommended, you can manually add PipelineKit to your project:

1. Download the source code
2. Drag the `Sources/PipelineKit` folder into your Xcode project
3. Ensure the files are added to your target

**Note**: Manual installation requires you to manage updates yourself and may cause issues with dependencies.

## Verification

After installation, verify PipelineKit is working:

```swift
import PipelineKit

// Create a simple test
let metadata = StandardCommandMetadata(userId: "test")
let context = CommandContext(metadata: metadata)
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

PipelineKit is fully compatible with Linux. Ensure you have Swift installed:

```bash
# Ubuntu
apt-get install swift

# Using Docker
docker run --rm -it swift:5.10
```

### Windows

Windows support is experimental. Use the official Swift for Windows installer.

## Troubleshooting

### "No such module 'PipelineKit'"

1. Ensure the package is properly added to your target dependencies
2. Clean build folder: **Product** ’ **Clean Build Folder** (çK)
3. Resolve packages: **File** ’ **Packages** ’ **Resolve Package Versions**

### "Package.resolved file is corrupted"

```bash
rm Package.resolved
swift package resolve
```

### "Cannot find package"

Ensure you have internet connectivity and the repository URL is correct.

## Next Steps

- Follow the [Getting Started](getting-started.md) guide
- Read about [Architecture](architecture.md)
- Check out [Examples](examples/basic-usage.md)
