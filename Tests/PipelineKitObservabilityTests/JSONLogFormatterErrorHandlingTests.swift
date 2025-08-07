import XCTest
@testable import PipelineKitObservability
import PipelineKitCore
import Foundation

final class JSONLogFormatterErrorHandlingTests: XCTestCase {
    
    // MARK: - Error Handling Tests
    
    func testErrorHandlingWithoutRecursion() async throws {
        // This test verifies that JSON encoding errors are handled without recursion
        // by writing to stderr instead of trying to log through the formatter again
        
        let formatter = JSONLogFormatter()
        
        // Create a command that will cause encoding to fail
        let problematicCommand = ProblematicCommand()
        let context = CommandContext()
        context.metadata["request_id"] = "test-123"
        
        // Capture stderr output
        let pipe = Pipe()
        let originalStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        
        // Format command start - this should fail encoding and write to stderr
        let result = formatter.formatCommandStart(
            commandType: "ProblematicCommand",
            requestId: "test-123",
            command: problematicCommand,
            context: context
        )
        
        // Restore stderr
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)
        
        // Read captured stderr
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderrOutput = String(data: data, encoding: .utf8) ?? ""
        
        // Verify error was written to stderr
        XCTAssertTrue(stderrOutput.contains("JSONLogFormatter.formatCommandStart encoding error"))
        
        // Verify fallback JSON was returned
        XCTAssertTrue(result.contains("\"error\":\"encoding_failed\""))
        XCTAssertTrue(result.contains("\"event\":\"command_start\""))
        XCTAssertTrue(result.contains("\"type\":"))
    }
    
    func testSuccessFormatting() async throws {
        let formatter = JSONLogFormatter()
        
        // Test normal success case
        let command = TestCommand(value: 42)
        let context = CommandContext()
        context.metadata["request_id"] = "success-test"
        context.metrics["latency"] = 123.45
        context.metrics["count"] = 10
        
        let result = formatter.formatCommandSuccess(
            commandType: "TestCommand",
            requestId: "success-test",
            result: "Success",
            duration: 0.150,
            context: context
        )
        
        // Parse the JSON to verify it's valid
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse JSON output")
            return
        }
        
        // Verify required fields
        XCTAssertEqual(json["event"] as? String, "command_success")
        XCTAssertEqual(json["command_type"] as? String, "TestCommand")
        XCTAssertEqual(json["request_id"] as? String, "success-test")
        XCTAssertEqual(json["duration_ms"] as? Double, 150.0)
        
        // Verify metrics were included
        let metrics = json["metrics"] as? [String: Double] ?? [:]
        XCTAssertEqual(metrics["latency"], 123.45)
        XCTAssertEqual(metrics["count"], 10.0)
    }
    
    func testFailureFormatting() async throws {
        let formatter = JSONLogFormatter()
        
        // Test failure case
        let command = TestCommand(value: 99)
        let context = CommandContext()
        context.metadata["request_id"] = "failure-test"
        context.metadata["user_id"] = "user-123"
        context.metadata["session_id"] = "session-456"
        
        let error = PipelineError.middleware(reason: .conditionNotMet("Test failure"))
        
        let result = formatter.formatCommandFailure(
            commandType: "TestCommand",
            requestId: "failure-test",
            error: error,
            duration: 0.025,
            context: context
        )
        
        // Parse the JSON
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse JSON output")
            return
        }
        
        // Verify required fields
        XCTAssertEqual(json["event"] as? String, "command_failure")
        XCTAssertEqual(json["command_type"] as? String, "TestCommand")
        XCTAssertEqual(json["request_id"] as? String, "failure-test")
        XCTAssertEqual(json["duration_ms"] as? Double, 25.0)
        XCTAssertNotNil(json["error"] as? String)
        XCTAssertEqual(json["error_type"] as? String, "PipelineError")
        
        // Verify metadata
        let metadata = json["metadata"] as? [String: String] ?? [:]
        XCTAssertEqual(metadata["user_id"], "user-123")
        XCTAssertEqual(metadata["session_id"], "session-456")
    }
    
    func testMetadataConversion() async throws {
        let formatter = JSONLogFormatter()
        
        // Test various metadata types
        let context = CommandContext()
        context.metadata["string"] = "test"
        context.metadata["bool"] = true
        context.metadata["int"] = 42
        context.metadata["double"] = 3.14159
        context.metadata["date"] = Date(timeIntervalSince1970: 1234567890)
        
        let result = formatter.formatCommandStart(
            commandType: "MetadataTest",
            requestId: "metadata-test",
            command: TestCommand(value: 1),
            context: context
        )
        
        // Parse JSON
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse JSON output")
            return
        }
        
        let metadata = json["metadata"] as? [String: String] ?? [:]
        XCTAssertEqual(metadata["string"], "test")
        XCTAssertEqual(metadata["bool"], "true")
        XCTAssertEqual(metadata["int"], "42")
        XCTAssertEqual(metadata["double"], "3.14159")
        XCTAssertTrue(metadata["date"]?.contains("2009-02-13") == true) // Unix timestamp 1234567890
    }
    
    func testConcurrentFormatting() async throws {
        // Test that the formatter works correctly under concurrent access
        let formatter = JSONLogFormatter()
        let iterations = 100
        
        await withTaskGroup(of: String.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let context = CommandContext()
                    context.metadata["request_id"] = "concurrent-\(i)"
                    
                    return formatter.formatCommandStart(
                        commandType: "ConcurrentTest",
                        requestId: "concurrent-\(i)",
                        command: TestCommand(value: i),
                        context: context
                    )
                }
            }
            
            var results: [String] = []
            for await result in group {
                results.append(result)
            }
            
            // Verify all results are valid JSON
            XCTAssertEqual(results.count, iterations)
            for result in results {
                guard let data = result.data(using: .utf8),
                      let _ = try? JSONSerialization.jsonObject(with: data) else {
                    XCTFail("Invalid JSON in concurrent result: \(result)")
                    return
                }
            }
        }
    }
}

// MARK: - Test Helpers

private struct TestCommand: Command {
    let value: Int
    
    struct Result: Sendable {
        let output: String
    }
    
    func execute(context: CommandContext) async throws -> Result {
        return Result(output: "Value: \(value)")
    }
}

// Command that causes encoding to fail
private struct ProblematicCommand: Command {
    // This will cause encoding to fail because of the non-encodable closure
    let problematicValue: () -> Void = { print("This can't be encoded") }
    
    struct Result: Sendable {
        let output: String
    }
    
    func execute(context: CommandContext) async throws -> Result {
        return Result(output: "Should not execute")
    }
}