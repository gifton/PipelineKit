import Foundation
import XCTest
import PipelineKit
@testable import PipelineKitSecurity

final class SecurityGuideCompositionTests: XCTestCase {
    func testMaskingFiltersEnrichedMetadataAtProductionFormatterAndRestoresContext() async {
        let sink = ProductionFormattingSink()
        let logger = MaskingAuditLogger(wrapping: sink)
        let trace = TraceContext(userID: "context-user-secret", sessionId: "context-session-secret")
        await AuditContext.withValue(trace) {
            await logger.log(GuideEvent(eventMetadata: [
                "userID": "event-user-secret", "userId": "alias-user-secret",
                "sessionId": "event-session-secret", "sessionID": "alias-session-secret",
                "authUserId": "authenticated-secret", "error": "error-secret",
                "commandType": "GuideCommand", "commandId": UUID(), "duration": 0.25
            ]))
            XCTAssertEqual(AuditContext.current, trace)
        }
        XCTAssertNil(AuditContext.current)
        let records = await sink.records
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertTrue(record.contextWasNil)
        XCTAssertEqual(record.metadata["masked"] as? Bool, true)
        XCTAssertEqual(record.metadata["commandType"] as? String, "GuideCommand")
        XCTAssertEqual(record.metadata["traceId"] as? String, trace.traceId.uuidString)
        XCTAssertEqual(record.metadata["spanId"] as? String, trace.spanId.uuidString)
        for key in ["userID", "userId", "sessionId", "sessionID", "authUserId", "error"] {
            XCTAssertNil(record.metadata[key], key)
        }
        XCTAssertTrue(record.output.contains("commandType=GuideCommand"))
        XCTAssertTrue(record.output.contains("traceId=\(trace.traceId.uuidString)"))
        XCTAssertFalse(record.output.contains("secret"), record.output)
    }

    func testOuterWrappersObserveAndSanitizeAuthenticationRejectionInSortedPipeline() async throws {
        let trace = GuideTrace()
        let metrics = SecurityMetricsMiddleware()
        let pipeline = StandardPipeline(handler: GuideHandler(trace: trace))
        // This order is required when outer wrappers share authentication's priority.
        try await pipeline.addMiddlewares([
            SecureErrorMiddleware(), metrics,
            AuthenticationMiddleware { _ in
                await trace.record("authentication")
                throw GuideFailure.secret
            }
        ])
        let middlewareTypes = await pipeline.middlewareTypes
        XCTAssertEqual(middlewareTypes, ["SecureErrorMiddleware", "SecurityMetricsMiddleware", "AuthenticationMiddleware"])
        let callerContext = TraceContext(userID: "caller-secret", sessionId: "session-secret")
        let context = CommandContext(metadata: DefaultCommandMetadata(userID: "claimed-user"))
        await AuditContext.withValue(callerContext) {
            do {
                _ = try await pipeline.execute(GuideCommand(), context: context)
                XCTFail("Authentication denial must reject")
            } catch {
                guard case let .executionFailed(message, errorContext) = error as? PipelineError else {
                    return XCTFail("Expected sanitized error, got \(error)")
                }
                XCTAssertEqual(message, "Internal server error")
                XCTAssertNil(errorContext)
            }
            XCTAssertEqual(AuditContext.current, callerContext)
        }
        let count = await metrics.failureCount(for: "claimed-user")
        XCTAssertEqual(count, 1)
        let events = await trace.events
        XCTAssertEqual(events, ["authentication"])
        XCTAssertNil(context.getMetadata("authUserId"))
        XCTAssertNil(AuditContext.current)
    }

    func testMetricsPreservesAuthenticationDenialWithoutSanitizer() async throws {
        let trace = GuideTrace()
        let metrics = SecurityMetricsMiddleware()
        let pipeline = StandardPipeline(handler: GuideHandler(trace: trace))
        try await pipeline.addMiddlewares([
            metrics, AuthenticationMiddleware { _ in throw GuideFailure.secret }
        ])
        do {
            _ = try await pipeline.execute(GuideCommand(), metadata: DefaultCommandMetadata(userID: "claimed-user"))
            XCTFail("Authentication denial must reject")
        } catch {
            XCTAssertEqual(error as? GuideFailure, .secret)
        }
        let count = await metrics.failureCount(for: "claimed-user")
        XCTAssertEqual(count, 1)
        let events = await trace.events
        XCTAssertEqual(events, [])
    }

