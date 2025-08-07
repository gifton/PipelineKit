import XCTest
import PipelineKitCore
@testable import PipelineKitObservability

final class LoggingMiddlewareTests: XCTestCase {
    
    // MARK: - Test Types
    
    struct TestCommand: Command {
        typealias Result = String
        let id: String
        let value: String
        
        func execute() async throws -> String {
            value
        }
    }
    
    struct FailingCommand: Command {
        typealias Result = String
        let error: Error
        
        func execute() async throws -> String {
            throw error
        }
    }
    
    struct SensitiveCommand: Command, LoggingSensitive {
        typealias Result = String
        let password: String
        let publicData: String
        
        func execute() async throws -> String {
            publicData
        }
        
        var sensitiveProperties: Set<String> {
            ["password"]
        }
    }
    
    enum TestError: Error {
        case expectedError
        case criticalError
    }
    
    // MARK: - Test Logger
    
    class TestLogger: Logger {
        var loggedMessages: [(level: LogLevel, message: String, metadata: [String: Any])] = []
        
        func log(
            level: LogLevel,
            message: String,
            metadata: [String: Any],
            source: String,
            file: String,
            function: String,
            line: UInt
        ) {
            loggedMessages.append((level, message, metadata))
        }
    }
    
    // MARK: - Tests
    
    func testSuccessfulCommandLogging() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(logger: logger)
        let command = TestCommand(id: "test-1", value: "Success")
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertEqual(result, "Success")
        XCTAssertEqual(logger.loggedMessages.count, 2)
        
        // Check start log
        let startLog = logger.loggedMessages[0]
        XCTAssertEqual(startLog.level, .info)
        XCTAssertTrue(startLog.message.contains("Executing command"))
        XCTAssertEqual(startLog.metadata["commandType"] as? String, "TestCommand")
        XCTAssertEqual(startLog.metadata["commandId"] as? String, "test-1")
        
