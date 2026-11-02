import Foundation
import PipelineKit
#if canImport(CryptoKit)
@preconcurrency import CryptoKit
#else
@preconcurrency import Crypto
#endif

/// Encrypts and reconstructs complete Codable commands using AES-GCM-256.
///
/// The returned envelope stores ciphertext and metadata only. Commands must encode
/// all state needed for reconstruction in their Codable conformance.
///
/// ```swift
/// let encryptor = await CommandEncryptor(keyStore: keyStore)
/// let encrypted = try await encryptor.encrypt(command)
/// let decrypted = try await encryptor.decrypt(encrypted)
/// ```
public actor CommandEncryptor {
    private var currentKeySnapshot: EncryptionKeySnapshot
    private let keyRotationInterval: TimeInterval
    private var lastKeyRotation: Date
    private let keyStore: any KeyStore

    /// Creates an encryptor, loading one atomic key snapshot or storing a new key.
    ///
    /// - Parameters:
    ///   - keyStore: Storage that retains keys by their version identifiers.
    ///   - keyRotationInterval: Time before encryption triggers rotation (default: 24 hours).
    public init(
        keyStore: any KeyStore,
        keyRotationInterval: TimeInterval = 86400
    ) async {
        self.keyStore = keyStore
        self.keyRotationInterval = keyRotationInterval
        self.lastKeyRotation = Date()

        if let snapshot = await keyStore.currentKeySnapshot {
            self.currentKeySnapshot = snapshot
        } else {
            let snapshot = EncryptionKeySnapshot(
                key: SendableSymmetricKey(size: .bits256),
                identifier: UUID().uuidString
            )
            await keyStore.store(key: snapshot.key, identifier: snapshot.identifier)
            self.currentKeySnapshot = snapshot
        }
    }

    /// JSON-encodes and encrypts the complete command.
    ///
    /// - Returns: Ciphertext and the identifier of the captured key used to seal it.
    /// - Throws: Encoding or cryptographic errors, or `.invalidKey` for a non-256-bit key.
    public func encrypt<T: Command & Codable>(_ command: T) async throws -> EncryptedCommand<T> {
        await rotateKeyIfNeeded()
        let snapshot = currentKeySnapshot
        guard snapshot.key.key.bitCount == 256 else {
            throw PipelineError.encryption(reason: .invalidKey)
        }

        let data = try JSONEncoder().encode(command)
        let sealed = try AES.GCM.seal(data, using: snapshot.key.key)
        guard let combinedData = sealed.combined else {
            throw PipelineError.encryption(reason: .encryptionFailed("Failed to create sealed box"))
        }

        return EncryptedCommand(
            encryptedData: combinedData,
            keyIdentifier: snapshot.identifier,
            algorithm: "AES-GCM-256"
        )
    }

    /// Authenticates and JSON-decodes a complete command using the envelope's key identifier.
    ///
    /// - Throws: Unsupported-algorithm, missing-key or invalid-key errors; cryptographic
    ///   authentication and decoding errors propagate unchanged. Expired keys cannot be recovered.
    public func decrypt<T: Command & Codable>(_ encrypted: EncryptedCommand<T>) async throws -> T {
        guard encrypted.algorithm == "AES-GCM-256" else {
            throw PipelineError.encryption(reason: .algorithmNotSupported(encrypted.algorithm))
        }
        guard let key = await keyStore.key(for: encrypted.keyIdentifier) else {
            throw PipelineError.encryption(reason: .keyNotFound(identifier: encrypted.keyIdentifier))
        }
        guard key.key.bitCount == 256 else {
            throw PipelineError.encryption(reason: .invalidKey)
        }

        let sealedBox = try AES.GCM.SealedBox(combined: encrypted.encryptedData)
        let data = try AES.GCM.open(sealedBox, using: key.key)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Stores a new key version before publishing its complete snapshot to this encryptor.
    /// Previously stored keys remain governed by the key store's explicit expiration policy.
    public func rotateKey() async {
        let snapshot = EncryptionKeySnapshot(
            key: SendableSymmetricKey(size: .bits256),
            identifier: UUID().uuidString
        )
        await keyStore.store(key: snapshot.key, identifier: snapshot.identifier)
        currentKeySnapshot = snapshot
        lastKeyRotation = Date()
    }

    private func rotateKeyIfNeeded() async {
        if Date().timeIntervalSince(lastKeyRotation) > keyRotationInterval {
            await rotateKey()
        }
    }
}

/// Ciphertext-only envelope. `T` identifies the decoded command type without storing a command.
public struct EncryptedCommand<T: Command>: Sendable {
    /// Combined AES-GCM nonce, ciphertext and authentication tag for the complete encoded command.
    public let encryptedData: Data

    /// Identifier of the key used to produce `encryptedData`.
    public let keyIdentifier: String

    /// Format identifier; `CommandEncryptor` produces and accepts `AES-GCM-256`.
    public let algorithm: String

    public init(encryptedData: Data, keyIdentifier: String, algorithm: String) {
        self.encryptedData = encryptedData
        self.keyIdentifier = keyIdentifier
        self.algorithm = algorithm
    }
}

/// Sendable wrapper for SymmetricKey to work with Swift 6 strict concurrency.
/// The wrapped key is an immutable value stored in a `let` property; this wrapper
/// exposes no mutation of that value.
public struct SendableSymmetricKey: @unchecked Sendable {
    public let key: SymmetricKey
    
    public init(_ key: SymmetricKey) {
        self.key = key
    }
    
    public init(size: SymmetricKeySize) {
        self.key = SymmetricKey(size: size)
    }
}

/// Protocol for key storage implementations.
public protocol KeyStore: Sendable {
    /// The current key and its identifier, captured atomically by the store.
    /// Implementations must return both values from the same stored version.
    var currentKeySnapshot: EncryptionKeySnapshot? { get async }
    
    /// Retrieve a key by identifier
    func key(for identifier: String) async -> SendableSymmetricKey?
    
    /// Store a key and publish its current snapshot atomically. Use a fresh identifier
    /// for each key version and retain previous versions until explicitly expired.
    func store(key: SendableSymmetricKey, identifier: String) async
    
    /// Remove expired keys
    func removeExpiredKeys(before date: Date) async
}

// Note: InMemoryKeyStore has been moved to PipelineKitTestSupport for test usage

/// Secure field masking for logging encrypted commands.
internal struct MaskedField: CustomStringConvertible, Sendable {
    private let maskedValue: String
    
    internal init(length: Int) {
        self.maskedValue = String(repeating: "*", count: min(length, 8))
    }
    
    var description: String {
        maskedValue
    }
}