    func testSecureErrorRemovesApplicationDefinedValidationAndAuthorizationDetails() async throws {
        let failures: [PipelineError] = [
            .validation(field: "secret-field", reason: .custom("validation-secret")),
            .authorization(reason: .custom("authorization-secret"))
        ]
        for failure in failures {
            let trace = GuideTrace()
            let pipeline = StandardPipeline(handler: GuideHandler(trace: trace))
            try await pipeline.addMiddlewares([
                SecureErrorMiddleware(), AuthenticationMiddleware { _ in throw failure }
            ])
            do {
                _ = try await pipeline.execute(GuideCommand())
                XCTFail("Must reject")
            } catch {
                XCTAssertFalse(String(describing: error).contains("secret"))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
            let events = await trace.events
            XCTAssertEqual(events, [])
        }
    }

    func testSuccessfulAuthenticationReachesHandlerWithoutCountingFailure() async throws {
        let trace = GuideTrace()
        let metrics = SecurityMetricsMiddleware()
        let pipeline = StandardPipeline(handler: GuideHandler(trace: trace))
        try await pipeline.addMiddlewares([
            SecureErrorMiddleware(), metrics,
            AuthenticationMiddleware { _ in "verified-user" }
        ])
        let context = CommandContext(metadata: DefaultCommandMetadata(userID: "claimed-user"))
        let result = try await pipeline.execute(GuideCommand(), context: context)
        XCTAssertEqual(result, "accepted")
        XCTAssertEqual(context.getMetadata("authUserId") as? String, "verified-user")
        let count = await metrics.failureCount(for: "claimed-user")
        XCTAssertEqual(count, 0)
        let events = await trace.events
        XCTAssertEqual(events, ["handler"])
    }

    func testAuditCreatesAndCleansContextOnSuccessAndFailure() async throws {
        for failure: GuideFailure? in [nil, .secret] {
            let sink = ProductionFormattingSink()
            let trace = GuideTrace()
            let pipeline = StandardPipeline(handler: GuideHandler(trace: trace, failure: failure))
            try await pipeline.addMiddlewares([
                AuthenticationMiddleware { _ in "authenticated-secret" },
                AuditLoggingMiddleware(logger: MaskingAuditLogger(wrapping: sink))
            ])
            XCTAssertNil(AuditContext.current)
            do {
                let result = try await pipeline.execute(GuideCommand())
                XCTAssertNil(failure)
                XCTAssertEqual(result, "accepted")
            } catch {
                XCTAssertEqual(error as? GuideFailure, failure)
                XCTAssertNotNil(failure)
            }
            XCTAssertNil(AuditContext.current)
            let records = await sink.records
            XCTAssertEqual(records.map(\.eventType), ["command.started", failure == nil ? "command.completed" : "command.failed"])
            XCTAssertTrue(records.allSatisfy(\.contextWasNil))
            XCTAssertTrue(records.allSatisfy { !$0.output.contains("secret") })
            let traceID = try XCTUnwrap(records.first?.metadata["traceId"] as? String)
            XCTAssertTrue(records.allSatisfy { $0.metadata["traceId"] as? String == traceID })
            let events = await trace.events
            XCTAssertEqual(events, ["handler"])
        }
    }

    func testAuditFailurePipelineRestoresCallerContextAndMasksLifecycleEvents() async throws {
        let sink = ProductionFormattingSink()
        let trace = GuideTrace()
        let pipeline = StandardPipeline(handler: GuideHandler(trace: trace, failure: .secret))
        try await pipeline.addMiddlewares([
            AuthenticationMiddleware { _ in "authenticated-secret" },
            AuditLoggingMiddleware(logger: MaskingAuditLogger(wrapping: sink))
        ])
        let callerContext = TraceContext(userID: "caller-secret", sessionId: "caller-session-secret")
        let context = CommandContext()
        context.setMetadata("sessionId", value: "metadata-session-secret")
        await AuditContext.withValue(callerContext) {
            do {
                _ = try await pipeline.execute(GuideCommand(), context: context)
                XCTFail("Handler must throw")
            } catch {
                XCTAssertEqual(error as? GuideFailure, .secret)
            }
            XCTAssertEqual(AuditContext.current, callerContext)
        }
        let records = await sink.records
        XCTAssertEqual(records.map(\.eventType), ["command.started", "command.failed"])
        XCTAssertTrue(records.allSatisfy(\.contextWasNil))
        XCTAssertTrue(records.allSatisfy { !$0.output.contains("secret") })
        XCTAssertTrue(records.allSatisfy { $0.metadata["traceId"] as? String == callerContext.traceId.uuidString })
        let events = await trace.events
        XCTAssertEqual(events, ["handler"])
        XCTAssertNil(AuditContext.current)
    }
}

private struct GuideEvent: AuditEvent {
    let eventType = "guide.event"
    let timestamp = Date(timeIntervalSince1970: 0)
    let eventMetadata: [String: any Sendable]
}

private actor ProductionFormattingSink: AuditLogger {
    struct Record: Sendable {
        let eventType: String
        let metadata: [String: any Sendable]
        let output: String
        let contextWasNil: Bool
    }
    private(set) var records: [Record] = []
    func log(_ event: any AuditEvent) {
        records.append(Record(
            eventType: event.eventType, metadata: event.metadata,
            output: ConsoleAuditLogger.production.formatEvent(event),
            contextWasNil: AuditContext.current == nil
        ))
    }
}

private enum GuideFailure: Error { case secret }
private struct GuideCommand: Command { typealias Result = String }
private actor GuideTrace {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
private struct GuideHandler: CommandHandler {
    let trace: GuideTrace
    var failure: GuideFailure? = nil
    func handle(_ command: GuideCommand, context: CommandContext) async throws -> String {
        await trace.record("handler")
        if let failure { throw failure }
        return "accepted"
    }
}

// Read-only inspection of the guide's counter, without changing its execution behavior.
private extension FailureCounter {
    func count(for key: String) -> Int { counts[key, default: 0] }
}
private extension SecurityMetricsMiddleware {
    func failureCount(for key: String) async -> Int { await failureCounts.count(for: key) }
}

// Executable copies of the guide's middleware and masking examples.
// Failure counts must live in a reference type with its own synchronization: `execute(_:context:next:)`
// is a non-mutating protocol requirement, so a struct can't carry `var` state mutated there.
actor FailureCounter {
    private var counts: [String: Int] = [:]

    func increment(_ key: String) -> Int {
        counts[key, default: 0] += 1
        return counts[key]!
    }
}

struct SecurityMetricsMiddleware: Middleware {
    // Register before AuthenticationMiddleware at the same priority.
    let priority: ExecutionPriority = .authentication
    private let threshold = 5
    private let failureCounts = FailureCounter()

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        do {
            return try await next(command, context)
        } catch {
            // Track failures by the CLAIMED (unauthenticated) identity in `context.userID`, not
            // by the authenticated "authUserId" metadata key: this middleware also needs to
            // count authentication failures, and "authUserId" is only ever set *after*
            // AuthenticationMiddleware succeeds — a failed attempt never sets it. Counting the
            // claimed identity is the correct choice for brute-force detection; just don't use
            // this counter (or its key) to make an authorization decision.
            if let userID = context.userID {
                let failures = await failureCounts.increment(userID)

                if failures >= threshold {
                    // Log security event
                    print("SECURITY: Multiple failures for user \(userID)")
                }
            }
            throw error
        }
    }
}

// Application-owned event types and allowlisted fields must contain no sensitive payloads.
struct MaskingAuditLogger: AuditLogger {
    private let wrapped: any AuditLogger