        // Check completion log
        let endLog = logger.loggedMessages[1]
        XCTAssertEqual(endLog.level, .info)
        XCTAssertTrue(endLog.message.contains("completed successfully"))
        XCTAssertNotNil(endLog.metadata["duration"])
    }
    
    func testFailedCommandLogging() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(logger: logger)
        let command = FailingCommand(error: TestError.expectedError)
        let context = CommandContext()
        
        // When
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Expected error")
        } catch {
            // Expected
        }
        
        // Then
        XCTAssertEqual(logger.loggedMessages.count, 2)
        
        // Check error log
        let errorLog = logger.loggedMessages[1]
        XCTAssertEqual(errorLog.level, .error)
        XCTAssertTrue(errorLog.message.contains("failed"))
        XCTAssertNotNil(errorLog.metadata["error"])
        XCTAssertNotNil(errorLog.metadata["duration"])
    }
    
    func testSensitiveDataFiltering() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(
            configuration: LoggingMiddleware.Configuration(
                logLevel: .debug,
                filterSensitiveData: true
            ),
            logger: logger
        )
        
        let command = SensitiveCommand(
            password: "secret123",
            publicData: "public"
        )
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then
        let logs = logger.loggedMessages
        for log in logs {
            // Password should be redacted
            XCTAssertFalse(log.message.contains("secret123"))
            
            // Check metadata doesn't contain password
            for (_, value) in log.metadata {
                if let stringValue = value as? String {
                    XCTAssertFalse(stringValue.contains("secret123"))
                }
            }
        }
    }
    
    func testLogLevelFiltering() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(
            configuration: LoggingMiddleware.Configuration(
                logLevel: .warning
            ),
            logger: logger
        )
        
        let command = TestCommand(id: "test", value: "Success")
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then - info logs should be filtered out
        XCTAssertEqual(logger.loggedMessages.count, 0)
        
        // When - error occurs
        let failingCommand = FailingCommand(error: TestError.expectedError)
        _ = try? await middleware.execute(failingCommand, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then - error log should appear
        XCTAssertEqual(logger.loggedMessages.count, 1)
        XCTAssertEqual(logger.loggedMessages[0].level, .error)
    }
    
    func testIncludeContext() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(
            configuration: LoggingMiddleware.Configuration(
                includeContext: true
            ),
            logger: logger
        )
        
        let command = TestCommand(id: "test", value: "Success")
        let context = CommandContext()
        context.metadata["userId"] = "user123"
        context.metadata["tenantId"] = "tenant456"
        context.requestID = "req-789"
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then
        let logs = logger.loggedMessages
        XCTAssertGreaterThan(logs.count, 0)
        
        for log in logs {
            XCTAssertEqual(log.metadata["requestId"] as? String, "req-789")
            XCTAssertEqual(log.metadata["userId"] as? String, "user123")
            XCTAssertEqual(log.metadata["tenantId"] as? String, "tenant456")
        }
    }
    
    func testIncludeStackTrace() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(
            configuration: LoggingMiddleware.Configuration(
                includeStackTrace: true
            ),
            logger: logger
        )
        
        let command = FailingCommand(error: TestError.expectedError)
        let context = CommandContext()
        
        // When
        _ = try? await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then
        let errorLog = logger.loggedMessages.last
        XCTAssertNotNil(errorLog)
        XCTAssertNotNil(errorLog?.metadata["stackTrace"])
    }
    
    func testCustomFormatter() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(
            configuration: LoggingMiddleware.Configuration(
                formatter: { level, message, metadata in
                    var formattedMetadata = metadata
                    formattedMetadata["customField"] = "customValue"
                    formattedMetadata["level"] = level.rawValue.uppercased()
                    return (message.uppercased(), formattedMetadata)
                }
            ),
            logger: logger
        )
        
        let command = TestCommand(id: "test", value: "Success")
        
        // When
        _ = try await middleware.execute(command, context: CommandContext()) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then
        let logs = logger.loggedMessages
        for log in logs {
            XCTAssertTrue(log.message == log.message.uppercased())
            XCTAssertEqual(log.metadata["customField"] as? String, "customValue")
            XCTAssertNotNil(log.metadata["level"])
        }
    }
    
    func testStructuredLogging() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(logger: logger)
        
        let command = TestCommand(id: "cmd-123", value: "Result")
        let context = CommandContext()
        context.requestID = "req-456"
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then - verify structured data
        let startLog = logger.loggedMessages[0]
        XCTAssertEqual(startLog.metadata["commandType"] as? String, "TestCommand")
        XCTAssertEqual(startLog.metadata["commandId"] as? String, "cmd-123")
        XCTAssertEqual(startLog.metadata["requestId"] as? String, "req-456")
        
        let endLog = logger.loggedMessages[1]
        XCTAssertNotNil(endLog.metadata["duration"])
        XCTAssertEqual(endLog.metadata["status"] as? String, "success")
    }
    
    func testPerformanceLogging() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(
            configuration: LoggingMiddleware.Configuration(
                logLevel: .debug,
                slowExecutionThreshold: 0.01 // 10ms
            ),
            logger: logger
        )
        
        struct SlowCommand: Command {
            typealias Result = String
            
            func execute() async throws -> String {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                return "Done"
            }
        }
        
        // When
        _ = try await middleware.execute(SlowCommand(), context: CommandContext()) { cmd, _ in
            try await cmd.execute()
        }
        
        // Then - should have warning about slow execution
        let logs = logger.loggedMessages
        let slowLog = logs.first { log in
            log.level == .warning && log.message.contains("slow")
        }
        XCTAssertNotNil(slowLog)
    }
    
    func testLogSampling() async throws {
        // Given
        let logger = TestLogger()
        let middleware = LoggingMiddleware(
            configuration: LoggingMiddleware.Configuration(
                samplingRate: 0.5 // 50% sampling
            ),
            logger: logger
        )
        
        // When - execute many commands
        let iterations = 100
        for i in 0..<iterations {
            _ = try await middleware.execute(
                TestCommand(id: "\(i)", value: "Success"),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }
        
        // Then - roughly 50% should be logged
        let logCount = logger.loggedMessages.count
        let expectedCount = iterations // Each execution logs twice when sampled
        XCTAssertGreaterThan(logCount, expectedCount / 4)
        XCTAssertLessThan(logCount, expectedCount * 3)
    }
}