import Foundation

/// A thread-safe wrapper for DateFormatter that satisfies Sendable requirements.
///
/// This wrapper uses thread-local storage to ensure each thread has its own
/// DateFormatter instance, eliminating any possibility of concurrent access
/// while providing optimal performance.
///
/// ## Usage
/// ```swift
/// let formatter = SendableDateFormatter(dateFormat: "HH:mm:ss.SSS")
/// let formattedDate = formatter.string(from: Date())
/// ```
public final class SendableDateFormatter: Sendable {
    private let dateFormat: String
    private let timeZone: TimeZone?
    private let locale: Locale?
    
    /// Thread-local storage key unique to this formatter configuration
    private var threadLocalKey: String {
        "SendableDateFormatter.\(dateFormat).\(timeZone?.identifier ?? "default").\(locale?.identifier ?? "default")"
    }
    
    /// Creates a new thread-safe date formatter
    /// - Parameters:
    ///   - dateFormat: The date format string
    ///   - timeZone: Optional time zone (defaults to current)
    ///   - locale: Optional locale (defaults to current)
    public init(
        dateFormat: String,
        timeZone: TimeZone? = nil,
        locale: Locale? = nil
    ) {
        self.dateFormat = dateFormat
        self.timeZone = timeZone
        self.locale = locale
    }
    
    /// Thread-safe access to the underlying DateFormatter
    private var formatter: DateFormatter {
        if let existing = Thread.current.threadDictionary[threadLocalKey] as? DateFormatter {
            return existing
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        if let timeZone = timeZone {
            formatter.timeZone = timeZone
        }
        if let locale = locale {
            formatter.locale = locale
        }
        
        Thread.current.threadDictionary[threadLocalKey] = formatter
        return formatter
    }
    
    /// Formats a date to string in a thread-safe manner
    /// - Parameter date: The date to format
    /// - Returns: The formatted date string
    public func string(from date: Date) -> String {
        formatter.string(from: date)
    }
    
    /// Parses a string to date in a thread-safe manner
    /// - Parameter string: The date string to parse
    /// - Returns: The parsed date, or nil if parsing fails
    public func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

// MARK: - Convenience Factory Methods

public extension SendableDateFormatter {
    /// Creates a formatter for timestamps in HH:mm:ss.SSS format
    static func timestamp() -> SendableDateFormatter {
        SendableDateFormatter(dateFormat: "HH:mm:ss.SSS")
    }
    
    /// Creates a formatter for ISO 8601 dates
    static func iso8601() -> SendableDateFormatter {
        SendableDateFormatter(
            dateFormat: "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
    
    /// Creates a formatter for short time format (HH:mm:ss)
    static func shortTime() -> SendableDateFormatter {
        SendableDateFormatter(dateFormat: "HH:mm:ss")
    }
}
