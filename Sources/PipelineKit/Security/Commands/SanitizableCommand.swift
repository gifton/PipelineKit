import Foundation

/// Protocol for commands that require data sanitization.
/// 
/// Implement this protocol to enable automatic sanitization of command data
/// before execution. This helps prevent injection attacks and ensures data
/// consistency.
/// 
/// Example:
/// ```swift
/// struct CreatePostCommand: Command, SanitizableCommand {
///     typealias Result = Post
///     let title: String
///     let content: String
///     
///     func sanitized() -> CreatePostCommand {
///         CreatePostCommand(
///             title: title.trimmingCharacters(in: .whitespacesAndNewlines),
///             content: CommandSanitizer.sanitizeHTML(content)
///         )
///     }
/// }
/// ```
public protocol SanitizableCommand: Command {
    /// Returns a sanitized copy of the command.
    /// 
    /// This method should return a new instance with sanitized data,
    /// removing or escaping potentially dangerous content.
    func sanitized() -> Self
}