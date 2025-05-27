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
///     var title: String
///     var content: String
///     
///     mutating func sanitize() {
///         title = title.trimmingCharacters(in: .whitespacesAndNewlines)
///         content = CommandSanitizer.sanitizeHTML(content)
///     }
/// }
/// ```
public protocol SanitizableCommand: Command {
    /// Sanitizes the command's data.
    /// 
    /// This method should modify the command's properties to remove
    /// or escape potentially dangerous content.
    mutating func sanitize()
}

/// Provides common sanitization utilities for command data.
public struct CommandSanitizer: Sendable {
    
    /// Sanitizes a string by removing potentially dangerous HTML/script content.
    /// 
    /// - Parameter input: The string to sanitize
    /// - Returns: Sanitized string with dangerous content removed
    public static func sanitizeHTML(_ input: String) -> String {
        var sanitized = input
        
        // Remove script tags and content
        let scriptPattern = #"<script[^>]*>[\s\S]*?</script>"#
        sanitized = sanitized.replacingOccurrences(
            of: scriptPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Remove event handlers
        let eventPattern = #"\s*on\w+\s*=\s*["'][^"']*["']"#
        sanitized = sanitized.replacingOccurrences(
            of: eventPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Escape remaining HTML entities
        return escapeHTML(sanitized)
    }
    
    /// Escapes HTML entities in a string.
    /// 
    /// - Parameter input: The string to escape
    /// - Returns: String with HTML entities escaped
    public static func escapeHTML(_ input: String) -> String {
        return input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    
    /// Sanitizes a string for SQL queries by escaping special characters.
    /// 
    /// Note: This is a basic implementation. For production use,
    /// always use parameterized queries instead of string sanitization.
    /// 
    /// - Parameter input: The string to sanitize
    /// - Returns: SQL-safe string
    public static func sanitizeSQL(_ input: String) -> String {
        return input
            .replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    /// Removes non-printable characters from a string.
    /// 
    /// - Parameter input: The string to clean
    /// - Returns: String with only printable characters
    public static func removNonPrintable(_ input: String) -> String {
        let printable = CharacterSet.alphanumerics
            .union(.punctuationCharacters)
            .union(.whitespaces)
            .union(.symbols)
        
        return input.unicodeScalars
            .filter { printable.contains($0) }
            .map { String($0) }
            .joined()
    }
    
    /// Truncates a string to a maximum length.
    /// 
    /// - Parameters:
    ///   - input: The string to truncate
    ///   - maxLength: Maximum allowed length
    ///   - suffix: Optional suffix to append when truncated (default: "...")
    /// - Returns: Truncated string
    public static func truncate(_ input: String, maxLength: Int, suffix: String = "...") -> String {
        guard input.count > maxLength else { return input }
        
        let endIndex = input.index(input.startIndex, offsetBy: maxLength - suffix.count)
        return String(input[..<endIndex]) + suffix
    }
}

/// Middleware that sanitizes commands before execution.
/// 
/// This middleware automatically sanitizes any command that conforms to
/// SanitizableCommand protocol, providing a security layer that cleans
/// potentially dangerous input data.
/// 
/// Example:
/// ```swift
/// let bus = CommandBus()
/// await bus.addMiddleware(SanitizationMiddleware())
/// ```
/// 
/// For proper security, use with priority ordering:
/// ```swift
/// let pipeline = PriorityPipeline(handler: handler)
/// try await pipeline.addMiddleware(
///     SanitizationMiddleware(),
///     priority: MiddlewareOrder.sanitization.rawValue
/// )
/// ```
public struct SanitizationMiddleware: Middleware {
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        var sanitizedCommand = command
        
        // Check if command is sanitizable
        if var sanitizableCommand = sanitizedCommand as? any SanitizableCommand {
            sanitizableCommand.sanitize()
            sanitizedCommand = sanitizableCommand as! T
        }
        
        // Continue to next middleware/handler
        return try await next(sanitizedCommand, metadata)
    }
    
    /// Recommended middleware order for this component
    public static var recommendedOrder: MiddlewareOrder { .sanitization }
}