import Foundation

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
    public static func removeNonPrintable(_ input: String) -> String {
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