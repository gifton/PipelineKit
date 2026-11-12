# PipelineKit Makefile
# Provides convenient shortcuts for common development tasks

.PHONY: help test test-unit clean build docs docs-preview lint

# Default target
help:
	@echo "PipelineKit Development Commands:"
	@echo ""
	@echo "Testing:"
	@echo "  make test              - Run all tests except the performance suite, in parallel"
	@echo "  make test-unit         - Run unit tests only"
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
	@echo "  make lint              - Lint code with SwiftLint (if installed)"

# Run all tests except the performance suite (the loop CONTRIBUTING.md documents)
test:
	swift test --parallel --skip PipelineKitPerformanceTests

# Run unit tests only
test-unit:
	swift package test-unit

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