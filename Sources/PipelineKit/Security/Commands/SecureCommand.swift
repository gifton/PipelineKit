import Foundation

/// A command that implements both validation and sanitization.
/// 
/// This protocol combines ValidatableCommand and SanitizableCommand
/// for commands that require both security measures.
public protocol SecureCommand: ValidatableCommand, SanitizableCommand {}