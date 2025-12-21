import Testing
import Foundation
@testable import PipelineKit
@testable import PipelineKitCore

// MARK: - Test Commands and Handlers

struct SimpleTestCommand: Command {
    typealias Result = String
    let value: String
}

struct SecureTestCommand: Command, RequiresEncryption {
    typealias Result = String
    let data: String
}

struct ValidatableTestCommand: Command, RequiresValidation {
    typealias Result = String
    var input: String
}

struct AuditableTestCommand: Command, Auditable {
    typealias Result = String
    let action: String
}

struct MultiScopeCommand: Command, RequiresEncryption, RequiresValidation {
    typealias Result = String
    let data: String
}

struct EchoHandler: CommandHandler {
    typealias CommandType = SimpleTestCommand
    func handle(_ command: SimpleTestCommand) async throws -> String {
        return "Echo: \(command.value)"
    }
}

struct SecureHandler: CommandHandler {
    typealias CommandType = SecureTestCommand
    func handle(_ command: SecureTestCommand) async throws -> String {
        return "Secure: \(command.data)"
    }
}

struct ValidatableHandler: CommandHandler {
    typealias CommandType = ValidatableTestCommand
    func handle(_ command: ValidatableTestCommand) async throws -> String {
        return "Validated: \(command.input)"
    }
}

// MARK: - Conditional Middleware Tests

@Suite("Conditional Middleware Tests")
struct ConditionalMiddlewareTests {

    struct FeatureFlagMiddleware: ConditionalMiddleware {
        let isEnabled: Bool
        var executionCount = 0

        func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool {
            return isEnabled
        }

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            context.setMetadata("featureFlagMiddleware", value: true)
            return try await next(command, context)
        }
    }

    struct CountingMiddleware: ConditionalMiddleware {
        let shouldRun: Bool

        func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool {
            return shouldRun
        }

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            let count = (context.getMetadata("executionCount") as? Int) ?? 0
            context.setMetadata("executionCount", value: count + 1)
            return try await next(command, context)
        }
    }

    @Test("Conditional middleware activates when shouldActivate returns true")
    func conditionalMiddlewareActivates() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(FeatureFlagMiddleware(isEnabled: true))

        let context = CommandContext()
        let result = try await pipeline.execute(SimpleTestCommand(value: "test"), context: context)

        #expect(result == "Echo: test")
        #expect(context.getMetadata("featureFlagMiddleware") as? Bool == true)
    }

    @Test("Conditional middleware skips when shouldActivate returns false")
    func conditionalMiddlewareSkips() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(FeatureFlagMiddleware(isEnabled: false))

        let context = CommandContext()
        let result = try await pipeline.execute(SimpleTestCommand(value: "test"), context: context)

        #expect(result == "Echo: test")
        #expect(context.getMetadata("featureFlagMiddleware") == nil)
    }

    @Test("Multiple conditional middleware - some activate, some skip")
    func mixedConditionalMiddleware() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(CountingMiddleware(shouldRun: true))
        try await pipeline.addMiddleware(CountingMiddleware(shouldRun: false))
        try await pipeline.addMiddleware(CountingMiddleware(shouldRun: true))

        let context = CommandContext()
        _ = try await pipeline.execute(SimpleTestCommand(value: "test"), context: context)

        // Only 2 of 3 middleware should have run
        #expect(context.getMetadata("executionCount") as? Int == 2)
    }
}

// MARK: - Scoped Middleware Tests

@Suite("Scoped Middleware Tests")
struct ScopedMiddlewareTests {

