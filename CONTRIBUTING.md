# Contributing to PipelineKit

Thank you for your interest in contributing to PipelineKit! This document provides guidelines and information for contributors.

## 🎯 How to Contribute

### Reporting Issues

Before creating an issue, please check if a similar issue already exists. When reporting bugs:

1. Use the bug report template
2. Provide minimal reproduction steps
3. Include Swift version and platform information
4. Add relevant logs or error messages

### Suggesting Features

For feature requests:

1. Use the feature request template
2. Explain the use case and motivation
3. Consider backward compatibility
4. Provide examples of the proposed API

### Pull Requests

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Update documentation if needed
7. Submit a pull request

## 🏗️ Development Setup

### Prerequisites

- Swift 6.0 or later
- Xcode 16.0 or later (for iOS/macOS development)
- Swift Package Manager

### Getting Started

```bash
# Clone the repository
git clone https://github.com/yourorg/PipelineKit.git
cd PipelineKit

# Build the project
swift build

# Run tests
swift test

# Generate documentation
swift package generate-documentation
```

### Project Structure

```
PipelineKit/
├── Sources/PipelineKit/
│   ├── Core/                 # Core protocols and types
│   ├── Bus/                  # Command bus implementation
│   ├── Pipeline/             # Pipeline implementations
│   ├── Security/             # Security features
│   └── Examples/             # Usage examples
├── Tests/PipelineKitTests/   # Test suite
├── Documentation/            # Additional documentation
└── Scripts/                  # Build and utility scripts
```

## 📝 Coding Standards

### Swift Style Guide

