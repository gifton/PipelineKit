import Foundation
import PipelineKit

/// A command whose application-defined validation is invoked by `ValidationMiddleware`.
///
/// Implementations must throw when the command is invalid. There is no default witness.
public protocol ValidatableCommand: Command {
    /// Validates this command, throwing the application's validation error on failure.
    func validate() async throws
}

/// A command that can return an application-defined, sanitized replacement value.
///
/// Implementations define the transformation for their own input and output context;
/// conformance is not a promise of protection against arbitrary injection attacks.
public protocol SanitizableCommand: Command {
    /// Returns the value to pass downstream, or throws if sanitization fails.
    func sanitize() async throws -> Self
}

/// Controls how security middleware handles a command without its capability.
public enum SecurityCapabilityRequirement: Sendable {
    /// Reject commands that do not conform to the middleware's capability protocol.
    case required
    /// Invoke the capability when present; explicitly allow unrelated commands through.
    case ifPresent
}
