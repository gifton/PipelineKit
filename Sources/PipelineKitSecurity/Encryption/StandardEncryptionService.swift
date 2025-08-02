import Foundation
import CryptoKit
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

/// Standard AES-GCM encryption service
struct StandardEncryptionService: EncryptionService {
    private let key: SymmetricKey
    
    init(key: SymmetricKey? = nil) {
        self.key = key ?? SymmetricKey(size: .bits256)
    }
    
    func encrypt<T: Encodable>(_ value: T) async throws -> EncryptedData {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            
            return EncryptedData(
                ciphertext: sealed.ciphertext,
                nonce: sealed.nonce.withUnsafeBytes { Data($0) },
                tag: sealed.tag,
                algorithm: "AES-GCM-256"
            )
        } catch {
            throw PipelineError.encryption(reason: .encryptionFailed(error.localizedDescription))
        }
    }
    
    func decrypt<T: Decodable>(_ data: EncryptedData, as type: T.Type) async throws -> T {
        guard data.algorithm == "AES-GCM-256" else {
            throw PipelineError.encryption(reason: .algorithmNotSupported(data.algorithm))
        }
        
        guard let tag = data.tag else {
            throw PipelineError.encryption(reason: .decryptionFailed("Missing authentication tag"))
        }
        
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: data.nonce),
                ciphertext: data.ciphertext,
                tag: tag
            )
            
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            
            let decoder = JSONDecoder()
            return try decoder.decode(type, from: decryptedData)
        } catch {
            throw PipelineError.encryption(reason: .decryptionFailed(error.localizedDescription))
        }
    }
    
    func validate() async throws {
        // Test encryption/decryption
        let testData = "validation_test"
        let encrypted = try await encrypt(testData)
        let decrypted = try await decrypt(encrypted, as: String.self)
        
        guard decrypted == testData else {
            throw PipelineError.encryption(reason: .encryptionFailed("Encryption service not properly configured: Validation failed"))
        }
    }
}