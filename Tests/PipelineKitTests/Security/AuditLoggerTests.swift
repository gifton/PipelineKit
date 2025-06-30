import XCTest
@testable import PipelineKit

final class AuditLoggerTests: XCTestCase {
    
    // MARK: - Basic Logging Tests
    
    func testConsoleLogging() async throws {
        let logger = AuditLogger(
            destination: .console,
            privacyLevel: .full,
            bufferSize: 2
        )
        
        let entry1 = AuditEntry(
            commandType: "TestCommand",
            userId: "user123",
            success: true,
            duration: 0.5
        )
        
        let entry2 = AuditEntry(
            commandType: "TestCommand",
            userId: "user456",
            success: false,
            duration: 0.3,
            errorType: "TestError"
        )
        
        await logger.log(entry1)
        await logger.log(entry2) // Should trigger flush
    }
    
    func testFileLogging() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let logFile = tempDir.appendingPathComponent("test-audit.json")
        
        // Clean up any existing file
        try? FileManager.default.removeItem(at: logFile)
        
        let logger = AuditLogger(
            destination: .file(url: logFile),
            privacyLevel: .full,
            bufferSize: 10
        )
        
        // Log some entries
        for i in 0..<5 {
            let entry = AuditEntry(
                commandType: "Command\(i)",
                userId: "user\(i)",
                success: i % 2 == 0,
                duration: Double(i) * 0.1
            )
            await logger.log(entry)
        }
        
        // Force flush
        await logger.flush()
        
        // Verify file contents
        let data = try Data(contentsOf: logFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([AuditEntry].self, from: data)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries[0].commandType, "Command0")
        XCTAssertEqual(entries[4].userId, "user4")
        
