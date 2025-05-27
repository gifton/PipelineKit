import Foundation

/// Protocol for commands that require validation.
/// 
/// Implement this protocol to enable automatic validation of command data
/// before execution. This is a key security feature to prevent invalid
/// or malicious data from being processed.
/// 
/// Example:
/// ```swift
/// struct CreateUserCommand: Command, ValidatableCommand {
///     typealias Result = User
///     let email: String
///     let password: String
///     
///     func validate() throws {
///         guard email.contains("@") else {
///             throw ValidationError.invalidEmail
///         }
///         guard password.count >= 8 else {
///             throw ValidationError.weakPassword
///         }
///     }
/// }
/// ```
public protocol ValidatableCommand: Command {
    /// Validates the command's data.
    /// 
    /// - Throws: ValidationError if the command data is invalid
    func validate() throws
}

/// Represents validation errors that can occur during command validation.
public enum ValidationError: Error, Sendable, LocalizedError {
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

/// Middleware that validates commands before execution.
/// 
/// This middleware automatically validates any command that conforms to
/// ValidatableCommand protocol, providing a security layer that ensures
/// only valid data is processed.
/// 
/// Example:
/// ```swift
/// let bus = CommandBus()
/// await bus.addMiddleware(ValidationMiddleware())
/// ```
/// 
/// For proper security, use with priority ordering:
/// ```swift
/// let pipeline = PriorityPipeline(handler: handler)
/// try await pipeline.addMiddleware(
///     ValidationMiddleware(),
///     priority: MiddlewareOrder.validation.rawValue
/// )
/// ```
public struct ValidationMiddleware: Middleware {
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if command is validatable
        if let validatableCommand = command as? any ValidatableCommand {
            try validatableCommand.validate()
        }
        
        // Continue to next middleware/handler
        return try await next(command, metadata)
    }
    
    /// Recommended middleware order for this component
    public static var recommendedOrder: MiddlewareOrder { .validation }
}