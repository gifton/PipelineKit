import Foundation

/// A validator that performs common validation checks.
public struct CommandValidator: Sendable {
    
    /// Validates an email address format.
    /// 
    /// - Parameter email: The email address to validate
    /// - Throws: ValidationError.invalidEmail if format is invalid
    public static func validateEmail(_ email: String) throws {
        let emailRegex = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        
        guard emailPredicate.evaluate(with: email) else {
            throw ValidationError.invalidEmail
        }
    }
    
    /// Validates a string length.
    /// 
    /// - Parameters:
    ///   - value: The string to validate
    ///   - field: The field name for error reporting
    ///   - minLength: Minimum allowed length (optional)
    ///   - maxLength: Maximum allowed length (optional)
    /// - Throws: ValidationError if length constraints are violated
    public static func validateLength(
        _ value: String,
        field: String,
        minLength: Int? = nil,
        maxLength: Int? = nil
    ) throws {
        if let min = minLength, value.count < min {
            throw ValidationError.valueTooShort(field: field, minLength: min)
        }
        
        if let max = maxLength, value.count > max {
            throw ValidationError.valueTooLong(field: field, maxLength: max)
        }
    }
    
    /// Validates that a string is not empty.
    /// 
    /// - Parameters:
    ///   - value: The string to validate
    ///   - field: The field name for error reporting
    /// - Throws: ValidationError.missingRequiredField if empty
    public static func validateNotEmpty(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingRequiredField(field)
        }
    }
    
    /// Validates that a string contains only alphanumeric characters.
    /// 
    /// - Parameters:
    ///   - value: The string to validate
    ///   - field: The field name for error reporting
    ///   - allowedCharacters: Additional allowed characters
    /// - Throws: ValidationError.invalidCharacters if invalid characters found
    public static func validateAlphanumeric(
        _ value: String,
        field: String,
        allowedCharacters: CharacterSet = CharacterSet()
    ) throws {
        let allowed = CharacterSet.alphanumerics.union(allowedCharacters)
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ValidationError.invalidCharacters(field: field)
        }
    }
}