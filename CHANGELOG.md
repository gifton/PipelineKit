# Changelog

All notable changes to PipelineKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Added `withBorrowedObject` method to `GenericObjectPool` for safe scoped borrowing
- Added `withBorrowedMeasurement` method to `PerformanceMeasurementPool` for automatic cleanup

### Changed
- Updated `PerformanceMiddleware.createMeasurement` to use scoped borrowing pattern

### Removed
- Nothing yet

### Fixed
- Fixed PooledObject automatic return issue - deinit cannot call async actor methods

### Security
- Nothing yet

## [Planned for Initial Release]

### Features in Development
- Core pipeline functionality with middleware pattern
- Thread-safe `CommandContext` implementation
- Parallel middleware execution support
- Context pooling for reduced memory allocations
- Middleware result caching
- Comprehensive builder pattern for pipeline construction
- Type-safe command and result handling
- Flexible middleware prioritization system
- Timeout middleware wrapper for execution monitoring
- Memory-efficient implementation
- Full async/await support throughout the API
- Comprehensive test suite
- Detailed documentation and examples
- SwiftLint integration for code quality
- GitHub Actions for CI/CD
- Context operations: 94.4% faster than actor-based approach
- Pipeline execution: 30% improvement with pre-compilation
- Parallel execution: Up to 49% speedup with 4 cores
- Memory usage: 131 bytes per context
- Cache hit rates: 99.8% in typical workloads

[Unreleased]: https://github.com/yourusername/PipelineKit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yourusername/PipelineKit/releases/tag/v0.1.0