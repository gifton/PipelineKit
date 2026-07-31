# PipelineKit Documentation

Index of the documentation tree. New to the project? Start with the
[repository README](../README.md), then the quick start below.

## User documentation

API reference for all seven modules, regenerated on every push to main:
https://gifton.github.io/PipelineKit/

| Path | What it covers |
|------|----------------|
| [getting-started/quick-start.md](getting-started/quick-start.md) | Your first command, handler, and pipeline |
| [getting-started/installation.md](getting-started/installation.md) | Installing via Swift Package Manager |
| [guides/architecture.md](guides/architecture.md) | How the pieces fit together |
| [guides/performance.md](guides/performance.md) | Performance guidance |
| [guides/resilience-patterns.md](guides/resilience-patterns.md) | Resilience middleware: rate limiting, circuit breakers, bulkheads, retries |
| [guides/security-best-practices.md](guides/security-best-practices.md) | Hardening guidance: validation, authorization, rate limiting, encryption, audit logging |
| [guides/command-bus/](guides/command-bus/) | The command-bus book — an in-depth, multi-chapter guide |
| [tutorials/](tutorials/) | Basic usage, custom middleware, advanced patterns |
| [CONCURRENCY.md](CONCURRENCY.md) | The concurrency model and its guarantees |
| [benchmarks.md](benchmarks.md) | Performance-test methodology and how to run the suite |

Project-level documents live at the repository root: [CHANGELOG](../CHANGELOG.md),
[CONTRIBUTING](../CONTRIBUTING.md), [CODE_OF_CONDUCT](../CODE_OF_CONDUCT.md),
[SECURITY](../SECURITY.md), [DEPENDENCIES](../DEPENDENCIES.md),
[VERSIONING](../VERSIONING.md).

## Maintainer / internal

Not user documentation — these describe process, point-in-time audits, and ideas
that may never ship. Nothing in here is a statement about current capabilities.

| Path | What it is |
|------|------------|
| [internal/](internal/) | Historical audits, wishlists, and design notes |
| [superpowers/](superpowers/) | Specs and plans used by the automated development workflow |
