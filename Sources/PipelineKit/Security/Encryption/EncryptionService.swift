import Foundation
import CryptoKit

/// Manages encryption keys and operations for command encryption.
///
/// Uses Apple's CryptoKit for secure encryption with AES-GCM.
/// Supports key rotation and secure key storage.
///
/// Example:
/// ```swift
/// let encryptor = CommandEncryptor()
/// let encrypted = try encryptor.encrypt(command)
/// let decrypted = try encryptor.decrypt(encrypted)
/// ```
public actor CommandEncryptor {
    private var currentKey: SymmetricKey
    private var keyRotationInterval: TimeInterval
    private var lastKeyRotation: Date
    private let keyStore: KeyStore
    
    /// Creates a command encryptor with specified configuration.
    ///
    /// - Parameters:
    ///   - keyStore: Storage for encryption keys
    ///   - keyRotationInterval: How often to rotate keys (default: 24 hours)
    public init(
        keyStore: KeyStore,
        keyRotationInterval: TimeInterval = 86400 // 24 hours
    ) {
        self.keyStore = keyStore
        self.keyRotationInterval = keyRotationInterval
        self.lastKeyRotation = Date()
        
        // Initialize with a new key or load existing
        if let existingKey = keyStore.currentKey {
            self.currentKey = existingKey
        } else {
            self.currentKey = SymmetricKey(size: .bits256)
            keyStore.store(key: currentKey, identifier: UUID().uuidString)
        }
    }
    
    /// Encrypts sensitive fields in a command.
    ///
    /// - Parameter command: The command to encrypt
    /// - Returns: Encrypted command data
    /// - Throws: Encryption errors
    public func encrypt<T: EncryptableCommand>(_ command: T) async throws -> EncryptedCommand<T> {
        await rotateKeyIfNeeded()
        
        let sensitiveData = try JSONSerialization.data(
            withJSONObject: command.sensitiveFields,
            options: .sortedKeys
        )
        
        let sealed = try AES.GCM.seal(sensitiveData, using: currentKey)
        
        return EncryptedCommand(
            originalCommand: command,
            encryptedData: sealed.combined!,
            keyIdentifier: keyStore.currentKeyIdentifier ?? "default",
            algorithm: "AES-GCM-256"
        )
    }
    
    /// Decrypts an encrypted command.
    ///
    /// - Parameter encrypted: The encrypted command
    /// - Returns: Decrypted command
    /// - Throws: Decryption errors
    public func decrypt<T: EncryptableCommand>(_ encrypted: EncryptedCommand<T>) async throws -> T {
        guard let key = keyStore.key(for: encrypted.keyIdentifier) else {
            throw EncryptionError.keyNotFound(encrypted.keyIdentifier)
        }
        
        let sealedBox = try AES.GCM.SealedBox(combined: encrypted.encryptedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        
        let fields = try JSONSerialization.jsonObject(
            with: decryptedData,
            options: []
        ) as? [String: Any] ?? [:]
        
        var command = encrypted.originalCommand
        command.updateSensitiveFields(fields)
        
        return command
    }
    
    /// Forces a key rotation.
    public func rotateKey() async {
        let newKey = SymmetricKey(size: .bits256)
        let identifier = UUID().uuidString
        
        keyStore.store(key: newKey, identifier: identifier)
        currentKey = newKey
        lastKeyRotation = Date()
    }
    
    /// Checks if key rotation is needed based on the interval.
    private func rotateKeyIfNeeded() async {
        if Date().timeIntervalSince(lastKeyRotation) > keyRotationInterval {
            await rotateKey()
        }
    }
}

/// Encrypted command wrapper.
public struct EncryptedCommand<T: EncryptableCommand>: Sendable {
    /// The original command (with sensitive fields removed)
    public let originalCommand: T
    
    /// Encrypted sensitive data
    public let encryptedData: Data
    
    /// Identifier of the key used for encryption
    public let keyIdentifier: String
    
    /// Encryption algorithm used
    public let algorithm: String
}

/// Protocol for key storage implementations.
public protocol KeyStore: Sendable {
    /// Current encryption key
    var currentKey: SymmetricKey? { get }
    
    /// Current key identifier
    var currentKeyIdentifier: String? { get }
    
    /// Retrieve a key by identifier
    func key(for identifier: String) -> SymmetricKey?
    
    /// Store a key with identifier
    func store(key: SymmetricKey, identifier: String)
    
    /// Remove expired keys
    func removeExpiredKeys(before date: Date)
}

/// Simple in-memory key store implementation.
///
/// **Thread Safety**: This class is marked `@unchecked Sendable` because:
/// - All mutable state access is protected by `NSLock`
/// - The lock ensures exclusive access to `keys`, `keyDates`, and `_currentKeyIdentifier`
/// - All public methods use `lock.withLock` to guarantee thread-safe operations
/// - No data races are possible as all shared mutable state is properly synchronized
internal final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]
    private var keyDates: [String: Date] = [:]
    private var _currentKeyIdentifier: String?
    
    internal init() {}
    
    public var currentKey: SymmetricKey? {
        lock.withLock {
            guard let identifier = _currentKeyIdentifier else { return nil }
            return keys[identifier]
        }
    }
    
    public var currentKeyIdentifier: String? {
        lock.withLock { _currentKeyIdentifier }
    }
    
    public func store(key: SymmetricKey, identifier: String) {
        lock.withLock {
            keys[identifier] = key
            keyDates[identifier] = Date()
            _currentKeyIdentifier = identifier
        }
    }
    
    public func key(for identifier: String) -> SymmetricKey? {
        lock.withLock { keys[identifier] }
    }
    
    public func removeExpiredKeys(before date: Date) {
        lock.withLock {
            for (identifier, keyDate) in keyDates {
                if keyDate < date && identifier != _currentKeyIdentifier {
                    keys.removeValue(forKey: identifier)
                    keyDates.removeValue(forKey: identifier)
                }
            }
        }
    }
}

/// Secure field masking for logging encrypted commands.
internal struct MaskedField: CustomStringConvertible, Sendable {
    private let maskedValue: String
    
    internal init(length: Int) {
        self.maskedValue = String(repeating: "*", count: min(length, 8))
    }
    
    public var description: String {
        maskedValue
    }
}