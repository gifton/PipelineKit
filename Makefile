# PipelineKit Makefile
# Run 'make help' for a list of commands

.DEFAULT_GOAL := help

# Variables
SWIFT := swift
DOCKER := docker
PROJECT_NAME := PipelineKit
PLATFORM := $(shell uname -s)

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

.PHONY: help
help: ## Show this help message
	@echo "$(BLUE)$(PROJECT_NAME) Development Commands$(NC)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "$(GREEN)%-20s$(NC) %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the project
	@echo "$(BLUE)Building $(PROJECT_NAME)...$(NC)"
	$(SWIFT) build

.PHONY: build-release
build-release: ## Build the project in release mode
	@echo "$(BLUE)Building $(PROJECT_NAME) in release mode...$(NC)"
	$(SWIFT) build -c release

.PHONY: test
test: ## Run tests
	@echo "$(BLUE)Running tests...$(NC)"
	$(SWIFT) test

.PHONY: test-parallel
test-parallel: ## Run tests in parallel
	@echo "$(BLUE)Running tests in parallel...$(NC)"
	$(SWIFT) test --parallel

.PHONY: test-coverage
test-coverage: ## Run tests with code coverage
	@echo "$(BLUE)Running tests with coverage...$(NC)"
	$(SWIFT) test --enable-code-coverage
	@echo "$(GREEN)Coverage report generated$(NC)"

.PHONY: clean
clean: ## Clean build artifacts
	@echo "$(BLUE)Cleaning build artifacts...$(NC)"
	$(SWIFT) package clean
	rm -rf .build
	@echo "$(GREEN)Clean complete$(NC)"

.PHONY: format
format: ## Format code using SwiftFormat
	@echo "$(BLUE)Formatting code...$(NC)"
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat . --config .swiftformat; \
		echo "$(GREEN)Formatting complete$(NC)"; \
	else \
		echo "$(RED)SwiftFormat not installed. Install with: brew install swiftformat$(NC)"; \
		exit 1; \
	fi

.PHONY: lint
lint: ## Lint code using SwiftLint
	@echo "$(BLUE)Linting code...$(NC)"
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --config .swiftlint.yml; \
	else \
		echo "$(RED)SwiftLint not installed. Install with: brew install swiftlint$(NC)"; \
		exit 1; \
	fi

.PHONY: lint-fix
lint-fix: ## Auto-fix linting issues
	@echo "$(BLUE)Auto-fixing linting issues...$(NC)"
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint --fix --config .swiftlint.yml; \
		echo "$(GREEN)Auto-fix complete$(NC)"; \
	else \
		echo "$(RED)SwiftLint not installed. Install with: brew install swiftlint$(NC)"; \
		exit 1; \
	fi

.PHONY: generate-docs
generate-docs: ## Generate documentation
	@echo "$(BLUE)Generating documentation...$(NC)"
	@if command -v jazzy >/dev/null 2>&1; then \
		jazzy \
			--clean \
			--author "PipelineKit Contributors" \
			--module $(PROJECT_NAME) \
			--swift-build-tool spm \
			--build-tool-arguments -Xswiftc,-swift-version,-Xswiftc,5 \
			--output docs/api; \
		echo "$(GREEN)Documentation generated in docs/api$(NC)"; \
	else \
		echo "$(YELLOW)Jazzy not installed. Install with: gem install jazzy$(NC)"; \
		echo "$(BLUE)Trying swift-doc...$(NC)"; \
		if command -v swift-doc >/dev/null 2>&1; then \
			swift-doc generate Sources/$(PROJECT_NAME) \
				--module-name $(PROJECT_NAME) \
				--output docs/api \
				--format html; \
			echo "$(GREEN)Documentation generated in docs/api$(NC)"; \
		else \
			echo "$(RED)swift-doc not installed. Install with: brew install swift-doc$(NC)"; \
			exit 1; \
		fi \
	fi

.PHONY: benchmark
benchmark: ## Run performance benchmarks
	@echo "$(BLUE)Running benchmarks...$(NC)"
	$(SWIFT) run -c release PipelineKitBenchmarks

.PHONY: benchmark-compare
benchmark-compare: ## Run benchmarks and compare with baseline
	@echo "$(BLUE)Running benchmarks with comparison...$(NC)"
	$(SWIFT) run -c release PipelineKitBenchmarks --save-baseline

.PHONY: verify
verify: ## Verify the project (build, test, lint)
	@echo "$(BLUE)Verifying $(PROJECT_NAME)...$(NC)"
	@$(MAKE) clean
	@$(MAKE) build
	@$(MAKE) test
	@$(MAKE) lint
	@echo "$(GREEN)Verification complete!$(NC)"

.PHONY: pre-commit
pre-commit: ## Run pre-commit checks
	@echo "$(BLUE)Running pre-commit checks...$(NC)"
	@$(MAKE) format
	@$(MAKE) lint-fix
	@$(MAKE) test
	@echo "$(GREEN)Pre-commit checks passed!$(NC)"

.PHONY: docker-test
docker-test: ## Run tests in Docker
	@echo "$(BLUE)Running tests in Docker...$(NC)"
	$(DOCKER) run --rm \
		-v "$$(pwd):/workspace" \
		-w /workspace \
		swift:5.10 \
		swift test

.PHONY: install-hooks
install-hooks: ## Install git hooks
	@echo "$(BLUE)Installing git hooks...$(NC)"
	@mkdir -p .git/hooks
	@echo "#!/bin/sh\nmake pre-commit" > .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "$(GREEN)Git hooks installed$(NC)"

.PHONY: update-deps
update-deps: ## Update dependencies
	@echo "$(BLUE)Updating dependencies...$(NC)"
	$(SWIFT) package update

.PHONY: resolve-deps
resolve-deps: ## Resolve dependencies
	@echo "$(BLUE)Resolving dependencies...$(NC)"
	$(SWIFT) package resolve

.PHONY: show-deps
show-deps: ## Show dependency graph
	@echo "$(BLUE)Dependency graph:$(NC)"
	$(SWIFT) package show-dependencies

.PHONY: archive
archive: ## Create release archive
	@echo "$(BLUE)Creating release archive...$(NC)"
	$(SWIFT) build -c release --arch arm64 --arch x86_64
	@tar -czf $(PROJECT_NAME).tar.gz -C .build/release $(PROJECT_NAME)
	@echo "$(GREEN)Archive created: $(PROJECT_NAME).tar.gz$(NC)"

.PHONY: install
install: build-release ## Install to /usr/local/bin
	@echo "$(BLUE)Installing $(PROJECT_NAME)...$(NC)"
	@cp .build/release/$(PROJECT_NAME) /usr/local/bin/
	@echo "$(GREEN)$(PROJECT_NAME) installed to /usr/local/bin$(NC)"

.PHONY: uninstall
uninstall: ## Uninstall from /usr/local/bin
	@echo "$(BLUE)Uninstalling $(PROJECT_NAME)...$(NC)"
	@rm -f /usr/local/bin/$(PROJECT_NAME)
	@echo "$(GREEN)$(PROJECT_NAME) uninstalled$(NC)"

# Development shortcuts
.PHONY: d
d: build ## Alias for build

.PHONY: t
t: test ## Alias for test

.PHONY: c
c: clean ## Alias for clean

.PHONY: l
l: lint ## Alias for lint