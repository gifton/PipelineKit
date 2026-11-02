import Foundation
import XCTest
import PipelineKit
import PipelineKitSecurity

final class SecurityCapabilityContractTests: XCTestCase {
    func testGenericPipelineInvokesValidationWitness() async throws {
        for route in Route.allCases {
            for requirement in [SecurityCapabilityRequirement.required, .ifPresent] {
                for rejects in [false, true] {
                    let trace = Trace()
                    let failure = WitnessFailure()
                    let command = CapabilityCommand(trace: trace, validationFailure: rejects ? failure : nil)
                    do {
                        let result = try await route.execute(
                            command, middleware: [ValidationMiddleware(requirement: requirement)], trace: trace
                        )
                        XCTAssertFalse(rejects, "\(route) must propagate the validation error")
                        XCTAssertEqual(result, Payload(title: "  Report  ", body: "  CONTENT  "))
                    } catch {
                        XCTAssertTrue(rejects, "\(route): \(error)")
                        XCTAssertTrue((error as? WitnessFailure) === failure, "\(route) must preserve the concrete error")
                    }
                    let events = await trace.events
                    XCTAssertEqual(events, rejects ? ["validate"] : ["validate"] + route.downstreamEvents, "\(route)")
                    XCTAssertEqual(events.filter { $0 == "handler" }.count, rejects ? 0 : 1, "\(route)")
                }
            }
        }
    }

    func testGenericPipelinePassesReturnedSanitizedValue() async throws {
        for route in Route.allCases {
            for requirement in [SecurityCapabilityRequirement.required, .ifPresent] {
                let trace = Trace()
                let command = CapabilityCommand(trace: trace)
                let result = try await route.execute(
                    command, middleware: [SanitizationMiddleware(requirement: requirement)], trace: trace
                )
                XCTAssertEqual(result, Payload(title: "Report", body: "content"), "\(route)")
                XCTAssertEqual(command.title, "  Report  ", "The caller's immutable value must be unchanged")
                XCTAssertEqual(command.body, "  CONTENT  ")
                let events = await trace.events
                XCTAssertEqual(events, ["sanitize"] + route.downstreamEvents, "\(route)")
            }
        }
    }

    func testSanitizationFailureRejectsBeforeHandler() async throws {
        for route in Route.allCases {
            for requirement in [SecurityCapabilityRequirement.required, .ifPresent] {
                let trace = Trace()
                let failure = WitnessFailure()
                let command = CapabilityCommand(trace: trace, sanitizationFailure: failure)
                do {
                    _ = try await route.execute(
                        command, middleware: [SanitizationMiddleware(requirement: requirement)], trace: trace
                    )
                    XCTFail("\(route) must propagate the sanitization error")
                } catch {
                    XCTAssertTrue((error as? WitnessFailure) === failure, "\(route)")
                }
                let events = await trace.events
                XCTAssertEqual(events, ["sanitize"], "\(route)")
                XCTAssertEqual(events.filter { $0 == "handler" }.count, 0, "\(route)")
            }
        }
    }

    func testMissingRequiredCapabilityRejectsBeforeHandler() async throws {
        let cases: [(any Middleware, SecurityCapabilityError)] = [
            (ValidationMiddleware(), .missingValidation(commandType: String(reflecting: UnrelatedCommand.self))),
            (SanitizationMiddleware(), .missingSanitization(commandType: String(reflecting: UnrelatedCommand.self)))
        ]
        for route in Route.allCases {
            for (middleware, expected) in cases {
                let trace = Trace()
                do {
                    _ = try await route.execute(UnrelatedCommand(), middleware: [middleware], trace: trace)
                    XCTFail("\(route) must reject missing capability")
                } catch {
                    XCTAssertEqual(error as? SecurityCapabilityError, expected, "\(route)")
                }
                let events = await trace.events
                XCTAssertEqual(events, [], "\(route)")
                XCTAssertEqual(events.filter { $0 == "handler" }.count, 0, "\(route)")
            }
        }
    }

    func testIfPresentAllowsUnrelatedCommand() async throws {
        for route in Route.allCases {
            let trace = Trace()
            let result = try await route.execute(
                UnrelatedCommand(),
                middleware: [ValidationMiddleware(requirement: .ifPresent), SanitizationMiddleware(requirement: .ifPresent)],
                trace: trace
            )
            XCTAssertEqual(result, Payload(title: "unrelated", body: "unchanged"), "\(route)")
            let events = await trace.events
            XCTAssertEqual(events, route.downstreamEvents, "\(route)")
        }
    }

