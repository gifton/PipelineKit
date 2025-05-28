import Foundation

public enum AuthorizationError: Error, Sendable, Equatable, Hashable, LocalizedError {
    case notAuthenticated
    case insufficientPermissions
    
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "User is not authenticated"
        case .insufficientPermissions:
            return "User does not have sufficient permissions for this operation"
        }
    }
}