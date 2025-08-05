import Foundation
import PipelineKitCore

/// Service protocol for encrypting and decrypting data
public protocol EncryptionService: Sendable {
    func encrypt<T: Encodable>(_ value: T) async throws -> EncryptedData
    func decrypt<T: Decodable>(_ data: EncryptedData, as type: T.Type) async throws -> T
    func validate() async throws
}

/// Container for encrypted data with metadata
public struct EncryptedData: Sendable, Codable {
    public let ciphertext: Data
    public let nonce: Data
    public let tag: Data?
    public let algorithm: String
    public let encryptedAt: Date
    
    public init(
        ciphertext: Data,
        nonce: Data,
        tag: Data? = nil,
        algorithm: String = "AES-GCM-256",
        encryptedAt: Date = Date()
    ) {
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.tag = tag
        self.algorithm = algorithm
        self.encryptedAt = encryptedAt
    }
}
