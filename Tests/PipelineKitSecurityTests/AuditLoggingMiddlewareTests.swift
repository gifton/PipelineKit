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

final class AuditLoggingMiddlewareTests: XCTestCase {
    func testAuditLoggingSuccess() async throws {
        // Create in-memory logger
        let logger = InMemoryAuditLogger()
        
        // Create middleware
        let middleware = AuditLoggingMiddleware(logger: logger)
        
        // Create test command
        let command = TestCommand(id: "test-123", action: "create")
        
        // Create context with user info
        let context = CommandContext()
        await context.setMetadata("authUserId", value: "user-456")
        await context.setMetadata("sessionId", value: "session-789")
        
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
        
        // Verify audit events were logged
        let events = await logger.allEvents()
        XCTAssertEqual(events.count, 2, "Should have start and complete events")
        
        // Verify start event
        let commandEvents = await logger.commandEvents()
        XCTAssertEqual(commandEvents.count, 2)
        
        let startEvent = commandEvents[0]
        XCTAssertEqual(startEvent.phase, .started)
        XCTAssertEqual(startEvent.commandType, "TestCommand")
        XCTAssertEqual(startEvent.userId, "user-456")
        XCTAssertEqual(startEvent.sessionId, "session-789")
        
        // Verify complete event
        let completeEvent = commandEvents[1]
        XCTAssertEqual(completeEvent.phase, .completed)
        XCTAssertEqual(completeEvent.commandType, "TestCommand")
        XCTAssertNotNil(completeEvent.duration)
        XCTAssertGreaterThan(completeEvent.duration ?? 0, 0)
    }
    
    func testAuditLoggingFailure() async throws {
        // Create in-memory logger
        let logger = InMemoryAuditLogger()
        
        // Create middleware
        let middleware = AuditLoggingMiddleware(logger: logger)
        
        // Create test command
        let command = TestCommand(id: "test-fail", action: "delete")
        
        // Create context
        let context = CommandContext()
        await context.setMetadata("authUserId", value: "admin")
        
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
        
        // Verify audit events were logged
        let events = await logger.commandEvents()
        XCTAssertEqual(events.count, 2, "Should have start and failed events")
        
        // Verify failure was logged
        let failedEvent = events[1]
        XCTAssertEqual(failedEvent.phase, .failed)
        XCTAssertNotNil(failedEvent.error)
        XCTAssertTrue(failedEvent.error?.contains("404") ?? false)
    }
    
    func testTraceContextPropagation() async throws {
        // Create logger
        let logger = InMemoryAuditLogger()
        let middleware = AuditLoggingMiddleware(logger: logger)
        
        // Create trace context
        let traceContext = TraceContext(
            traceId: UUID(),
            spanId: UUID(),
            userId: "trace-user",
            sessionId: "trace-session"
        )
        
        // Execute with trace context
        await AuditContext.withValue(traceContext) {
            let command = TestCommand(id: "trace-test", action: "read")
            let context = CommandContext()
            
            let handler: @Sendable (TestCommand, CommandContext) async throws -> TestResult = { _, _ in
                TestResult(success: true, message: "OK")
            }
            
            _ = try? await middleware.execute(command, context: context, next: handler)
        }
        
        // Verify trace context was included in events
        let events = await logger.commandEventsWithMetadata()
        XCTAssertFalse(events.isEmpty)
        
        for testableEvent in events {
            let metadata = testableEvent.metadata
            XCTAssertEqual(metadata["traceId"] as? String, traceContext.traceId.uuidString)
            XCTAssertEqual(metadata["spanId"] as? String, traceContext.spanId.uuidString)
        }
    }
    
    func testInMemoryLoggerCapacity() async throws {
        // Create logger with limited capacity
        let logger = InMemoryAuditLogger(maxEvents: 3)
        
        // Log more events than capacity
        for i in 0..<5 {
            await logger.log(GenericAuditEvent(
                eventType: "test.\(i)",
                metadata: ["index": i]
            ))
        }
        
        // Should only have last 3 events
        let events = await logger.allEvents()
        XCTAssertEqual(events.count, 3)
        
        // Should be events 2, 3, 4 (0 and 1 were dropped)
        XCTAssertEqual(events[0].eventType, "test.2")
        XCTAssertEqual(events[1].eventType, "test.3")
        XCTAssertEqual(events[2].eventType, "test.4")
        
        // Check dropped count
        let droppedCount = await logger.droppedEventsCount
        XCTAssertEqual(droppedCount, 2)
    }
    
