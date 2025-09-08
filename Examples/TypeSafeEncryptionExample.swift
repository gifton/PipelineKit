import Foundation
import PipelineKit
import PipelineKitCore
import PipelineKitSecurity

// MARK: - Example Command with Sensitive Data

struct CreateUserCommand: Command, EncryptableCommand {
    typealias Result = UserProfile
    
    let username: String
    let email: String
    let password: String  // Sensitive
    let age: Int
    let isActive: Bool
    let joinDate: Date
    let metadata: [String: String]  // Potentially sensitive
    
    // Define which fields are sensitive
    var sensitiveData: [String: any Encodable] {
        return [
            "password": password,
            "metadata": metadata
        ]
    }
    
    // Create new instance with encrypted data
    func withEncryptedData(_ encryptedData: [String: EncryptedData]) -> CreateUserCommand {
        // In a real implementation, you'd replace the sensitive fields
        // with encrypted placeholders or store the encrypted data separately
        return self // Simplified for example
    }
}

// MARK: - Example Result with Encrypted Data

struct UserProfile: Sendable, DecryptableResult {
    let username: String
    let email: String
    private let encryptedPassword: EncryptedData?
    private let encryptedMetadata: EncryptedData?
    
    // Protocol requirement - expose encrypted fields
    var encryptedData: [String: EncryptedData]? {
        var fields: [String: EncryptedData] = [:]
        if let pwd = encryptedPassword {
            fields["password"] = pwd
        }
        if let meta = encryptedMetadata {
            fields["metadata"] = meta
        }
        return fields.isEmpty ? nil : fields
    }
    
    // Protocol requirement - create instance with decrypted data
    func withDecryptedData(_ decryptedData: [String: DecryptedValue]) -> UserProfile {
        var decryptedPassword: String?
        var decryptedMetadata: [String: String]?
        
        // Extract values with proper type checking
        if let passwordValue = decryptedData["password"] {
            decryptedPassword = passwordValue.get(as: String.self)
            
            // If it's TypedData, we can decode it
            if let typedData = passwordValue.get(as: TypedData.self) {
                if let decoded = try? typedData.decode(as: String.self) {
                    decryptedPassword = decoded
                }
            }
        }
        
        if let metadataValue = decryptedData["metadata"] {
            decryptedMetadata = metadataValue.get(as: [String: String].self)
            
            // Handle TypedData case
            if let typedData = metadataValue.get(as: TypedData.self) {
                if let decoded = try? typedData.decode(as: [String: String].self) {
                    decryptedMetadata = decoded
                }
            }
        }
        
        // In a real implementation, you'd create a new instance
        // with the decrypted values
        print("Decrypted password type: \(type(of: decryptedPassword))")
        print("Decrypted metadata type: \(type(of: decryptedMetadata))")
        
        return self
    }
    
    init(username: String, email: String, encryptedPassword: EncryptedData? = nil, encryptedMetadata: EncryptedData? = nil) {
        self.username = username
        self.email = email
        self.encryptedPassword = encryptedPassword
        self.encryptedMetadata = encryptedMetadata
    }
}

// MARK: - Example Usage

@main
struct TypeSafeEncryptionExample {
    static func main() async throws {
        print("=== Type-Safe Encryption Example ===\n")
        
        // Create mock encryption service
        let encryptionService = MockEncryptionService()
        
        // Create encryption middleware
        let encryptionMiddleware = EncryptionMiddleware(
            encryptionService: encryptionService,
            sensitiveFields: ["password", "metadata"]
        )
        
        // Create command with various data types
        let command = CreateUserCommand(
            username: "john_doe",
            email: "john@example.com",
            password: "super_secret_password_123",  // String
            age: 30,  // Int
            isActive: true,  // Bool
            joinDate: Date(),  // Date
            metadata: ["ssn": "123-45-6789", "phone": "555-0123"]  // Dictionary
        )
        
        print("Original Command:")
        print("  Username: \(command.username)")
        print("  Password: \(command.password)")
        print("  Age: \(command.age)")
        print("  Active: \(command.isActive)")
        print("  Metadata: \(command.metadata)")
        print()
        
        // Simulate encryption/decryption flow
        print("Encryption would preserve type information:")
        print("  - password: String → EncryptedData(typeHint: \"String\")")
        print("  - metadata: Dictionary → EncryptedData(typeHint: \"Dictionary<String, String>\")")
        print()
        
        // Show how decryption works with type preservation
        print("Decryption uses type hints to restore correct types:")
        print("  - EncryptedData(typeHint: \"String\") → String")
        print("  - EncryptedData(typeHint: \"Dictionary<String, String>\") → [String: String]")
        print()
        
        print("Benefits of Type-Safe Encryption:")
        print("  ✅ No data loss during encryption/decryption")
        print("  ✅ Type safety maintained throughout pipeline")
        print("  ✅ Custom types supported via JSON encoding")
        print("  ✅ Partial decryption possible with error handling")
        print("  ✅ Audit trail with field-level tracking")
    }
}

// MARK: - Mock Encryption Service

struct MockEncryptionService: EncryptionService {
    func encrypt<T: Encodable>(_ value: T) async throws -> EncryptedData {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        
        // Mock encryption - just return the data with metadata
        return EncryptedData(
            ciphertext: data,
            nonce: Data(repeating: 0, count: 12),
            tag: nil,
            algorithm: "AES-GCM-256",
            encryptedAt: Date(),
            typeHint: String(describing: T.self),
            encodingFormat: "json"
        )
    }
    
    func decrypt<T: Decodable>(_ data: EncryptedData, as type: T.Type) async throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data.ciphertext)
    }
    
    func validate() async throws {
        // Mock validation
    }
}