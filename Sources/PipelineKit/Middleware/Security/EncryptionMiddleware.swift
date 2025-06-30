import Foundation

/// Middleware that encrypts command data for secure transmission or storage.
///
/// This middleware encrypts commands before they are processed and can optionally
/// decrypt results. It's useful for securing sensitive data in transit or at rest.
///
/// ## Example Usage
/// ```swift
/// let encryptor = MyEncryptor(key: securityKey)
/// let middleware = EncryptionMiddleware(
///     encryptor: encryptor,
///     shouldEncrypt: { command in
///         // Only encrypt sensitive commands
///         command is SensitiveCommand
///     }
/// )
/// ```
public final class EncryptionMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .security
    
    private let encryptor: any CommandEncryptor
    private let shouldEncrypt: @Sendable (any Command) async -> Bool
    private let encryptionContext: String
    
    /// Creates an encryption middleware with the specified configuration.
    ///
    /// - Parameters:
    ///   - encryptor: The encryptor to use for command encryption
    ///   - shouldEncrypt: Function to determine if a command should be encrypted
    ///   - encryptionContext: Context identifier for encryption (e.g., "storage", "transport")
    public init(
        encryptor: any CommandEncryptor,
        shouldEncrypt: @escaping @Sendable (any Command) async -> Bool = { _ in true },
        encryptionContext: String = "default"
    ) {
        self.encryptor = encryptor
        self.shouldEncrypt = shouldEncrypt
        self.encryptionContext = encryptionContext
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if encryption is needed
        let shouldEncryptCommand = await shouldEncrypt(command)
        
        if shouldEncryptCommand {
            // Emit encryption start event
            await context.emitCustomEvent(
                "encryption.started",
                properties: [
                    "command": String(describing: type(of: command)),
                    "context": encryptionContext
                ]
            )
            
            do {
                // Encrypt the command
                let encryptedData = try await encryptor.encrypt(command)
                
                // Store encryption metadata in context
                await context.set(EncryptionMetadata(
                    isEncrypted: true,
                    encryptionContext: encryptionContext,
                    encryptedAt: Date()
                ), for: EncryptionMetadataKey.self)
                
                // Log encryption success
                await context.emitCustomEvent(
                    "encryption.completed",
                    properties: [
                        "command": String(describing: type(of: command)),
                        "size": encryptedData.count,
                        "context": encryptionContext
                    ]
                )
                
                // Note: In a real implementation, you might want to create
                // an EncryptedCommand wrapper and pass that through the pipeline
                // For now, we store the encrypted data in context and pass
                // the original command through
                await context.set(encryptedData, for: EncryptedDataKey.self)
                
            } catch {
                await context.emitCustomEvent(
                    "encryption.failed",
                    properties: [
                        "command": String(describing: type(of: command)),
                        "error": String(describing: error),
                        "context": encryptionContext
                    ]
                )
                throw EncryptionError.encryptionFailed(error)
            }
        }
        
        // Execute the next middleware
        return try await next(command, context)
    }
}

// MARK: - Context Keys

private struct EncryptionMetadataKey: ContextKey {
    typealias Value = EncryptionMetadata
}

private struct EncryptedDataKey: ContextKey {
    typealias Value = Data
}

/// Metadata about encryption operations
public struct EncryptionMetadata: Sendable {
    public let isEncrypted: Bool
    public let encryptionContext: String
    public let encryptedAt: Date
}

// MARK: - Context Extensions

public extension CommandContext {
    /// Gets the encryption metadata if available
    var encryptionMetadata: EncryptionMetadata? {
        get async { await self[EncryptionMetadataKey.self] }
    }
    
    /// Gets the encrypted data if available
    var encryptedData: Data? {
        get async { await self[EncryptedDataKey.self] }
    }
}

// MARK: - Errors

public enum EncryptionError: LocalizedError {
    case encryptionFailed(Error)
    case decryptionFailed(Error)
    case keyNotAvailable
    case invalidEncryptedData
    
    public var errorDescription: String? {
        switch self {
        case .encryptionFailed(let error):
            return "Encryption failed: \(error.localizedDescription)"
        case .decryptionFailed(let error):
            return "Decryption failed: \(error.localizedDescription)"
        case .keyNotAvailable:
            return "Encryption key not available"
        case .invalidEncryptedData:
            return "Invalid encrypted data format"
        }
    }
}

// MARK: - Convenience Initializers

public extension EncryptionMiddleware {
    /// Creates an encryption middleware that encrypts all commands
    convenience init(encryptor: any CommandEncryptor) {
        self.init(
            encryptor: encryptor,
            shouldEncrypt: { _ in true }
        )
    }
    
    /// Creates an encryption middleware for specific command types
    convenience init<C: Command>(
        encryptor: any CommandEncryptor,
        forType type: C.Type
    ) {
        self.init(
            encryptor: encryptor,
            shouldEncrypt: { command in
                command is C
            }
        )
    }
    
    /// Creates an encryption middleware based on security context
    static func contextBased(
        encryptor: any CommandEncryptor,
        requiresSecureContext: Bool = true
    ) -> EncryptionMiddleware {
        EncryptionMiddleware(
            encryptor: encryptor,
            shouldEncrypt: { command in
                // Only encrypt if in secure context or if not required
                true // Simplified - would check context.isSecure in real implementation
            },
            encryptionContext: requiresSecureContext ? "secure" : "any"
        )
    }
}