import Foundation
import PipelineKit
@preconcurrency import CryptoKit

/// Middleware that handles encryption and decryption of sensitive data in commands.
///
/// This middleware provides transparent encryption/decryption of sensitive fields
/// in commands and their results, ensuring data is encrypted at rest and in transit.
///
/// ## Overview
///
/// The encryption middleware:
/// - Encrypts sensitive fields in commands before processing
/// - Decrypts sensitive fields in results before returning
/// - Supports configurable encryption algorithms
/// - Handles key rotation and versioning
/// - Provides field-level encryption
///
/// ## Usage
///
/// ```swift
/// let encryptionMiddleware = EncryptionMiddleware(
///     encryptionService: AESEncryptionService(key: masterKey),
///     sensitiveFields: ["password", "ssn", "creditCard"]
/// )
///
/// let pipeline = StandardPipeline(
///     handler: handler,
///     middleware: [encryptionMiddleware, ...]
/// )
/// ```
///
/// ## Security Considerations
///
/// - Keys should be stored securely (e.g., in Keychain or HSM)
/// - Use authenticated encryption modes (e.g., AES-GCM)
/// - Implement proper key rotation policies
/// - Log encryption operations for audit purposes
///
/// - Note: This middleware has `.preProcessing` priority to ensure encryption
///   happens before most other processing.
///
/// - SeeAlso: `EncryptionService`, `Middleware`
public struct EncryptionMiddleware: Middleware {
    /// Priority ensures encryption happens early in the pipeline.
    public let priority: ExecutionPriority = .preProcessing
    
    /// The encryption service used for cryptographic operations.
    private let encryptionService: EncryptionService
    
    /// Set of field names that should be encrypted.
    private let sensitiveFields: Set<String>
    
    /// Whether to encrypt entire command payloads.
    private let encryptFullPayload: Bool
    
    /// Whether to allow partial decryption if some fields fail.
    private let allowPartialDecryption: Bool
    
    /// Creates a new encryption middleware.
    ///
    /// - Parameters:
    ///   - encryptionService: The service handling encryption/decryption operations
    ///   - sensitiveFields: Field names that contain sensitive data
    ///   - encryptFullPayload: If true, encrypts entire command payload
    public init(
        encryptionService: EncryptionService,
        sensitiveFields: Set<String> = [],
        encryptFullPayload: Bool = false,
        allowPartialDecryption: Bool = false
    ) {
        self.encryptionService = encryptionService
        self.sensitiveFields = sensitiveFields
        self.encryptFullPayload = encryptFullPayload
        self.allowPartialDecryption = allowPartialDecryption
    }
    
    /// Executes encryption/decryption around command processing.
    ///
    /// - Parameters:
    ///   - command: The command being executed
    ///   - context: The command context
    ///   - next: The next handler in the chain
    ///
    /// - Returns: The result from the command execution chain
    ///
    /// - Throws: `EncryptionError` if encryption/decryption fails, or any error
    ///   from the downstream chain
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Encrypt sensitive data in command if needed
        let processedCommand = try await encryptCommand(command, context: context)
        
        // Execute with encrypted command
        let result = try await next(processedCommand, context)
        
