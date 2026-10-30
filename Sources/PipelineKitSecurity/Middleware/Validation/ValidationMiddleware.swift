import PipelineKit

/// Invokes a command's `ValidatableCommand` witness before calling the next stage.
///
/// By default, a command without the capability throws
/// `SecurityCapabilityError.missingValidation(commandType:)`. Use `.ifPresent`
/// explicitly when a pipeline is intended to accept unrelated command types.
/// Validation errors propagate unchanged; see
/// `SecurityCapabilityContractTests.testGenericPipelineInvokesValidationWitness`.
///
/// ```swift
/// let pipeline = StandardPipeline(handler: handler)
/// try await pipeline.addMiddleware(ValidationMiddleware())
/// ```
public struct ValidationMiddleware: Middleware {
    public let priority: ExecutionPriority = .validation
    private let requirement: SecurityCapabilityRequirement

    /// Creates validation middleware with an explicit policy for absent capability.
    /// - Parameter requirement: Defaults to rejecting commands without `ValidatableCommand`.
    public init(requirement: SecurityCapabilityRequirement = .required) {
        self.requirement = requirement
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        guard let validatable = command as? any ValidatableCommand else {
            if case .required = requirement {
                throw SecurityCapabilityError.missingValidation(commandType: String(reflecting: T.self))
            }
            return try await next(command, context)
        }

        try await validatable.validate()
        return try await next(command, context)
    }
}