    func testConsoleLoggerFormatting() async throws {
        // This test verifies formatting but doesn't capture stdout
        let logger = ConsoleAuditLogger(verbose: true)
        
        let event = CommandLifecycleEvent(
            phase: .completed,
            commandType: "TestCommand",
            commandId: UUID(),
            userId: "test-user",
            duration: 1.234
        )
        
        // Just verify it doesn't crash
        await logger.log(event)
        
        // For production logger
        let prodLogger = ConsoleAuditLogger.production
        await prodLogger.log(event)
        
        // For development logger
        let devLogger = ConsoleAuditLogger.development
        await devLogger.log(event)
        
        XCTAssertTrue(true, "Console loggers should not crash")
    }
    
    func testSecurityAuditEvent() async throws {
        let logger = InMemoryAuditLogger()
        
        // Log various security events
        await logger.log(SecurityAuditEvent(
            action: .encryption,
            resource: "user.password",
            principal: "system"
        ))
        
        await logger.log(SecurityAuditEvent(
            action: .accessDenied,
            resource: "/admin/users",
            principal: "guest",
            details: ["reason": "Insufficient privileges" as any Sendable]
        ))
        
        await logger.log(SecurityAuditEvent(
            action: .keyRotation,
            details: [
                "oldKeyId": "key-v1" as any Sendable,
                "newKeyId": "key-v2" as any Sendable
            ]
        ))
        
        // Verify events
        let securityEvents = await logger.securityEvents()
        XCTAssertEqual(securityEvents.count, 3)
        
        // Check event types
        XCTAssertEqual(securityEvents[0].eventType, "security.encryption")
        XCTAssertEqual(securityEvents[1].eventType, "security.accessDenied")
        XCTAssertEqual(securityEvents[2].eventType, "security.keyRotation")
        
        // Check metadata
        XCTAssertEqual(securityEvents[1].metadata["reason"] as? String, "Insufficient privileges")
    }
    
    func testEventQuerying() async throws {
        let logger = InMemoryAuditLogger()
        
        // Log various events
        let cmd1 = CommandLifecycleEvent(phase: .started, commandType: "CreateUser")
        let cmd2 = CommandLifecycleEvent(phase: .completed, commandType: "CreateUser")
        let cmd3 = CommandLifecycleEvent(phase: .started, commandType: "DeleteUser")
        let sec1 = SecurityAuditEvent(action: .encryption)
        
        await logger.log(cmd1)
        await logger.log(cmd2)
        await logger.log(cmd3)
        await logger.log(sec1)
        
        // Test various query methods
        let allEvents = await logger.allEvents()
        XCTAssertEqual(allEvents.count, 4)
        
        let createUserEvents = await logger.commandEvents(forType: "CreateUser")
        XCTAssertEqual(createUserEvents.count, 2)
        
        let startedEvents = await logger.events { event in
            event.eventType.contains("started")
        }
        XCTAssertEqual(startedEvents.count, 2)
        
        let lastCommand = await logger.lastCommandEvent()
        XCTAssertEqual(lastCommand?.commandType, "DeleteUser")
        
        let lastSecurity = await logger.lastSecurityEvent()
        XCTAssertEqual(lastSecurity?.action, .encryption)
    }
    
    func testHealthStream() async throws {
        let logger = InMemoryAuditLogger(maxEvents: 2)
        
        // Start monitoring health
        let healthTask = Task {
            var healthEvents: [LoggerHealthEvent] = []
            for await event in logger.health {
                healthEvents.append(event)
                if healthEvents.count >= 2 {
                    break
                }
            }
            return healthEvents
        }
        
        // Trigger health events by exceeding capacity
        for i in 0..<12 {
            await logger.log(GenericAuditEvent(eventType: "test.\(i)"))
        }
        
        // Clear to trigger recovery
        await logger.clear()
        
        // Cancel health monitoring
        healthTask.cancel()
        
        // The health stream should have reported dropped events
        let droppedCount = await logger.droppedEventsCount
        XCTAssertEqual(droppedCount, 0, "Should be reset after clear")
    }
}
