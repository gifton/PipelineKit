import Foundation

/// A command represents an intent to perform an action in the system.
/// 
/// Commands are the primary unit of work in the Command-Pipeline architecture.
/// They encapsulate data and intent, and are processed by command handlers.
/// 
/// All commands must be `Sendable` to ensure thread safety in concurrent environments.
/// 
/// Example:
/// ```swift
/// struct CreateUserCommand: Command {
///     typealias Result = User
///     let email: String
///     let name: String
/// }
/// ```
public protocol Command: Sendable {
    /// The type of result produced when this command is executed.
    /// Must also be `Sendable` for thread safety.
    associatedtype Result: Sendable
}
