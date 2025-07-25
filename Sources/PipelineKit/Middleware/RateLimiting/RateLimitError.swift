import Foundation

/// Rate limit specific errors.
public enum RateLimitError: Error, Sendable, LocalizedError {
    case limitExceeded(remaining: Int, resetAt: Date)
    
    public var errorDescription: String? {
        switch self {
        case let .limitExceeded(remaining, resetAt):
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            return "Rate limit exceeded. Remaining: \(remaining). Reset at: \(formatter.string(from: resetAt))"
        }
    }
}