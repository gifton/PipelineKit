# PipelineKit Makefile
# Provides convenient shortcuts for common development tasks

.PHONY: help test test-unit test-stress test-stress-tsan test-integration clean build docs format lint

# Default target
help:
	@echo "PipelineKit Development Commands:"
	@echo ""
	@echo "Testing:"
	@echo "  make test              - Run all tests"
	@echo "  make test-unit         - Run unit tests only"
	@echo "  make test-stress       - Run stress tests"
	@echo "  make test-stress-tsan  - Run stress tests with Thread Sanitizer"
	@echo "  make test-integration  - Run integration tests only"
	@echo ""
	@echo "Building:"
	@echo "  make build             - Build the package"
	@echo "  make clean             - Clean build artifacts"
	@echo ""
	@echo "Documentation:"
	@echo "  make docs              - Generate documentation"
	@echo "  make docs-preview      - Preview documentation in browser"
	@echo ""
	@echo "Code Quality:"
	@echo "  make format            - Format code with swift-format"
	@echo "  make lint              - Lint code with SwiftLint (if installed)"

# Run all tests
test:
	swift test

# Run unit tests only
test-unit:
	swift package test-unit

# Run stress tests
test-stress:
	swift package test-stress

# Run stress tests with Thread Sanitizer
test-stress-tsan:
	swift package test-stress-tsan

# Run integration tests only
test-integration:
	swift package test-integration

# Build the package
build:
	swift build

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build

# Generate documentation
docs:
	swift package generate-documentation

# Preview documentation
docs-preview:
	swift package preview-documentation

# Format code (requires swift-format)
format:
	@if command -v swift-format >/dev/null 2>&1; then \
		swift-format -i -r Sources/ Tests/; \
	else \
		echo "swift-format not installed. Install with: brew install swift-format"; \
	fi

# Lint code (requires SwiftLint)
lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint; \
	else \
		echo "SwiftLint not installed. Install with: brew install swiftlint"; \
	fi

# Advanced targets for CI/CD
.PHONY: test-coverage test-parallel release

# Run tests with code coverage
test-coverage:
	swift test --enable-code-coverage
	@echo "Coverage report generated. Use 'swift test --show-codecov-path' to see the path."

# Run all tests in parallel
test-parallel:
	swift test --parallel

# Create release build
release:
	swift build -c release