    func testCombinedCapabilitiesReachHandlerWithTransformedFields() async throws {
        for route in Route.allCases {
            let trace = Trace()
            let command = CapabilityCommand(trace: trace)
            let result = try await route.execute(
                command, middleware: [SanitizationMiddleware(), ValidationMiddleware()], trace: trace
            )
            XCTAssertEqual(result, Payload(title: "Report", body: "content"), "\(route)")
            let events = await trace.events
            // The existing intrinsic priorities run validation (200) before sanitization (300).
            XCTAssertEqual(events, ["validate", "sanitize"] + route.downstreamEvents, "\(route)")
        }
    }
}

private extension SecurityCapabilityContractTests {
    enum Route: CaseIterable {
        case standard, anyStandard, dynamic, builderPlainFirst, builderNamedFirst

        var downstreamEvents: [String] {
            switch self {
            case .builderPlainFirst, .builderNamedFirst: return ["named", "handler"]
            default: return ["handler"]
            }
        }

        func execute<C: PayloadCommand>(
            _ command: C, middleware: [any Middleware], trace: Trace
        ) async throws -> Payload {
            let handler = RecordingHandler<C>(trace: trace)
            let context = CommandContext()
            switch self {
            case .standard:
                let pipeline = StandardPipeline(handler: handler)
                try await pipeline.addMiddlewares(middleware)
                return try await pipeline.execute(command, context: context)
            case .anyStandard:
                let pipeline = AnyStandardPipeline(handler: handler, options: .init(maxConcurrency: 10, maxOutstanding: nil))
                for stage in middleware {
                    try await pipeline.addMiddleware(stage)
                }
                return try await pipeline.execute(command, context: context)
            case .dynamic:
                let pipeline = DynamicPipeline()
                await pipeline.register(C.self, handler: handler)
                try await pipeline.addMiddlewares(middleware)
                return try await pipeline.send(command, context: context, retryPolicy: .none)
            case .builderPlainFirst, .builderNamedFirst:
                let builder = PipelineBuilder(handler: handler)
                let named = NamedStage(trace: trace)
                if self == .builderNamedFirst {
                    await builder.withLogging(named)
                }
                for stage in middleware {
                    await builder.with(stage)
                }
                if self == .builderPlainFirst {
                    await builder.withLogging(named)
                }
                let pipeline = try await builder.build()
                return try await pipeline.execute(command, context: context)
            }
        }
    }

    actor Trace {
        private(set) var events: [String] = []
        func append(_ event: String) { events.append(event) }
    }

    final class WitnessFailure: Error, Sendable {}

    struct Payload: Sendable, Equatable {
        let title: String
        let body: String
    }

    protocol PayloadCommand: Command where Result == Payload {
        var title: String { get }
        var body: String { get }
    }

    struct CapabilityCommand: PayloadCommand, ValidatableCommand, SanitizableCommand {
        typealias Result = Payload
        let title: String
        let body: String
        let trace: Trace
        let validationFailure: WitnessFailure?
        let sanitizationFailure: WitnessFailure?

        init(
            title: String = "  Report  ", body: String = "  CONTENT  ", trace: Trace,
            validationFailure: WitnessFailure? = nil, sanitizationFailure: WitnessFailure? = nil
        ) {
            self.title = title
            self.body = body
            self.trace = trace
            self.validationFailure = validationFailure
            self.sanitizationFailure = sanitizationFailure
        }

        func validate() async throws {
            await trace.append("validate")
            if let validationFailure { throw validationFailure }
        }

        func sanitize() async throws -> Self {
            await trace.append("sanitize")
            if let sanitizationFailure { throw sanitizationFailure }
            return Self(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                trace: trace, validationFailure: validationFailure, sanitizationFailure: sanitizationFailure
            )
        }
    }

    struct UnrelatedCommand: PayloadCommand {
        typealias Result = Payload
        let title = "unrelated"
        let body = "unchanged"
    }

    struct RecordingHandler<C: PayloadCommand>: CommandHandler {
        typealias CommandType = C
        let trace: Trace

        func handle(_ command: C, context: CommandContext) async throws -> Payload {
            await trace.append("handler")
            return Payload(title: command.title, body: command.body)
        }
    }

    struct NamedStage: Middleware {
        let priority: ExecutionPriority = .observability
        let trace: Trace

        func execute<T: Command>(
            _ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            await trace.append("named")
            return try await next(command, context)
        }
    }
}