    struct EncryptionMarkerMiddleware: ScopedMiddleware {
        typealias Scope = RequiresEncryption

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            context.setMetadata("encryptionApplied", value: true)
            return try await next(command, context)
        }
    }

    struct ValidationMarkerMiddleware: ScopedMiddleware {
        typealias Scope = RequiresValidation

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            context.setMetadata("validationApplied", value: true)
            return try await next(command, context)
        }
    }

    struct AuditMarkerMiddleware: ScopedMiddleware {
        typealias Scope = Auditable

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            context.setMetadata("auditApplied", value: true)
            return try await next(command, context)
        }
    }

    @Test("Scoped middleware activates for matching command type")
    func scopedMiddlewareActivatesForMatchingType() async throws {
        let pipeline = StandardPipeline(handler: SecureHandler())
        try await pipeline.addMiddleware(EncryptionMarkerMiddleware())

        let context = CommandContext()
        let result = try await pipeline.execute(SecureTestCommand(data: "secret"), context: context)

        #expect(result == "Secure: secret")
        #expect(context.getMetadata("encryptionApplied") as? Bool == true)
    }

    @Test("Scoped middleware skips for non-matching command type")
    func scopedMiddlewareSkipsForNonMatchingType() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(EncryptionMarkerMiddleware())

        let context = CommandContext()
        let result = try await pipeline.execute(SimpleTestCommand(value: "plain"), context: context)

        #expect(result == "Echo: plain")
        #expect(context.getMetadata("encryptionApplied") == nil)
    }

    @Test("Multiple scoped middleware with different scopes")
    func multipleScopedMiddleware() async throws {
        let pipeline = StandardPipeline(handler: ValidatableHandler())
        try await pipeline.addMiddleware(EncryptionMarkerMiddleware())
        try await pipeline.addMiddleware(ValidationMarkerMiddleware())
        try await pipeline.addMiddleware(AuditMarkerMiddleware())

        let context = CommandContext()
        // ValidatableTestCommand only conforms to RequiresValidation
        _ = try await pipeline.execute(ValidatableTestCommand(input: "test"), context: context)

        #expect(context.getMetadata("encryptionApplied") == nil)
        #expect(context.getMetadata("validationApplied") as? Bool == true)
        #expect(context.getMetadata("auditApplied") == nil)
    }
}

// MARK: - Command Interceptor Tests

@Suite("Command Interceptor Tests")
struct CommandInterceptorTests {

    struct TrimmingInterceptor: CommandInterceptor {
        func intercept<T: Command>(_ command: T) -> T {
            guard var validatable = command as? ValidatableTestCommand else {
                return command
            }
            validatable.input = validatable.input.trimmingCharacters(in: .whitespaces)
            return validatable as! T
        }
    }

    struct UppercaseInterceptor: CommandInterceptor {
        func intercept<T: Command>(_ command: T) -> T {
            guard var validatable = command as? ValidatableTestCommand else {
                return command
            }
            validatable.input = validatable.input.uppercased()
            return validatable as! T
        }
    }

    struct CountingInterceptor: CommandInterceptor {
        func intercept<T: Command>(_ command: T) -> T {
            // Just pass through - we don't need actual counting for these tests
            return command
        }
    }

    @Test("Interceptor transforms command before middleware")
    func interceptorTransformsCommand() async throws {
        let pipeline = StandardPipeline(handler: ValidatableHandler())
        await pipeline.addInterceptor(TrimmingInterceptor())

        let result = try await pipeline.execute(ValidatableTestCommand(input: "  hello world  "))

        #expect(result == "Validated: hello world")
    }

    @Test("Multiple interceptors chain in order")
    func multipleInterceptorsChain() async throws {
        let pipeline = StandardPipeline(handler: ValidatableHandler())
        await pipeline.addInterceptor(TrimmingInterceptor())
        await pipeline.addInterceptor(UppercaseInterceptor())

        let result = try await pipeline.execute(ValidatableTestCommand(input: "  hello  "))

        #expect(result == "Validated: HELLO")
    }