        // Clean up
        try? FileManager.default.removeItem(at: logFile)
    }
    
    func testCustomDestination() async throws {
        let expectation = XCTestExpectation(description: "Custom handler called")
        let collector = EntriesCollector()
        
        let logger = AuditLogger(
            destination: .custom { entries in
                await collector.add(entries)
                expectation.fulfill()
            },
            privacyLevel: .full,
            bufferSize: 3
        )
        
        // Log entries
        for i in 0..<3 {
            let entry = AuditEntry(
                commandType: "Command\(i)",
                userId: "user\(i)",
                success: true,
                duration: 0.1
            )
            await logger.log(entry)
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
        let receivedEntries = await collector.getEntries()
        XCTAssertEqual(receivedEntries.count, 3)
    }
    
    // MARK: - Privacy Level Tests
    
    func testPrivacyMasking() async throws {
        let expectation = XCTestExpectation(description: "Entries logged")
        let collector = EntriesCollector()
        
        let logger = AuditLogger(
            destination: .custom { entries in
                await collector.add(entries)
                expectation.fulfill()
            },
            privacyLevel: .masked,
            bufferSize: 1
        )
        
        let entry = AuditEntry(
            commandType: "TestCommand",
            userId: "user123456",
            success: true,
            duration: 0.5,
            metadata: ["apiKey": "secret123456", "short": "abc"]
        )
        
        await logger.log(entry)
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        let loggedEntries = await collector.getEntries()
        let maskedEntry = loggedEntries[0]
        XCTAssertEqual(maskedEntry.commandType, "TestCommand") // Not masked
        XCTAssertEqual(maskedEntry.userId, "us***56") // Masked
        XCTAssertEqual(maskedEntry.metadata["apiKey"], "sec***456") // Masked
        XCTAssertEqual(maskedEntry.metadata["short"], "***") // Fully masked
    }
    
    func testPrivacyMinimal() async throws {
        let expectation = XCTestExpectation(description: "Entries logged")
        let collector = EntriesCollector()
        
        let logger = AuditLogger(
            destination: .custom { entries in
                await collector.add(entries)
                expectation.fulfill()
            },
            privacyLevel: .minimal,
            bufferSize: 1
        )
        
        let entry = AuditEntry(
            commandType: "TestCommand",
            userId: "user123456",
            success: true,
            duration: 0.5,
            metadata: ["apiKey": "secret123456"]
        )
        
        await logger.log(entry)
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        let loggedEntries = await collector.getEntries()
        let minimalEntry = loggedEntries[0]
        XCTAssertEqual(minimalEntry.userId, "anonymous")
        XCTAssertTrue(minimalEntry.metadata.isEmpty)
    }
    
    // MARK: - Query Tests
    
    func testAuditQuery() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let logFile = tempDir.appendingPathComponent("test-query.json")
        
        // Clean up any existing file
        try? FileManager.default.removeItem(at: logFile)
        
        let logger = AuditLogger(
            destination: .file(url: logFile),
            privacyLevel: .full
        )
        
        // Create test entries
        let now = Date()
        let entries = [
            AuditEntry(
                timestamp: now.addingTimeInterval(-3600),
                commandType: "CommandA",
                userId: "user1",
                success: true,
                duration: 0.1
            ),
            AuditEntry(
                timestamp: now.addingTimeInterval(-1800),
                commandType: "CommandB",
                userId: "user2",
                success: false,
                duration: 0.2
            ),
            AuditEntry(
                timestamp: now,
                commandType: "CommandA",
                userId: "user1",
                success: true,
                duration: 0.15
            )
        ]
        
        for entry in entries {
            await logger.log(entry)
        }
        await logger.flush()
        
        // Query by user
        let userResults = await logger.query(
            AuditQueryCriteria(userId: "user1")
        )
        XCTAssertEqual(userResults.count, 2)
        
        // Query by command type
        let commandResults = await logger.query(
            AuditQueryCriteria(commandType: "CommandB")
        )
        XCTAssertEqual(commandResults.count, 1)
        
        // Query by success
        let failureResults = await logger.query(
            AuditQueryCriteria(success: false)
        )
        XCTAssertEqual(failureResults.count, 1)
        
        // Query by date range
        let dateResults = await logger.query(
            AuditQueryCriteria(
                startDate: now.addingTimeInterval(-2000),
                endDate: now.addingTimeInterval(-1000)
            )
        )
        XCTAssertEqual(dateResults.count, 1)
        
        // Clean up
        try? FileManager.default.removeItem(at: logFile)
    }
    
    // MARK: - Middleware Tests
    
    func testAuditLoggingMiddleware() async throws {
        let expectation = XCTestExpectation(description: "Audit logged")
        let collector = EntriesCollector()
        
        let auditLogger = AuditLogger(
            destination: .custom { entries in
                await collector.add(entries)
                expectation.fulfill()
            },
            privacyLevel: .full,
            bufferSize: 1
        )
        
        let middleware = AuditLoggingMiddleware(
            logger: auditLogger,
            metadataExtractor: { command, _ in
                if let cmd = command as? TestCommand {
                    return ["value": cmd.value]
                }
                return [:]
            }
        )
        
        let command = TestCommand(value: "test123")
        let context = await CommandContext.test(userId: "testuser")
        
        let result = try await middleware.execute(command, context: context) { _, _ in
            "Success"
        }
        
        XCTAssertEqual(result, "Success")
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        let loggedEntries = await collector.getEntries()
        XCTAssertEqual(loggedEntries.count, 1)
        let entry = loggedEntries[0]
        XCTAssertEqual(entry.commandType, "TestCommand")
        XCTAssertEqual(entry.userId, "testuser")
        XCTAssertTrue(entry.success)
        XCTAssertEqual(entry.metadata["value"], "test123")
    }
    
    func testAuditLoggingMiddlewareWithError() async throws {
        let expectation = XCTestExpectation(description: "Audit logged")
        let collector = EntriesCollector()
        
        let auditLogger = AuditLogger(
            destination: .custom { entries in
                await collector.add(entries)
                expectation.fulfill()
            },
            privacyLevel: .full,
            bufferSize: 1
        )
        
        let middleware = AuditLoggingMiddleware(logger: auditLogger)
        
        let command = TestCommand(value: "fail")
        let context = await CommandContext.test(userId: "testuser")
        
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                throw TestError.middlewareFailed
            }
            XCTFail("Expected error")
        } catch {
            // Expected
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        let loggedEntries = await collector.getEntries()
        XCTAssertEqual(loggedEntries.count, 1)
        let entry = loggedEntries[0]
        XCTAssertFalse(entry.success)
        XCTAssertEqual(entry.errorType, "TestError")
    }
    
    // MARK: - Statistics Tests
    
    func testAuditStatistics() {
        let entries = [
            AuditEntry(
                commandType: "CommandA",
                userId: "user1",
                success: true,
                duration: 0.5
            ),
            AuditEntry(
                commandType: "CommandA",
                userId: "user1",
                success: true,
                duration: 0.3
            ),
            AuditEntry(
                commandType: "CommandB",
                userId: "user2",
                success: false,
                duration: 0.8,
                errorType: "ValidationError"
            ),
            AuditEntry(
                commandType: "CommandA",
                userId: "user2",
                success: true,
                duration: 0.4
            ),
            AuditEntry(
                commandType: "CommandC",
                userId: "user1",
                success: false,
                duration: 1.0,
                errorType: "ValidationError"
            )
        ]
        
        let stats = AuditStatistics.calculate(from: entries)
        
        XCTAssertEqual(stats.totalCommands, 5)
        XCTAssertEqual(stats.successCount, 3)
        XCTAssertEqual(stats.failureCount, 2)
        XCTAssertEqual(stats.successRate, 0.6, accuracy: 0.01)
        XCTAssertEqual(stats.averageDuration, 0.6, accuracy: 0.01)
        
        XCTAssertEqual(stats.commandCounts["CommandA"], 3)
        XCTAssertEqual(stats.commandCounts["CommandB"], 1)
        XCTAssertEqual(stats.commandCounts["CommandC"], 1)
        
        XCTAssertEqual(stats.errorCounts["ValidationError"], 2)
        
        XCTAssertEqual(stats.userActivity["user1"], 3)
        XCTAssertEqual(stats.userActivity["user2"], 2)
    }
    
    // MARK: - Log Rotation Tests
    
    func testLogRotation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let logFile = tempDir.appendingPathComponent("test-rotation.json")
        
        // Clean up any existing files
        try? FileManager.default.removeItem(at: logFile)
        
        let logger = AuditLogger(
            destination: .file(url: logFile),
            privacyLevel: .full,
            bufferSize: 1 // Small buffer to force immediate writes
        )
        
        // Create entries to write directly
        var entries: [AuditEntry] = []
        for i in 0..<10000 {
            entries.append(AuditEntry(
                commandType: "Command\(i % 10)",
                userId: "user\(i % 100)",
                success: true,
                duration: 0.1
            ))
        }
        
        // Write entries directly to file to simulate existing log
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: logFile)
        
        // Now log one more entry to trigger rotation
        await logger.log(AuditEntry(
            commandType: "TriggerRotation",
            userId: "user",
            success: true,
            duration: 0.1
        ))
        await logger.flush()
        
        // Check that rotation occurred
        let files = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.starts(with: "audit-") }
        
        XCTAssertTrue(files.count >= 1, "Expected at least one rotated archive file")
        
        // Verify main log file still exists and has entries
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path))
        
        // Clean up
        try? FileManager.default.removeItem(at: logFile)
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
    
    // MARK: - Test Helpers
    
    struct TestCommand: Command {
        let value: String
        typealias Result = String
        
        func execute() async throws -> String {
            return "Executed: \(value)"
        }
    }
    
    actor EntriesCollector {
        private var entries: [AuditEntry] = []
        
        func add(_ newEntries: [AuditEntry]) {
            entries.append(contentsOf: newEntries)
        }
        
        func getEntries() -> [AuditEntry] {
            entries
        }
    }
}