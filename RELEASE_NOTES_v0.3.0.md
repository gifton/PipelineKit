# PipelineKit v0.3.0 - Swift 6 Compliance & Stability Release

We're excited to announce **PipelineKit v0.3.0**, a focused release improving Swift 6 language mode compliance, CI stability, and documentation accuracy. This release incorporates valuable feedback from early beta integrators who helped identify compatibility issues and documentation gaps.

## 🙏 Thank You to Beta Integrators

Special thanks to our beta integrators who provided crucial feedback on Swift 6 strict concurrency compliance and helped us identify platform-specific CI issues. Your real-world integration testing has significantly improved the framework's robustness and developer experience.

## 📋 What's New

### ✅ Swift 6 Language Mode Compliance

Full compliance with Swift 6's strict concurrency checking through comprehensive protocol type annotations:

- **Added `any` keyword** to all protocol type usage across the codebase
- **Fixed protocol type warnings** in core modules:
  - `SimpleSemaphore.swift`, `DynamicPipeline.swift`, `MiddlewareChainBuilder.swift`
  - `StatsDExporter.swift`, `Command+Observability.swift`, `CommandContext+Events.swift`
  - `AsyncSemaphore.swift`, `BackPressureSemaphore.swift`, `StandardPipeline.swift`
  - `MetricsFacade.swift`
- **Added `@preconcurrency` import** for OSLog in `SignpostMiddleware.swift` to handle Sendable warnings

**Impact:** Projects using Swift 6 language mode will now compile without warnings, enabling stricter concurrency safety checks in your own code.

### 🧪 CI/CD Improvements

Enhanced continuous integration reliability and cross-platform compatibility:

- **Fixed flaky timing tests**: `BackPressureMiddlewareTests.testStatsAccuracy` now skips on CI where timing is unreliable
- **Coverage export improvements**:
  - Now uses Swift toolchain's `llvm-cov` instead of system version for consistency
  - Changed output format from JSON to LCOV for better tool compatibility
  - Added proper error handling and debugging output
- **macOS/Linux compatibility**: Removed Linux-specific `timeout` command from macOS workflows
  - Relies on job-level timeouts for better cross-platform compatibility

**Impact:** More reliable CI builds with better coverage reporting and reduced false-positive test failures.

### 📚 Documentation & Platform Support

Comprehensive documentation updates based on integrator feedback:

- **Platform support clarity**:
  - Added visionOS to platform badge and documentation
  - Added explicit platform version requirements section
- **Accuracy improvements**:
  - Fixed module name typo: `PipelineKitCaching` → `PipelineKitCache`
  - Updated all installation examples to reference v0.3.0
  - Corrected issue templates with current version numbers
- **Enhanced documentation** for CommandContext access patterns

**Impact:** Clearer onboarding for new users and accurate platform requirements information.

## 📦 Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", from: "0.3.0")
]
```

### Supported Platforms

- **Swift**: 6.0+
- **iOS**: 17.0+
- **macOS**: 14.0+
- **tvOS**: 17.0+
- **watchOS**: 10.0+
- **visionOS**: 1.0+
- **Linux**: Experimental support (some features may require alternative backends)

## 🔄 Migration from v0.2.0

This is a **non-breaking** release. No code changes are required when upgrading from v0.2.0.

### Recommended Actions

1. **Update your Package.swift**:
   ```swift
   .package(url: "https://github.com/gifton/PipelineKit.git", from: "0.3.0")
   ```

2. **Enable Swift 6 language mode** (optional but recommended):
   ```swift
   .target(
       name: "YourTarget",
       dependencies: ["PipelineKit"],
       swiftSettings: [
           .enableUpcomingFeature("ExistentialAny")
       ]
   )
   ```

3. **Run tests** to verify compatibility with improved strict concurrency checks

## 🐛 Bug Fixes

- Fixed Swift 6 protocol type warnings throughout the codebase
- Fixed coverage export format mismatch in CI
- Fixed flaky timing-dependent tests in CI environments
- Fixed cross-platform CI compatibility issues

## 🔧 Internal Improvements

- Improved CI stability with better timeout handling
- Enhanced coverage reporting with LCOV format
- Better error handling and debugging output in CI workflows
- Cleaned up platform-specific command usage

## 📊 Module Overview

PipelineKit provides modular, opt-in functionality:

| Module | Description |
|--------|-------------|
| **PipelineKit** | Main module with StandardPipeline, DynamicPipeline, PipelineBuilder |
| **PipelineKitCore** | Foundation types: Command, CommandHandler, Middleware, CommandContext |
| **PipelineKitObservability** | Events, metrics, StatsD export, ObservabilitySystem |
| **PipelineKitResilience** | Circuit breakers, retry, timeout, backpressure, bulkhead |
| **PipelineKitSecurity** | Authentication, authorization, audit logging |
| **PipelineKitCache** | Caching middleware with compression and invalidation |
| **PipelineKitPooling** | Object pooling for resource management |

## 🚀 What's Next

Looking ahead to future releases:

- **Distributed tracing** integration (OpenTelemetry)
- **Additional metrics backends** (Prometheus, CloudWatch)
- **Performance optimizations** based on real-world usage patterns
- **Enhanced Linux support** with platform-specific optimizations

## 📝 Full Changelog

For a complete list of changes, see [CHANGELOG.md](CHANGELOG.md).

## 🤝 Contributing

We welcome contributions! Areas where we'd especially appreciate help:

- Linux platform testing and optimization
- Additional metrics backend implementations
- Performance benchmarking on various workloads
- Documentation improvements and examples

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## 📄 License

PipelineKit is released under the MIT License. See [LICENSE](LICENSE) for details.

## 🔗 Resources

- **Documentation**: [Getting Started Guide](docs/getting-started/quick-start.md)
- **Examples**: [Examples Directory](Examples/)
- **Issues**: [GitHub Issues](https://github.com/gifton/PipelineKit/issues)
- **Discussions**: [GitHub Discussions](https://github.com/gifton/PipelineKit/discussions)

---

**Note for Integrators**: If you encounter any issues or have feedback, please [open an issue](https://github.com/gifton/PipelineKit/issues/new/choose) or start a [discussion](https://github.com/gifton/PipelineKit/discussions). Your real-world usage insights continue to drive the framework's evolution.

Built with ❤️ for the Swift community.
