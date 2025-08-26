import Foundation
import PipelineKit

/// A validator that performs common validation checks.
public struct CommandValidator: Sendable {
    /// Validates an email address format.
    /// 
    /// - Parameter email: The email address to validate
    /// - Throws: PipelineError.validation if format is invalid
    public static func validateEmail(_ email: String) throws {
        // Use optimized pre-compiled regex validator
        guard OptimizedValidators.validateEmail(email) else {
            throw PipelineError.validation(field: "email", reason: .invalidEmail)
        }
    }
    
    /// Validates a string length.
    /// 
    /// - Parameters:
    ///   - value: The string to validate
    ///   - field: The field name for error reporting
    ///   - minLength: Minimum allowed length (optional)
    ///   - maxLength: Maximum allowed length (optional)
    /// - Throws: PipelineError.validation if length constraints are violated
    public static func validateLength(
        _ value: String,
        field: String,
        minLength: Int? = nil,
        maxLength: Int? = nil
    ) throws {
        if let min = minLength, value.count < min {
            throw PipelineError.validation(field: field, reason: .tooShort(field: field, min: min))
        }
        
        if let max = maxLength, value.count > max {
            throw PipelineError.validation(field: field, reason: .tooLong(field: field, max: max))
        }
    }
    
    /// Validates that a string is not empty.
    /// 
    /// - Parameters:
    ///   - value: The string to validate
    ///   - field: The field name for error reporting
    /// - Throws: PipelineError.validation if empty
    public static func validateNotEmpty(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.validation(field: field, reason: .missingRequired)
        }
    }
    
    /// Validates that a string contains only alphanumeric characters.
    /// 
    /// - Parameters:
    ///   - value: The string to validate
    ///   - field: The field name for error reporting
    ///   - allowedCharacters: Additional allowed characters
    /// - Throws: PipelineError.validation if invalid characters found
    public static func validateAlphanumeric(
        _ value: String,
        field: String,
        allowedCharacters: CharacterSet = CharacterSet()
    ) throws {
        let allowed = CharacterSet.alphanumerics.union(allowedCharacters)
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw PipelineError.validation(field: field, reason: .invalidCharacters(field: field))
        }
    }
}