    @Test("Interceptor count is tracked")
    func interceptorCountTracked() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())

        #expect(await pipeline.interceptorCount == 0)

        await pipeline.addInterceptor(CountingInterceptor())
        #expect(await pipeline.interceptorCount == 1)

        await pipeline.addInterceptor(CountingInterceptor())
        #expect(await pipeline.interceptorCount == 2)
    }

    @Test("Clear interceptors removes all")
    func clearInterceptors() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())

        await pipeline.addInterceptor(CountingInterceptor())
        await pipeline.addInterceptor(CountingInterceptor())
        #expect(await pipeline.interceptorCount == 2)

        await pipeline.clearInterceptors()
        #expect(await pipeline.interceptorCount == 0)
    }

    @Test("InterceptorChain works standalone")
    func interceptorChainStandalone() async throws {
        let chain = InterceptorChain()
        chain.addInterceptor(TrimmingInterceptor())
        chain.addInterceptor(UppercaseInterceptor())

        let command = ValidatableTestCommand(input: "  hello  ")
        let result = chain.intercept(command)

        #expect(result.input == "HELLO")
    }

    @Test("TypedCommandInterceptor only affects matching type")
    func typedInterceptorMatchesType() async throws {
        struct ValidatableNormalizer: TypedCommandInterceptor {
            typealias CommandType = ValidatableTestCommand

            func intercept(_ command: ValidatableTestCommand) -> ValidatableTestCommand {
                var result = command
                result.input = command.input.lowercased()
                return result
            }
        }

        let chain = InterceptorChain()
        chain.addInterceptor(ValidatableNormalizer())

        // Should transform ValidatableTestCommand
        let validatable = ValidatableTestCommand(input: "HELLO")
        let result1 = chain.intercept(validatable)
        #expect(result1.input == "hello")

        // Should NOT transform SimpleTestCommand
        let simple = SimpleTestCommand(value: "HELLO")
        let result2 = chain.intercept(simple)
        #expect(result2.value == "HELLO")
    }
}

// MARK: - Enhanced Pipeline Introspection Tests

@Suite("Enhanced Pipeline Introspection Tests")
struct EnhancedPipelineIntrospectionTests {

    struct TestMiddleware: Middleware {
        let priority: ExecutionPriority = .validation

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            return try await next(command, context)
        }
    }

    struct ConditionalTestMiddleware: ConditionalMiddleware {
        let priority: ExecutionPriority = .preProcessing

        func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool {
            return true
        }

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            return try await next(command, context)
        }
    }

    @Test("PipelineInfo includes interceptor count")
    func pipelineInfoIncludesInterceptorCount() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        await pipeline.addInterceptor(CountingInterceptor())
        await pipeline.addInterceptor(CountingInterceptor())

        let info = await PipelineInspector.inspect(pipeline)

        #expect(info.interceptorCount == 2)
    }

    @Test("PipelineInfo includes middleware details")
    func pipelineInfoIncludesMiddlewareDetails() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(TestMiddleware())
        try await pipeline.addMiddleware(ConditionalTestMiddleware())

        let info = await PipelineInspector.inspect(pipeline)

        #expect(info.middlewareDetails.count == 2)
        // Middleware is sorted by priority (lower values first)
        // validation (200) comes before preProcessing (300)
        let validationDetail = info.middlewareDetails.first { $0.priority == ExecutionPriority.validation.rawValue }
        let preProcessingDetail = info.middlewareDetails.first { $0.priority == ExecutionPriority.preProcessing.rawValue }

        #expect(validationDetail != nil)
        #expect(preProcessingDetail != nil)
        #expect(preProcessingDetail?.isConditional == true)
    }

    @Test("Pipeline diagram includes interceptors")
    func diagramIncludesInterceptors() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        await pipeline.addInterceptor(CountingInterceptor())
        try await pipeline.addMiddleware(TestMiddleware())

        let diagram = await PipelineInspector.diagram(pipeline)

        #expect(diagram.contains("[Interceptors]"))
        #expect(diagram.contains("Interceptors: 1"))
    }

    @Test("Pipeline describe includes detailed middleware info")
    func describeIncludesDetailedInfo() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        await pipeline.addInterceptor(CountingInterceptor())
        try await pipeline.addMiddleware(TestMiddleware())
        try await pipeline.addMiddleware(ConditionalTestMiddleware())

        let description = await PipelineInspector.describe(pipeline)

        #expect(description.contains("Pipeline Description"))
        #expect(description.contains("Interceptors: 1"))
        #expect(description.contains("Middleware (2)"))
        #expect(description.contains("Priority:"))
        #expect(description.contains("Flags:"))
    }

    @Test("Execution trace returns active middleware")
    func executionTraceReturnsActiveMiddleware() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(TestMiddleware())
        try await pipeline.addMiddleware(ConditionalTestMiddleware())

        let trace = await PipelineInspector.trace(
            SimpleTestCommand(value: "test"),
            through: pipeline
        )

        #expect(trace.commandType == "SimpleTestCommand")
        #expect(trace.activeMiddleware.count == 2)
        #expect(trace.handlerType == "EchoHandler")
    }

    @Test("PipelineInfo description includes interceptor count")
    func pipelineInfoDescriptionIncludesInterceptors() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        await pipeline.addInterceptor(CountingInterceptor())

        let info = await PipelineInspector.inspect(pipeline)
        let description = info.description

        #expect(description.contains("interceptors: 1"))
    }

    @Test("MiddlewareDetail tracks conditional and scoped flags")
    func middlewareDetailTracksFlags() async throws {
        struct ScopedTestMiddleware: ScopedMiddleware {
            typealias Scope = RequiresEncryption

            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @escaping MiddlewareNext<T>
            ) async throws -> T.Result {
                return try await next(command, context)
            }
        }

        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(ScopedTestMiddleware())
        try await pipeline.addMiddleware(ConditionalTestMiddleware())

        let info = await PipelineInspector.inspect(pipeline)

        // Note: ScopedMiddleware is also ConditionalMiddleware
        let scopedDetail = info.middlewareDetails.first { $0.typeName.contains("ScopedTest") }
        let conditionalDetail = info.middlewareDetails.first { $0.typeName.contains("ConditionalTest") }

        #expect(scopedDetail?.isScoped == true)
        #expect(scopedDetail?.isConditional == true) // ScopedMiddleware inherits from ConditionalMiddleware
        #expect(conditionalDetail?.isConditional == true)
    }
}

