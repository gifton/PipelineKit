import Foundation

// NOTE: This file requires PipelineKitStressTest types which have been
// moved to a separate package. It should be moved to that package's test suite.
/*

/// Log formatter that sanitizes sensitive information before formatting.
///
/// This formatter wraps another formatter and applies sanitization rules
/// to remove or mask sensitive data patterns like passwords, tokens, keys, etc.
public struct SanitizingLogFormatter: LogFormatter {
    private let baseFormatter: LogFormatter
    private let sanitizers: [LogSanitizer]
    
    public init(
        baseFormatter: LogFormatter? = nil,
        sanitizers: [LogSanitizer]? = nil
    ) {
        self.baseFormatter = baseFormatter ?? DefaultLogFormatter()
        self.sanitizers = sanitizers ?? LogSanitizer.defaultSanitizers
    }
    
    public func format(_ entry: LogEntry) -> String {
        // Sanitize the message
        var sanitizedMessage = entry.message
        for sanitizer in sanitizers {
            sanitizedMessage = sanitizer.sanitize(sanitizedMessage)
        }
        
        // Create sanitized entry
        let sanitizedEntry = LogEntry(
            timestamp: entry.timestamp,
            level: entry.level,
            message: sanitizedMessage,
            file: entry.file,
            function: entry.function,
            line: entry.line,
            threadId: entry.threadId
        )
        
        // Format with base formatter
        return baseFormatter.format(sanitizedEntry)
    }
}

/// Protocol for log sanitization rules
public protocol LogSanitizer: Sendable {
    func sanitize(_ message: String) -> String
}

/// Regex-based sanitizer
public struct RegexSanitizer: LogSanitizer {
    private let pattern: String
    private let replacement: String
    
    public init(pattern: String, replacement: String = "[REDACTED]") {
        self.pattern = pattern
        self.replacement = replacement
    }
    
    public func sanitize(_ message: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return message
        }
        
        let range = NSRange(message.startIndex..., in: message)
        return regex.stringByReplacingMatches(
            in: message,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}

/// Keyword-based sanitizer
public struct KeywordSanitizer: LogSanitizer {
    private let keywords: Set<String>
    private let caseSensitive: Bool
    private let replacement: String
    
    public init(
        keywords: Set<String>,
        caseSensitive: Bool = false,
        replacement: String = "[REDACTED]"
    ) {
        self.keywords = keywords
        self.caseSensitive = caseSensitive
        self.replacement = replacement
    }
    
    public func sanitize(_ message: String) -> String {
        var result = message
        
        for keyword in keywords {
            if caseSensitive {
                result = result.replacingOccurrences(of: keyword, with: replacement)
            } else {
                let options: String.CompareOptions = [.caseInsensitive]
                result = result.replacingOccurrences(
                    of: keyword,
                    with: replacement,
                    options: options
                )
            }
        }
        
        return result
    }
}

/// Value masking sanitizer
public struct ValueMaskingSanitizer: LogSanitizer {
    private let keyPattern: String
    private let maskLength: Int
    
    public init(keyPattern: String, maskLength: Int = 8) {
        self.keyPattern = keyPattern
        self.maskLength = maskLength
    }
    
    public func sanitize(_ message: String) -> String {
        // Pattern to match key=value or key:value formats
        let pattern = "(\(keyPattern))\\s*[=:]\\s*([^\\s,;]+)"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return message
        }
        
        let range = NSRange(message.startIndex..., in: message)
        let matches = regex.matches(in: message, options: [], range: range)
        
        var result = message
        
        // Process matches in reverse to maintain string indices
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            
            let valueRange = match.range(at: 2)
            guard let swiftRange = Range(valueRange, in: result) else { continue }
            
            let maskedValue = String(repeating: "*", count: maskLength)
            result.replaceSubrange(swiftRange, with: maskedValue)
        }
        
        return result
    }
}

// MARK: - Default Sanitizers

extension LogSanitizer {
    /// Default set of sanitizers for common sensitive patterns
    public static var defaultSanitizers: [LogSanitizer] {
        [
            // API keys and tokens
            RegexSanitizer(
                pattern: "\\b(?:api[_-]?key|token|secret|password)\\s*[=:]\\s*['\"]?([^'\"\\s]+)['\"]?",
                replacement: "$1=[REDACTED]"
            ),
            
            // Credit card numbers
            RegexSanitizer(
                pattern: "\\b\\d{4}[\\s-]?\\d{4}[\\s-]?\\d{4}[\\s-]?\\d{3,4}\\b",
                replacement: "[CARD-REDACTED]"
            ),
            
            // Email addresses (optional - uncomment if needed)
            // RegexSanitizer(
            //     pattern: "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}\\b",
            //     replacement: "[EMAIL-REDACTED]"
            // ),
            
            // Bearer tokens
            RegexSanitizer(
                pattern: "Bearer\\s+[A-Za-z0-9\\-._~+/]+=*",
                replacement: "Bearer [TOKEN-REDACTED]"
            ),
            
            // AWS credentials
            RegexSanitizer(
                pattern: "AKIA[0-9A-Z]{16}",
                replacement: "[AWS-KEY-REDACTED]"
            ),
            
            // Generic sensitive keywords
            KeywordSanitizer(
                keywords: ["password", "passwd", "pwd", "secret", "private_key"],
                caseSensitive: false
            ),
            
            // Value masking for common sensitive fields
            ValueMaskingSanitizer(keyPattern: "password|passwd|pwd|token|secret|api_key|apikey")
        ]
    }
}
*/

// Placeholder types to prevent compilation errors
public struct SanitizingLogFormatter {}
public protocol LogSanitizer {}