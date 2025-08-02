import Foundation

/// Security extensions for the Command protocol.
///
/// These extensions provide opt-in security capabilities for commands
/// without requiring separate protocol conformances.

// MARK: - Validation

public extension Command {
    /// Default implementation of validate() that performs no validation.
    func validate() throws {
        // Default: no validation required
    }
}

// MARK: - Sanitization

public extension Command {
    /// Default implementation of sanitized() that returns self unchanged.
    func sanitized() throws -> Self {
        // Default: return self unchanged
        return self
    }
}

// MARK: - Encryption

public extension Command {
    /// Fields that should be encrypted.
    ///
    /// Default implementation returns empty dictionary.
    /// Override this property to specify sensitive fields.
    var sensitiveFields: [String: Any] {
        // Default: no sensitive fields
        return [:]
    }
    
    /// Update the command with decrypted fields.
    ///
    /// Default implementation does nothing.
    /// Override this method if your command has mutable sensitive fields.
    ///
    /// - Parameter fields: The decrypted field values
    func updateSensitiveFields(_ fields: [String: Any]) {
        // Default: no-op for immutable commands
        // Commands that need this should make themselves mutable
    }
}

// MARK: - Security Capability Detection

public extension Command {
    /// Whether this command requires validation.
    var requiresValidation: Bool {
        // Check if validate() has been overridden
        // This is a heuristic - in practice, middleware should attempt validation
        // and handle the default no-op gracefully
        return true
    }
    
    /// Whether this command requires sanitization.
    var requiresSanitization: Bool {
        // Similar heuristic for sanitization
        return true
    }
    
    /// Whether this command has sensitive fields requiring encryption.
    var hasSensitiveFields: Bool {
        return !sensitiveFields.isEmpty
    }
}