// MARK: - Integration Tests

@Suite("Phase 1 Integration Tests")
struct Phase1IntegrationTests {

    struct LoggingInterceptor: CommandInterceptor {
        func intercept<T: Command>(_ command: T) -> T {
            // In real use, this would log
            return command
        }
    }

    struct AuthMiddleware: ConditionalMiddleware {
        let isAuthenticated: Bool

        func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool {
            return command is any RequiresAuthentication
        }

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            guard isAuthenticated else {
                throw PipelineError.executionFailed(message: "Not authenticated", context: nil)
            }
            context.setMetadata("authenticated", value: true)
            return try await next(command, context)
        }
    }

    struct EncryptionScopedMiddleware: ScopedMiddleware {
        typealias Scope = RequiresEncryption

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            context.setMetadata("encrypted", value: true)
            return try await next(command, context)
        }
    }

    @Test("Full pipeline with interceptors, conditional, and scoped middleware")
    func fullPipelineIntegration() async throws {
        let pipeline = StandardPipeline(handler: SecureHandler())

        // Add interceptor
        await pipeline.addInterceptor(LoggingInterceptor())

        // Add conditional middleware (won't activate for SecureTestCommand)
        try await pipeline.addMiddleware(AuthMiddleware(isAuthenticated: true))

        // Add scoped middleware (will activate for SecureTestCommand)
        try await pipeline.addMiddleware(EncryptionScopedMiddleware())

        let context = CommandContext()
        let result = try await pipeline.execute(SecureTestCommand(data: "secret"), context: context)

        #expect(result == "Secure: secret")
        // Auth middleware should NOT activate (SecureTestCommand doesn't conform to RequiresAuthentication)
        #expect(context.getMetadata("authenticated") == nil)
        // Encryption middleware SHOULD activate
        #expect(context.getMetadata("encrypted") as? Bool == true)

        // Verify introspection
        let info = await PipelineInspector.inspect(pipeline)
        #expect(info.interceptorCount == 1)
        #expect(info.middlewareCount == 2)
    }
}

// Helper for tests
struct CountingInterceptor: CommandInterceptor {
    func intercept<T: Command>(_ command: T) -> T {
        return command
    }
}