        // Decrypt sensitive data in result if needed
        return try await decryptResult(result, context: context)
    }
    
    // MARK: - Private Methods
    
    private func encryptCommand<T: Command>(_ command: T, context: CommandContext) async throws -> T {
        // Check if command supports encryption
        guard let encryptable = command as? any EncryptableCommand else {
            // If not encryptable but we have sensitive fields configured, log warning
            if !sensitiveFields.isEmpty || encryptFullPayload {
                await context.setMetadata("encryption.skipped", value: true)
                await context.setMetadata("encryption.reason", value: "Command does not support encryption")
            }
            return command
        }
        
        // Get sensitive data from the command
        let sensitiveData = encryptable.sensitiveData
        guard !sensitiveData.isEmpty else {
            return command
        }
        
        // Filter to only encrypt configured fields if specified
        let dataToEncrypt: [String: any Encodable]
        if sensitiveFields.isEmpty || encryptFullPayload {
            // Encrypt all sensitive data
            dataToEncrypt = sensitiveData
        } else {
            // Only encrypt specified fields
            dataToEncrypt = sensitiveData.filter { sensitiveFields.contains($0.key) }
        }
        
        guard !dataToEncrypt.isEmpty else {
            return command
        }
        
        // Encrypt each field with type preservation
        var encryptedFields: [String: EncryptedData] = [:]
        for (fieldPath, value) in dataToEncrypt {
            do {
                var encrypted = try await encryptionService.encrypt(value)
                
                // Add type hint to the encrypted data for proper decryption
                let typeHint = String(describing: type(of: value))
                encrypted = EncryptedData(
                    ciphertext: encrypted.ciphertext,
                    nonce: encrypted.nonce,
                    tag: encrypted.tag,
                    algorithm: encrypted.algorithm,
                    encryptedAt: encrypted.encryptedAt,
                    typeHint: typeHint,
                    encodingFormat: encrypted.encodingFormat
                )
                
                encryptedFields[fieldPath] = encrypted
            } catch {
                // Log encryption failure and re-throw
                await context.setMetadata("encryption.failed", value: true)
                await context.setMetadata("encryption.error", value: error.localizedDescription)
                throw EncryptionError.encryptionFailed("Failed to encrypt field \(fieldPath): \(error)")
            }
        }
        
        // Create new command with encrypted data
        let encryptedCommand = encryptable.withEncryptedData(encryptedFields)
        
        // Mark encryption in context
        await context.setMetadata("encryption.applied", value: true)
        await context.setMetadata("encryption.timestamp", value: Date())
        await context.setMetadata("encryption.fieldCount", value: encryptedFields.count)
        
        // Log encryption for audit
        let metadata = await context.getMetadata()
        if let auditLogger = metadata["auditLogger"] as? AuditLogger {
            await auditLogger.log(SecurityAuditEvent(
                action: .encryption,
                resource: String(describing: type(of: command)),
                details: [
                    "fieldsEncrypted": Array(encryptedFields.keys) as any Sendable
                ]
            ))
        }
        
        guard let typedCommand = encryptedCommand as? T else {
            throw EncryptionError.encryptionFailed("Failed to cast encrypted command to type \(T.self)")
        }
        return typedCommand
    }
    
    private func decryptResult<T>(_ result: T, context: CommandContext) async throws -> T {
        // Check if result supports decryption
        guard let decryptable = result as? DecryptableResult,
              let encryptedData = decryptable.encryptedData,
              !encryptedData.isEmpty else {
            return result
        }
        
        // Decrypt each field with type preservation
        var decryptedFields: [String: DecryptedValue] = [:]
        var failedFields: [String] = []
        
        for (fieldPath, encrypted) in encryptedData {
            do {
                // Determine the type to decrypt based on type hint
                let decryptedValue: DecryptedValue
                
                if let typeHint = encrypted.typeHint {
                    // Use type hint to guide decryption
                    switch typeHint {
                    case "String":
                        let value = try await encryptionService.decrypt(encrypted, as: String.self)
                        decryptedValue = DecryptedValue(value)
                    case "Int":
                        let value = try await encryptionService.decrypt(encrypted, as: Int.self)
                        decryptedValue = DecryptedValue(value)
                    case "Double":
                        let value = try await encryptionService.decrypt(encrypted, as: Double.self)
                        decryptedValue = DecryptedValue(value)
                    case "Bool":
                        let value = try await encryptionService.decrypt(encrypted, as: Bool.self)
                        decryptedValue = DecryptedValue(value)
                    case "Date":
                        let value = try await encryptionService.decrypt(encrypted, as: Date.self)
                        decryptedValue = DecryptedValue(value)
                    case "Data":
                        let value = try await encryptionService.decrypt(encrypted, as: Data.self)
                        decryptedValue = DecryptedValue(value)
                    default:
                        // For custom types, try to decrypt as JSON-encoded Data
                        // The result implementation should handle deserialization
                        if encrypted.encodingFormat == "json" {
                            let data = try await encryptionService.decrypt(encrypted, as: Data.self)
                            // Store as Data but with type hint for later deserialization
                            decryptedValue = DecryptedValue(TypedData(data: data, originalType: typeHint))
                        } else {
                            // Fallback to raw Data
                            let data = try await encryptionService.decrypt(encrypted, as: Data.self)
                            decryptedValue = DecryptedValue(data)
                        }
                    }
                } else {
                    // No type hint - fallback to Data and let result handle it
                    let data = try await encryptionService.decrypt(encrypted, as: Data.self)
                    decryptedValue = DecryptedValue(data)
                }
                
                decryptedFields[fieldPath] = decryptedValue
                
            } catch {
                // Log decryption failure
                failedFields.append(fieldPath)
                await context.setMetadata("decryption.failed.\(fieldPath)", value: true)
                await context.setMetadata("decryption.error.\(fieldPath)", value: error.localizedDescription)
                
                // Depending on configuration, we might want to fail or continue
                if !allowPartialDecryption {
                    throw EncryptionError.decryptionFailed("Failed to decrypt field \(fieldPath): \(error)")
                }
            }
        }
        
        // Log overall decryption status
        if !failedFields.isEmpty {
            await context.setMetadata("decryption.partial", value: true)
            await context.setMetadata("decryption.failedFields", value: failedFields)
        }
        
        // Create new result with decrypted data
        let decryptedResult = decryptable.withDecryptedData(decryptedFields)
        
        // Mark decryption in context
        await context.setMetadata("encryption.decrypted", value: true)
        await context.setMetadata("decryption.fieldCount", value: decryptedFields.count)
        await context.setMetadata("decryption.failedCount", value: failedFields.count)
        
        // Log decryption for audit
        let contextMetadata = await context.getMetadata()
        if let auditLogger = contextMetadata["auditLogger"] as? AuditLogger {
            await auditLogger.log(SecurityAuditEvent(
                action: .decryption,
                resource: String(describing: type(of: result)),
                details: [
                    "fieldsDecrypted": Array(decryptedFields.keys) as any Sendable,
                    "failedFields": failedFields as any Sendable
                ]
            ))
        }
        
        guard let typedResult = decryptedResult as? T else {
            throw EncryptionError.decryptionFailed("Failed to cast decrypted result to type \(T.self)")
        }
        return typedResult
    }
}

