# Disabled Tests Documentation

This document tracks all tests that are currently disabled in the PipelineKit project and the reasons for their disability.

## AsyncSemaphore Tests

**Files:**
- `/Tests/PipelineKitTests/Pipeline/AsyncSemaphoreTests.swift`
- `/Tests/PipelineKitTests/Pipeline/AsyncSemaphoreTimeoutTests.swift`
- `/Tests/PipelineKitTests/Pipeline/BackPressureAsyncSemaphoreTests.swift`
- `/Tests/PipelineKitTests/Pipeline/BackPressureAsyncSemaphoreTimeoutTests.swift`

**Reason:** Swift compiler bug with actor method visibility in test targets

**Details:** The `acquire(timeout:)` method exists and is marked as public on the AsyncSemaphore and BackPressureAsyncSemaphore actors, but the Swift compiler does not make these methods visible to test targets. This appears to be a known issue with actor method visibility across module boundaries in test configurations.

**Resolution:** These tests should be re-enabled once the Swift compiler issue is resolved in a future Swift version.

## PipelineBuilderDSLTests

**File:** `/Tests/PipelineKitTests/DSL/PipelineBuilderDSLTests.swift`

**Reason:** DSL features were removed from the API

**Details:** The DSL features including `when`, `retry`, and `CreatePipeline` were removed as part of the API simplification in Phase 3.1. These tests are no longer applicable to the current API.

**Resolution:** These tests should be deleted rather than re-enabled, as they test features that no longer exist.

## PipelineMacrosTests

**File:** `/Tests/PipelineMacrosTests/PipelineMacroTests.swift`

**Reason:** Platform compatibility

**Details:** These tests use `XCTSkip` when macros are not available on the current platform. This is a legitimate use of conditional test execution.

**Resolution:** No action needed - these tests run when the platform supports macros.

## Tracking

Last updated: 2025-08-02

To check current status of disabled tests:
```bash
grep -r "DISABLED:" Tests/ --include="*.swift"
grep -r "XCTSkip" Tests/ --include="*.swift"
```