import Foundation

/// A handler that processes a specific type of command.
/// 
/// Command handlers contain the business logic for processing commands.
/// Each handler is responsible for one command type, following the
/// Single Responsibility Principle.
/// 
/// All handlers must be `Sendable` for thread safety in concurrent environments.
/// 
/// Example:
/// ```swift
/// struct CreateUserHandler: CommandHandler {
///     typealias CommandType = CreateUserCommand
///     
///     func handle(_ command: CreateUserCommand) async throws -> User {
///         // Validate input
///         guard isValidEmail(command.email) else {
///             throw PipelineError.validation(field: "email", reason: .invalidEmail)
///         }
///         
///         // Create and return user
///         return User(email: command.email, name: command.name)
///     }
/// }
/// ```
public protocol CommandHandler: Sendable {
    /// The type of command this handler processes
    associatedtype CommandType: Command
    
    /// Processes the command and returns a result.
    /// 
    /// This method contains the core business logic for the command.
    /// It should be pure in terms of side effects, with all I/O operations
    /// properly managed through dependency injection.
    /// 
    /// - Parameter command: The command to process
    /// - Returns: The result of processing the command
    /// - Throws: Any errors that occur during processing
    func handle(_ command: CommandType) async throws -> CommandType.Result
}