// MARK: - Supporting Types

/// Helper struct to carry typed data with its original type information
public struct TypedData: Sendable {
    public let data: Data
    public let originalType: String
    
    public init(data: Data, originalType: String) {
        self.data = data
        self.originalType = originalType
    }
    
    /// Attempt to decode the data as a specific Decodable type
    public func decode<T: Decodable>(as type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        return try decoder.decode(type, from: data)
    }
}

// EncryptionService and EncryptedData are defined in EncryptionProtocols.swift

/// Errors that can occur during encryption operations.
public enum EncryptionError: Error, LocalizedError {
    case encryptionFailed(String)
    case decryptionFailed(String)
    case keyNotFound(String)
    case invalidKeyVersion(String)
    case unsupportedAlgorithm(String)
    
    public var errorDescription: String? {
        switch self {
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .decryptionFailed(let reason):
            return "Decryption failed: \(reason)"
        case .keyNotFound(let version):
            return "Encryption key not found for version: \(version)"
        case .invalidKeyVersion(let version):
            return "Invalid key version: \(version)"
        case .unsupportedAlgorithm(let algorithm):
            return "Unsupported encryption algorithm: \(algorithm)"
        }
    }
}

// MARK: - Encryption Service Implementation
// StandardEncryptionService (defined in Encryption/StandardEncryptionService.swift) provides
// the actual AES-GCM encryption implementation that conforms to EncryptionService protocol

// MARK: - Encryptable Protocol

/// Protocol for commands that support field-level encryption.
public protocol EncryptableCommand: Command {
    /// Returns a dictionary of field paths and their values that should be encrypted.
    /// Field paths use dot notation for nested fields (e.g., "user.password").
    var sensitiveData: [String: any Encodable] { get }
    
    /// Creates a new instance with encrypted data replacing the sensitive fields.
    func withEncryptedData(_ encryptedData: [String: EncryptedData]) -> Self
}

/// Protocol for results that may contain encrypted data.
public protocol DecryptableResult {
    /// Returns encrypted data fields that need decryption.
    var encryptedData: [String: EncryptedData]? { get }
    
    /// Creates a new instance with decrypted data.
    /// The DecryptedValue wrapper preserves type information from decryption.
    func withDecryptedData(_ decryptedData: [String: DecryptedValue]) -> Self
}

// MARK: - Security Audit Event
// SecurityAuditEvent is defined in AuditLogger.swift
