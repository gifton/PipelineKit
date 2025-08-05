import Foundation
import PipelineKit
import PipelineKitCore

/// Mock encryptor for testing encryption - provides a simple implementation without inheritance
public actor MockEncryptor {
    private let encryptionKey: String
    private var encryptedCommands: [String] = []
    
    public init(key: String = "test-key") {
        self.encryptionKey = key
    }
    
    public func encrypt<T: Command>(_ command: T) async throws -> Data where T: Encodable {
        encryptedCommands.append(String(describing: type(of: command)))
        
        // Simple mock encryption - just encode to JSON and prefix with key
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(command)
        let encrypted = "\(encryptionKey):::\(jsonData.base64EncodedString())"
        return encrypted.data(using: .utf8)!
    }
    
    public func getEncryptedCommands() -> [String] {
        encryptedCommands
    }
}

/// Mock decryptor for testing decryption operations
public actor MockDecryptor {
    private let encryptionKey: String
    private var decryptedCount = 0
    
    public init(key: String = "test-key") {
        self.encryptionKey = key
    }
    
    public func decrypt<T: Command>(_ data: Data, as type: T.Type) async throws -> T where T: Decodable {
        decryptedCount += 1
        
        // Simple mock decryption
        guard let encrypted = String(data: data, encoding: .utf8),
              encrypted.hasPrefix("\(encryptionKey):::") else {
            throw MockEncryptionError.invalidKey
        }
        
        let base64 = String(encrypted.dropFirst(encryptionKey.count + 3))
        guard let jsonData = Data(base64Encoded: base64) else {
            throw MockEncryptionError.invalidData
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: jsonData)
    }
    
    public func getDecryptedCount() -> Int {
        decryptedCount
    }
}

public enum MockEncryptionError: LocalizedError {
    case invalidKey
    case invalidData
    
    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Invalid encryption key"
        case .invalidData:
            return "Invalid encrypted data format"
        }
    }
}
