import XCTest
import Foundation
@testable import PipelineKit
@testable import StressTestSupport

// NOTE: This file requires PipelineKitStressTest types which have been
// moved to a separate package. It should be moved to that package's test suite.
/*
/// Quick validation tests for the improvements
@MainActor
*/
final class ValidationTests: XCTestCase {
    
    func testPlaceholder() {
        // Placeholder test to prevent empty test class
        XCTAssertTrue(true)
    }
    
    /*
    func testClosureScenarioNoLongerCrashes() async throws {
        // This test validates that ClosureScenario no longer has weak reference issues
        let harness = ScenarioTestHarness()
        
        // This should not crash even if TestContext is deallocated
        let result = try await harness
            .withContext { builder in
                builder.safetyLimits(.conservative)
            }
            .runAsync("Test No Crash") { context in
                // Access context - should not be nil
                XCTAssertNotNil(context)
                try await Task.sleep(nanoseconds: 100_000)
            }
        
        XCTAssertTrue(result.passed)
    }
    
    func testDateFormatterPerformance() {
        // This test validates that DateFormatter is now static
        let formatter1 = DefaultLogFormatter()
        let formatter2 = DefaultLogFormatter()
        
        // Both should use the same static DateFormatter instance
        // We can't directly test this, but we can measure performance
        let startTime = Date()
        
        for _ in 0..<1000 {
            let entry = LogEntry(
                timestamp: Date(),
                level: .info,
                message: "Test message",
                file: "test.swift",
                function: "test",
                line: 42,
                threadId: "main"
            )
            _ = formatter1.format(entry)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        // With static formatter, this should be fast (less than 0.5 seconds for 1000 formats)
        XCTAssertLessThan(duration, 0.5, "Formatting should be fast with static DateFormatter")
    }
    
    func testTypeSafeMetrics() {
        // Test the new type-safe metrics wrapper
        var metrics = TypedMetrics()
        
        // Set different types of metrics
        metrics.set(.cpuUsage, value: .double(45.5))
        metrics.set(.memoryUsage, value: .integer(1024 * 1024))
        metrics.set(.activeTasks, value: .integer(10))
        metrics.set(.custom("user_id"), value: .string("test-user"))
        
        // Retrieve with type safety
        XCTAssertEqual(metrics.doubleValue(for: .cpuUsage), 45.5)
        XCTAssertEqual(metrics.intValue(for: .memoryUsage), 1024 * 1024)
        XCTAssertEqual(metrics.intValue(for: .activeTasks), 10)
        XCTAssertEqual(metrics.stringValue(for: .custom("user_id")), "test-user")
    }
    
    func testAsyncFileLogOutput() async throws {
        // Test async file output
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).log")
        
        let output = try AsyncFileLogOutput(fileURL: tempFile)
        
        // Write some messages
        for i in 0..<10 {
            output.write("Test message \(i)")
        }
        
        // Force flush and wait
        await output.forceFlush()
        
        // Check file was written
        let content = try String(contentsOf: tempFile)
        XCTAssertTrue(content.contains("Test message 0"))
        XCTAssertTrue(content.contains("Test message 9"))
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempFile)
    }
    
    func testLogSanitization() {
        // Test log sanitization
        let baseFormatter = CompactLogFormatter()
        let sanitizer = SanitizingLogFormatter(baseFormatter: baseFormatter)
        
        let entry = LogEntry(
            timestamp: Date(),
            level: .error,
            message: "Failed to authenticate with api_key=sk-1234567890abcdef and password=secret123",
            file: "auth.swift",
            function: "authenticate",
            line: 100,
            threadId: "main"
        )
        
        let formatted = sanitizer.format(entry)
        
        // Check that sensitive data is redacted
        XCTAssertTrue(formatted.contains("[REDACTED]"))
        XCTAssertFalse(formatted.contains("sk-1234567890abcdef"))
        XCTAssertFalse(formatted.contains("secret123"))
    }
    */
}