    init(wrapping logger: any AuditLogger) {
        self.wrapped = logger
    }

    func log(_ event: any AuditEvent) async {
        struct MaskedEvent: AuditEvent {
            let eventType: String
            let timestamp: Date
            let eventMetadata: [String: any Sendable]
        }

        let allowedKeys: Set<String> = ["commandType", "commandId", "traceId", "spanId", "duration"]
        var metadata = event.metadata.filter { allowedKeys.contains($0.key) }
        metadata["masked"] = true
        let filtered = MaskedEvent(
            eventType: event.eventType, timestamp: event.timestamp, eventMetadata: metadata
        )
        await AuditContext.$current.withValue(nil) {
            await wrapped.log(filtered)
        }
    }
}


struct SecureErrorMiddleware: Middleware {
    // Register before metrics and authentication at the same priority.
    let priority: ExecutionPriority = .authentication

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        do {
            return try await next(command, context)
        } catch {
            // Log the real error for debugging (never sent to the client). `context.userID` here
            // is the unauthenticated, caller-claimed identity — fine for a diagnostic log line
            // (it labels who *said* they were making the request), but never treat it as verified.
            print("Command \(T.self) failed for user \(context.userID ?? "unknown"): \(error)")

            // Return a sanitized error to the client
            throw sanitizeError(error)
        }
    }

    private func sanitizeError(_ error: Error) -> Error {
        switch error {
        case let pipelineError as PipelineError:
            switch pipelineError {
            case .authentication, .rateLimitExceeded:
                return pipelineError // These cases carry only fixed text and scalar retry details.

            case .validation:
                // Application-defined reasons and field names can contain sensitive values.
                return PipelineError.validation(field: nil, reason: .custom("Invalid request"))

            case .authorization:
                return PipelineError.authorization(reason: .invalidCredentials)

            default:
                // Hide implementation details
                return PipelineError.executionFailed(message: "Internal server error", context: nil)
            }

        default:
            return PipelineError.executionFailed(message: "Internal server error", context: nil)
        }
    }
}
