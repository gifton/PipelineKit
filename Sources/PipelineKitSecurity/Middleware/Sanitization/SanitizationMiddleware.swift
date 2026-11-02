import PipelineKit

/// Passes the value returned by a command's `SanitizableCommand` witness downstream.
///
/// By default, a command without the capability throws
/// `SecurityCapabilityError.missingSanitization(commandType:)`. Use `.ifPresent`
/// explicitly when a pipeline is intended to accept unrelated command types.
/// Sanitization is application-defined transformation, not a universal injection defense.
///
/// ```swift
/// import Foundation
/// import PipelineKitSecurity
///
/// struct CreatePostCommand: SanitizableCommand {
///     typealias Result = String
///     let title: String
///
///     func sanitize() async throws -> Self {
///         Self(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
///     }
/// }
/// ```
///
/// The returned value replaces the input to the next stage; see
/// `SecurityCapabilityContractTests.testGenericPipelinePassesReturnedSanitizedValue`.
public struct SanitizationMiddleware: Middleware {
    public let priority: ExecutionPriority = .preProcessing
    private let requirement: SecurityCapabilityRequirement

    /// Creates sanitization middleware with an explicit policy for absent capability.
    /// - Parameter requirement: Defaults to rejecting commands without `SanitizableCommand`.
    public init(requirement: SecurityCapabilityRequirement = .required) {
        self.requirement = requirement
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        guard let sanitizable = command as? any SanitizableCommand else {
            if case .required = requirement {
                throw SecurityCapabilityError.missingSanitization(commandType: String(reflecting: T.self))
            }
            return try await next(command, context)
        }

        let sanitized = try await sanitizable.sanitize()
        guard let typedCommand = sanitized as? T else {
            throw SecurityCapabilityError.invalidSanitizedType(
                expected: String(reflecting: T.self),
                actual: String(reflecting: type(of: sanitized))
            )
        }
        return try await next(typedCommand, context)
    }
}
