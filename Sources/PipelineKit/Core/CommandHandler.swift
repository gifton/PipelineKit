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
///             throw ValidationError.invalidEmail
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

/// Registration information for a command handler.
/// 
/// Used for tracking and debugging handler registrations in the system.
public protocol CommandHandlerRegistration: Sendable {
    /// The string representation of the command type
    var commandType: String { get }
    
    /// The string representation of the handler type
    var handlerType: String { get }
}

/// A registry for managing command handler registrations.
/// 
/// This protocol defines the interface for registering and retrieving
/// command handlers. Implementations should ensure thread safety.
/// 
/// The `@MainActor` attribute ensures all registry operations happen
/// on the main actor for consistency.
@MainActor
public protocol CommandHandlerRegistry: Sendable {
    /// Registers a handler type for a specific command type.
    /// 
    /// - Parameters:
    ///   - commandType: The type of command to handle
    ///   - handler: The handler type that will process the command
    func register<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H.Type
    ) where H.CommandType == T
    
    /// Retrieves a handler for the specified command type.
    /// 
    /// - Parameter commandType: The type of command to find a handler for
    /// - Returns: The registered handler, or nil if none exists
    func handler<T: Command>(for commandType: T.Type) -> (any CommandHandler)?
}