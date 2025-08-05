import XCTest
@testable import PipelineKit

// This file validates that our SwiftLint rules are properly configured
// It contains examples that SHOULD trigger warnings when SwiftLint is run

final class SwiftLintRuleValidationTests: XCTestCase {
    func testSwiftLintRules() {
        // This test just ensures the file compiles
        // The actual validation happens when SwiftLint runs
        XCTAssertTrue(true)
    }
}

// MARK: - Examples that should trigger SwiftLint warnings

// Example 1: @unchecked Sendable without documentation
// This SHOULD trigger: "Undocumented @unchecked Sendable"
struct BadExample1: @unchecked Sendable {
    let value: Any
}

// Example 2: @unchecked Sendable with Thread Safety but no Invariant
// This SHOULD trigger: "Missing Thread Safety Invariant"
/// Thread Safety: This is thread-safe because reasons
struct BadExample2: @unchecked Sendable {
    let value: Any
}

// Example 3: Correct usage - should NOT trigger warnings
/// Thread Safety: This type uses @unchecked Sendable for the following reasons:
/// 1. The stored value is immutable
/// 2. Thread Safety Invariant: The value property must only contain
///    immutable types or value types with Sendable semantics
struct GoodExample: @unchecked Sendable {
    let value: Any
}