We follow the [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/) and [Swift.org Style Guide](https://google.github.io/swift/).

Key points:

- Use descriptive names for types, methods, and properties
- Prefer `struct` over `class` when possible
- Use `async`/`await` for asynchronous operations
- Mark types as `Sendable` when thread-safe
- Document public APIs with comprehensive comments

### Code Examples

```swift
// ✅ Good: Clear, descriptive names
public struct ValidationMiddleware: Middleware {
    private let validators: [CommandValidator]
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        try await validateCommand(command)
        return try await next(command, metadata)
    }
}

// ❌ Bad: Unclear names, missing documentation
public struct VM: MW {
    var v: [CV]
    func ex<T>(_ c: T, m: CM, n: @Sendable (T, CM) async throws -> T.Result) async throws -> T.Result {
        try await vc(c)
        return try await n(c, m)
    }
}
```

### Documentation Standards

All public APIs must be documented:

```swift
/// A middleware that validates commands before execution.
///
/// The validation middleware checks command data against predefined rules
/// and throws validation errors for invalid input.
///
/// Example:
/// ```swift
/// let middleware = ValidationMiddleware(validators: [
///     EmailValidator(),
///     LengthValidator(min: 1, max: 100)
/// ])
/// ```
///
/// - Note: Validation runs before any business logic execution
/// - Warning: Failed validation prevents command execution
public struct ValidationMiddleware: Middleware {
    // Implementation...
}
```

## 🧪 Testing Guidelines

### Test Organization

- Unit tests for individual components
- Integration tests for component interaction
- Performance tests for critical paths
- Security tests for vulnerability detection

### Writing Tests

```swift
final class ValidationMiddlewareTests: XCTestCase {
    
    // MARK: - Test Setup
    
    private var middleware: ValidationMiddleware!
    
    override func setUp() {
        super.setUp()
        middleware = ValidationMiddleware(validators: [TestValidator()])
    }
    
    // MARK: - Success Cases
    
    func testValidCommandPassesThrough() async throws {
        let command = ValidTestCommand()
        let result = try await middleware.execute(command, metadata: DefaultCommandMetadata()) { _, _ in
            "success"
        }
        XCTAssertEqual(result, "success")
    }
    
    // MARK: - Failure Cases
    
    func testInvalidCommandThrowsError() async throws {
        let command = InvalidTestCommand()
        
        do {
            _ = try await middleware.execute(command, metadata: DefaultCommandMetadata()) { _, _ in
                "should not reach"
            }
            XCTFail("Expected validation error")
        } catch let error as ValidationError {
            XCTAssertEqual(error.field, "testField")
        }
    }
    
    // MARK: - Test Helpers
    
    struct ValidTestCommand: Command {
        typealias Result = String
    }
    
    struct InvalidTestCommand: Command {
        typealias Result = String
    }
}
```

### Test Coverage

Maintain high test coverage:

- New features must have comprehensive tests
- Bug fixes must include regression tests
- Security features require security-specific tests

```bash
# Generate test coverage report
swift test --enable-code-coverage

# View coverage
swift test --show-codecov-path
```

## 🔒 Security Considerations

### Security Review Process

All security-related changes require:

1. Security impact assessment
2. Threat model review
3. Code review by security team member
4. Security testing (penetration testing if needed)

### Secure Coding Practices

- Validate all inputs
- Use cryptographically secure random numbers
- Implement proper error handling
- Follow principle of least privilege
- Sanitize all outputs

### Reporting Security Issues

**Do not create public issues for security vulnerabilities.**

Instead, email: security@pipelinekit.dev

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Suggested fix (if available)

## 📋 Pull Request Process

### Before Submitting

1. **Code Quality**
   ```bash
   swift build
   swift test
   ```

2. **Documentation**
   - Update API documentation
   - Add example usage
   - Update CHANGELOG.md

3. **Testing**
   - Add tests for new features
   - Ensure existing tests pass
   - Add performance tests if applicable

### PR Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update
- [ ] Security improvement

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] Manual testing performed

## Security Impact
- [ ] No security impact
- [ ] Security improvement
- [ ] Requires security review

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] Tests added/updated
- [ ] No breaking changes (or documented)
```

### Review Process

1. **Automated Checks**
   - Build succeeds
   - Tests pass
   - Code coverage maintained
   - Style guide compliance

2. **Code Review**
   - Functional correctness
   - Security implications
   - Performance impact
   - API design quality

3. **Final Approval**
   - Two approvals required
   - All discussions resolved
   - CI/CD pipeline passes

## 🚀 Release Process

### Versioning

We use [Semantic Versioning](https://semver.org/):

- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

### Release Checklist

1. **Preparation**
   - [ ] Update version numbers
   - [ ] Update CHANGELOG.md
   - [ ] Update documentation
   - [ ] Run full test suite

2. **Release**
   - [ ] Create release tag
   - [ ] Build release artifacts
   - [ ] Update package repositories
   - [ ] Publish documentation

3. **Post-Release**
   - [ ] Monitor for issues
   - [ ] Update examples
   - [ ] Announce release

## 🤝 Community Guidelines

### Code of Conduct

We are committed to providing a welcoming and inspiring community for all. Please read our [Code of Conduct](CODE_OF_CONDUCT.md).

### Communication

- **GitHub Issues**: Bug reports and feature requests
- **GitHub Discussions**: General questions and discussions
- **Email**: security@pipelinekit.dev for security issues

### Recognition

Contributors are recognized in:
- CONTRIBUTORS.md file
- Release notes
- Project documentation

## 📚 Resources

### Learning Resources

- [Swift Documentation](https://docs.swift.org/)
- [Swift Package Manager](https://swift.org/package-manager/)
- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [Security Best Practices](SECURITY.md)

### Development Tools

- [SwiftLint](https://github.com/realm/SwiftLint) - Code style enforcement
- [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) - Code formatting
- [Instruments](https://developer.apple.com/instruments/) - Performance profiling

### Useful Commands

```bash
# Format code
swift-format --in-place --recursive Sources/ Tests/

# Lint code
swiftlint lint

# Run specific tests
swift test --filter ValidationTests

# Profile performance
swift test --enable-test-discovery --parallel
```

## ❓ Getting Help

If you need help:

1. Check existing documentation
2. Search GitHub issues
3. Ask in GitHub Discussions
4. Contact maintainers

---

Thank you for contributing to PipelineKit! Your contributions help make the framework better for everyone.