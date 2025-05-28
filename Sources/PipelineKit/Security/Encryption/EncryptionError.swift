import Foundation

/// Errors related to encryption operations.
public enum EncryptionError: Error, Sendable, LocalizedError {
    case keyNotFound(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case noSensitiveFields
    case invalidKeyFormat
    
    public var errorDescription: String? {
        switch self {
        case let .keyNotFound(identifier):
            return "Encryption key not found: \(identifier)"
        case let .encryptionFailed(reason):
            return "Encryption failed: \(reason)"
        case let .decryptionFailed(reason):
            return "Decryption failed: \(reason)"
        case .noSensitiveFields:
            return "No sensitive fields marked for encryption"
        case .invalidKeyFormat:
            return "Invalid encryption key format"
        }
    }
}