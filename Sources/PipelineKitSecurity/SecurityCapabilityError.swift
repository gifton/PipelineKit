/// A capability required by security middleware is absent or returned an incompatible value.
///
/// Associated strings identify command types, not command payloads.
public enum SecurityCapabilityError: Error, Sendable, Equatable {
    /// Validation was required, but the command did not conform to `ValidatableCommand`.
    case missingValidation(commandType: String)
    /// Sanitization was required, but the command did not conform to `SanitizableCommand`.
    case missingSanitization(commandType: String)
    /// An erased sanitization result could not be cast back to the pipeline's command type.
    case invalidSanitizedType(expected: String, actual: String)
}
