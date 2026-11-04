import Foundation
import PipelineKit

/// Service protocol for encrypting and decrypting data
public protocol EncryptionService: Sendable {
    func encrypt<T: Encodable>(_ value: T) async throws -> EncryptedData
    func decrypt<T: Decodable>(_ data: EncryptedData, as type: T.Type) async throws -> T
    func validate() async throws
}

/// Opt-in access to authenticated serialized plaintext for field-level results.
///
/// Conformers must authenticate the encrypted payload before returning its exact
/// plaintext bytes. Do not deserialize and re-encode the payload, or return bytes
/// when authentication fails. This is distinct from `decrypt(_:as: Data.self)`,
/// which decodes a serialized `Data` value (for example, a JSON base64 string).
///
/// `typeHint` and `encodingFormat` are advisory, untrusted metadata. The current
/// AES-GCM service authenticates only the serialized plaintext, not these fields.
/// Callers must select and validate the expected type and format independently.
public protocol SerializedPlaintextDecrypting: EncryptionService {
    /// Decrypts an authenticated payload into its original serialized plaintext bytes.
    ///
    /// Conformers must authenticate before returning bytes and must not deserialize
    /// or re-encode the plaintext. Callers must independently validate the expected
    /// type and encoding format; the container's advisory metadata is untrusted.
    /// - Parameter data: The encrypted payload and its associated container metadata.
    /// - Returns: The exact serialized plaintext, before value decoding.
    /// - Throws: An error if authentication or decryption fails.
    func decryptSerializedPlaintext(_ data: EncryptedData) async throws -> Data
}

/// Type-erased container for decrypted values
public struct DecryptedValue: Sendable {
    private let value: any Sendable
    private let typeInfo: String
    
    public init<T: Sendable>(_ value: T) {
        self.value = value
        self.typeInfo = String(describing: T.self)
    }
    
    /// Try to get the value as a specific type
    public func get<T: Sendable>(as type: T.Type) -> T? {
        return value as? T
    }
    
    /// Get the underlying value without type checking
    public var anyValue: any Sendable {
        return value
    }
    
    /// Get type information string
    public var storedType: String {
        return typeInfo
    }
}

/// Container for encrypted data with metadata
public struct EncryptedData: Sendable, Codable {
    public let ciphertext: Data
    public let nonce: Data
    public let tag: Data?
    public let algorithm: String
    public let encryptedAt: Date
    /// Type information for proper deserialization
    public let typeHint: String?
    /// Encoding format used (json, plist, etc.)
    public let encodingFormat: String
    
    public init(
        ciphertext: Data,
        nonce: Data,
        tag: Data? = nil,
        algorithm: String = "AES-GCM-256",
        encryptedAt: Date = Date(),
        typeHint: String? = nil,
        encodingFormat: String = "json"
    ) {
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.tag = tag
        self.algorithm = algorithm
        self.encryptedAt = encryptedAt
        self.typeHint = typeHint
        self.encodingFormat = encodingFormat
    }
}
