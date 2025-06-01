import Foundation

/// Errors related to encryption operations.
public enum EncryptionError: Error, Sendable, LocalizedError {
    case keyNotFound(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case noSensitiveFields
    case invalidKeyFormat
    case unsupportedAlgorithm(String)
    case invalidData(String)
    case notConfigured(String)
    
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
        case let .unsupportedAlgorithm(algorithm):
            return "Unsupported encryption algorithm: \(algorithm)"
        case let .invalidData(reason):
            return "Invalid encrypted data: \(reason)"
        case let .notConfigured(reason):
            return "Encryption service not properly configured: \(reason)"
        }
    }
}