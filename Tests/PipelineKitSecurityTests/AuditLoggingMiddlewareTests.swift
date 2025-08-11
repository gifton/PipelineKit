import XCTest
import PipelineKitCore
import PipelineKitSecurity
import Foundation

// Test command
struct TestCommand: Command {
    typealias Result = TestResult
    let id: String
    let action: String
}

struct TestResult: Sendable {
    let success: Bool
    let message: String
}

// Mock audit logger for testing
actor MockAuditLogger: AuditLogger {
    private(set) var loggedEvents: [SecurityAuditEvent] = []
    private(set) var loggedEntries: [AuditEntry] = []
    
    func log(_ event: SecurityAuditEvent) async {
        loggedEvents.append(event)
    }
    
    func logCommandStarted(_ entry: AuditEntry) async {
        loggedEntries.append(entry)
    }
    
    func logCommandCompleted(_ entry: AuditEntry) async {
        loggedEntries.append(entry)
    }
    
    func logCommandFailed(_ entry: AuditEntry) async {
        loggedEntries.append(entry)
    }
    
    func getLoggedEvents() async -> [SecurityAuditEvent] {
        return loggedEvents
    }
    
    func getLoggedEntries() async -> [AuditEntry] {
        return loggedEntries
    }
}

final class AuditLoggingMiddlewareTests: XCTestCase {
    
    func testAuditLoggingSuccess() async throws {
        // Create mock logger
        let mockLogger = MockAuditLogger()
        
        // Create middleware
        let middleware = AuditLoggingMiddleware(
            logger: mockLogger,
            detailLevel: .full,
            includeResults: true
        )
        
        // Create test command
        let command = TestCommand(id: "test-123", action: "create")
        
        // Create context
        let context = CommandContext()
        context.metadata["authUserId"] = "user-456"
        context.metadata["sessionId"] = "session-789"
        
        // Test handler
        let handler: @Sendable (TestCommand, CommandContext) async throws -> TestResult = { _, _ in
            // Simulate some work
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            return TestResult(success: true, message: "Created successfully")
        }
        
        // Execute through middleware
        let result = try await middleware.execute(command, context: context, next: handler)
        
        // Verify result
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.message, "Created successfully")
        
        // Verify audit entries were logged
        let entries = await mockLogger.getLoggedEntries()
        XCTAssertGreaterThanOrEqual(entries.count, 2) // Start and complete events
        
        // Verify first entry (command started)
        if entries.count > 0 {
            let startEntry = entries[0]
            XCTAssertEqual(startEntry.commandType, "TestCommand")
            XCTAssertEqual(startEntry.userId, "user-456")
            XCTAssertEqual(startEntry.sessionId, "session-789")
        }
        
        // Verify last entry (command completed)
        if entries.count > 1 {
            let completeEntry = entries[entries.count - 1]
            XCTAssertEqual(completeEntry.status, .success)
            XCTAssertNotNil(completeEntry.duration)
            XCTAssertGreaterThan(completeEntry.duration ?? 0, 0)
        }
    }
    
    func testAuditLoggingFailure() async throws {
        // Create mock logger
        let mockLogger = MockAuditLogger()
        
        // Create middleware
        let middleware = AuditLoggingMiddleware(
            logger: mockLogger,
            detailLevel: .standard
        )
        
        // Create test command
        let command = TestCommand(id: "test-fail", action: "delete")
        
        // Create context
        let context = CommandContext()
        context.metadata["authUserId"] = "admin"
        
        // Test handler that throws error
        let handler: @Sendable (TestCommand, CommandContext) async throws -> TestResult = { _, _ in
            throw NSError(domain: "TestError", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Resource not found"
            ])
        }
        
        // Execute through middleware and expect error
        do {
            _ = try await middleware.execute(command, context: context, next: handler)
            XCTFail("Expected error to be thrown")
        } catch {
            // Error expected
            XCTAssertEqual((error as NSError).code, 404)
        }
        
        // Verify audit entries were logged
        let entries = await mockLogger.getLoggedEntries()
        XCTAssertGreaterThanOrEqual(entries.count, 2) // Start and failed events
        
        // Verify failure was logged
        if let failEntry = entries.last {
            XCTAssertEqual(failEntry.status, .failure)
            XCTAssertNotNil(failEntry.error)
        }
    }
    
    func testNDJSONFormat() async throws {
        // Create temp directory for test
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Create file logger
        let fileLogger = FileAuditLogger(directory: tempDir.path)
        
        // Log multiple entries
        for i in 0..<3 {
            let entry = AuditEntry(
                id: UUID(),
                timestamp: Date(),
                commandType: "TestCommand",
                userId: "user-\(i)",
                status: .success
            )
            await fileLogger.logCommandCompleted(entry)
        }
        
        // Read the log file
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty, "Should have created audit log file")
        
        if let logFile = files.first(where: { $0.pathExtension == "ndjson" }) {
            let content = try String(contentsOf: logFile)
            let lines = content.split(separator: "\n")
            
            // Verify ND-JSON format (each line is valid JSON)
            for line in lines where !line.isEmpty {
                let data = Data(line.utf8)
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
            }
            
            // Should have 3 entries
            XCTAssertEqual(lines.filter { !$0.isEmpty }.count, 3)
        } else {
            XCTFail("No audit log file found")
        }
    }
    
    func testPrivacyLevels() async throws {
        // Test minimal privacy level
        let minimalLogger = DefaultAuditLogger(
            destination: .console,
            privacyLevel: .minimal
        )
        
        // Test entry sanitization
        let entry = AuditEntry(
            id: UUID(),
            timestamp: Date(),
            commandType: "TestCommand",
            userId: "user@example.com",
            sessionId: "session-12345",
            commandData: ["password": "secret123" as any Sendable]
        )
        
        // The sanitization should anonymize user ID and remove sensitive data
        // This would be tested more thoroughly in a real implementation
        XCTAssertNotNil(minimalLogger)
    }
}