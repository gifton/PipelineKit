import Foundation

/// Represents validation errors that can occur during command validation.
public enum ValidationError: Error, Sendable, LocalizedError, Equatable, Hashable {
    case invalidEmail
    case weakPassword
    case missingRequiredField(String)
    case invalidFormat(field: String, expectedFormat: String)
    case valueTooLong(field: String, maxLength: Int)
    case valueTooShort(field: String, minLength: Int)
    case invalidCharacters(field: String)
    case custom(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "Invalid email address format"
        case .weakPassword:
            return "Password does not meet security requirements"
        case .missingRequiredField(let field):
            return "Required field '\(field)' is missing"
        case .invalidFormat(let field, let format):
            return "Field '\(field)' does not match expected format: \(format)"
        case .valueTooLong(let field, let maxLength):
            return "Field '\(field)' exceeds maximum length of \(maxLength)"
        case .valueTooShort(let field, let minLength):
            return "Field '\(field)' is shorter than minimum length of \(minLength)"
        case .invalidCharacters(let field):
            return "Field '\(field)' contains invalid characters"
        case .custom(let message):
            return message
        }
    }
}