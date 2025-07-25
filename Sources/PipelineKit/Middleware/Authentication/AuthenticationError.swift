import Foundation

/// Errors that can occur during authentication
public enum AuthenticationError: Error, Sendable, Equatable, Hashable, LocalizedError {
    case invalidToken
    case missingToken
    case tokenExpired
    case authenticationFailed(reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "The provided authentication token is invalid"
        case .missingToken:
            return "No authentication token was provided"
        case .tokenExpired:
            return "The authentication token has expired"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        }
    }
}