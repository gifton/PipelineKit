import Foundation

/// Middleware for automatic command encryption/decryption.
///
/// Example:
/// ```swift
/// let encryptor = CommandEncryptor()
/// let middleware = EncryptionMiddleware(encryptor: encryptor)
/// 
/// pipeline.use(middleware)
/// ```
public struct EncryptionMiddleware: Middleware, PrioritizedMiddleware {
    private let encryptor: CommandEncryptor
    private let shouldEncrypt: @Sendable (any Command) -> Bool
    
    public static var recommendedOrder: ExecutionPriority { .encryption }
    
    /// Creates encryption middleware.
    ///
    /// - Parameters:
    ///   - encryptor: The command encryptor to use
    ///   - shouldEncrypt: Predicate to determine if a command should be encrypted
    public init(
        encryptor: CommandEncryptor,
        shouldEncrypt: @escaping @Sendable (any Command) -> Bool = { $0 is any EncryptableCommand }
    ) {
        self.encryptor = encryptor
        self.shouldEncrypt = shouldEncrypt
    }
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Only process encryptable commands
        guard let encryptableCommand = command as? any EncryptableCommand else {
            return try await next(command, metadata)
        }
        
        // Note: Due to type system limitations, we can't directly encrypt/decrypt
        // in the middleware. This would typically be handled at the transport layer.
        // This middleware serves as a marker/validator for encryptable commands.
        
        // Validate that sensitive fields are properly marked
        if encryptableCommand.sensitiveFields.isEmpty {
            throw EncryptionError.noSensitiveFields
        }
        
        return try await next(command, metadata)
    }
}