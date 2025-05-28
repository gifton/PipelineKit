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