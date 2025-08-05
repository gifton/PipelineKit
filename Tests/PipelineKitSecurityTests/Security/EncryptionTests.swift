import XCTest
import CryptoKit
@testable import PipelineKit
@testable import PipelineKitSecurity
import PipelineKitTestSupport

final class EncryptionTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    // MARK: - Test Commands
    
    private struct PaymentCommand: Command {
        var cardNumber: String
        var cvv: String
        let amount: Double
        
        typealias Result = PaymentResult
        
        func execute() async throws -> PaymentResult {
            return PaymentResult(transactionId: "TX123", success: true)
        }
        
        var sensitiveFields: [String: Any] {
            ["cardNumber": cardNumber, "cvv": cvv]
        }
        
        mutating func updateSensitiveFields(_ fields: [String: Any]) {
            if let cardNumber = fields["cardNumber"] as? String {
                self.cardNumber = cardNumber
            }
            if let cvv = fields["cvv"] as? String {
                self.cvv = cvv
            }
        }
    }
    
    private struct PaymentResult: Sendable {
        let transactionId: String
        let success: Bool
    }
    
    private struct UserCommand: Command {
        var ssn: String
        var password: String
        let username: String
        
        typealias Result = String
        
        func execute() async throws -> String {
            return "User: \(username)"
        }
        
        var sensitiveFields: [String: Any] {
            ["ssn": ssn, "password": password]
        }
        
        mutating func updateSensitiveFields(_ fields: [String: Any]) {
            if let ssn = fields["ssn"] as? String {
                self.ssn = ssn
            }
            if let password = fields["password"] as? String {
                self.password = password
            }
        }
    }
    
    // MARK: - Encryption Tests
    
    func testBasicEncryption() async throws {
        let keyStore = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(keyStore: keyStore)
        
        let command = PaymentCommand(
            cardNumber: "1234-5678-9012-3456",
            cvv: "123",
            amount: 99.99
        )
        
        let encrypted = try await encryptor.encrypt(command)
        
        XCTAssertEqual(encrypted.algorithm, "AES-GCM-256")
        XCTAssertFalse(encrypted.keyIdentifier.isEmpty)
        XCTAssertFalse(encrypted.encryptedData.isEmpty)
        
        // Ensure sensitive data is not in plain text
        let encryptedString = String(data: encrypted.encryptedData, encoding: .utf8) ?? ""
        XCTAssertFalse(encryptedString.contains("1234-5678-9012-3456"))
        XCTAssertFalse(encryptedString.contains("123"))
    }
    
    func testEncryptionDecryption() async throws {
        let keyStore = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(keyStore: keyStore)
        
        let originalCommand = PaymentCommand(
            cardNumber: "1234-5678-9012-3456",
            cvv: "123",
            amount: 99.99
        )
        
        let encrypted = try await encryptor.encrypt(originalCommand)
        let decrypted = try await encryptor.decrypt(encrypted)
        
        XCTAssertEqual(decrypted.cardNumber, originalCommand.cardNumber)
        XCTAssertEqual(decrypted.cvv, originalCommand.cvv)
        XCTAssertEqual(decrypted.amount, originalCommand.amount)
    }
    
    func testMultipleCommandTypes() async throws {
        let keyStore = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(keyStore: keyStore)
        
        // Test PaymentCommand
        let paymentCommand = PaymentCommand(
            cardNumber: "1234-5678-9012-3456",
            cvv: "123",
            amount: 99.99
        )
        
        let encryptedPayment = try await encryptor.encrypt(paymentCommand)
        let decryptedPayment = try await encryptor.decrypt(encryptedPayment)
        
        XCTAssertEqual(decryptedPayment.cardNumber, paymentCommand.cardNumber)
        
        // Test UserCommand
        let userCommand = UserCommand(
            ssn: "123-45-6789",
            password: "secret123",
            username: "john.doe"
        )
        
        let encryptedUser = try await encryptor.encrypt(userCommand)
        let decryptedUser = try await encryptor.decrypt(encryptedUser)
        
        XCTAssertEqual(decryptedUser.ssn, userCommand.ssn)
        XCTAssertEqual(decryptedUser.password, userCommand.password)
        XCTAssertEqual(decryptedUser.username, userCommand.username)
    }
    
    // MARK: - Key Management Tests
    
    func testKeyRotation() async throws {
        let keyStore = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(
            keyStore: keyStore,
            keyRotationInterval: 0.1 // Rotate after 0.1 seconds
        )
        
        let command1 = PaymentCommand(
            cardNumber: "1111-2222-3333-4444",
            cvv: "111",
            amount: 50.0
        )
        
        let encrypted1 = try await encryptor.encrypt(command1)
        let keyId1 = encrypted1.keyIdentifier
        
        // Wait for rotation (key rotation interval is 0.1 seconds)
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        
        let command2 = PaymentCommand(
            cardNumber: "5555-6666-7777-8888",
            cvv: "222",
            amount: 75.0
        )
        
        let encrypted2 = try await encryptor.encrypt(command2)
        let keyId2 = encrypted2.keyIdentifier
        
        // Different keys should be used
        XCTAssertNotEqual(keyId1, keyId2)
        
        // Both should still decrypt correctly
        let decrypted1 = try await encryptor.decrypt(encrypted1)
        let decrypted2 = try await encryptor.decrypt(encrypted2)
        
        XCTAssertEqual(decrypted1.cardNumber, command1.cardNumber)
        XCTAssertEqual(decrypted2.cardNumber, command2.cardNumber)
    }
    
    func testManualKeyRotation() async throws {
        let keyStore = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(keyStore: keyStore)
        
        let command = PaymentCommand(
            cardNumber: "1234-5678-9012-3456",
            cvv: "123",
            amount: 99.99
        )
        
        let encrypted1 = try await encryptor.encrypt(command)
        
        // Manually rotate key
        await encryptor.rotateKey()
        
        let encrypted2 = try await encryptor.encrypt(command)
        
        // Different keys should be used
        XCTAssertNotEqual(encrypted1.keyIdentifier, encrypted2.keyIdentifier)
        
        // Both should decrypt correctly
        let decrypted1 = try await encryptor.decrypt(encrypted1)
        let decrypted2 = try await encryptor.decrypt(encrypted2)
        
        XCTAssertEqual(decrypted1.cardNumber, command.cardNumber)
        XCTAssertEqual(decrypted2.cardNumber, command.cardNumber)
    }
    
    // MARK: - Key Store Tests
    
    func testInMemoryKeyStore() async {
        let store = InMemoryKeyStore()
        
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        
        await store.store(key: key1, identifier: "key1")
        let currentId1 = await store.currentKeyIdentifier
        XCTAssertEqual(currentId1, "key1")
        let currentKey1 = await store.currentKey
        XCTAssertNotNil(currentKey1)
        
        await store.store(key: key2, identifier: "key2")
        let currentId2 = await store.currentKeyIdentifier
        XCTAssertEqual(currentId2, "key2")
        
        // Both keys should be retrievable
        let retrievedKey1 = await store.key(for: "key1")
        XCTAssertNotNil(retrievedKey1)
        let retrievedKey2 = await store.key(for: "key2")
        XCTAssertNotNil(retrievedKey2)
        
        // Non-existent key
        let nonExistentKey = await store.key(for: "key3")
        XCTAssertNil(nonExistentKey)
    }
    
    func testKeyStoreExpiration() async {
        let store = InMemoryKeyStore()
        
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let key3 = SymmetricKey(size: .bits256)
        
        await store.store(key: key1, identifier: "key1")
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await store.store(key: key2, identifier: "key2")
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await store.store(key: key3, identifier: "key3") // Current key
        
        // Remove keys older than 40ms
        // At this point: key1 is ~100ms old, key2 is ~50ms old, key3 is ~0ms old
        let cutoff = Date().addingTimeInterval(-0.04)
        await store.removeExpiredKeys(before: cutoff)
        
        // key1 and key2 should be removed, key3 should remain
        let key1Retrieved = await store.key(for: "key1")
        XCTAssertNil(key1Retrieved)
        let key2Retrieved = await store.key(for: "key2")
        XCTAssertNil(key2Retrieved)
        let key3Retrieved = await store.key(for: "key3")
        XCTAssertNotNil(key3Retrieved)
        let currentId = await store.currentKeyIdentifier
        XCTAssertEqual(currentId, "key3")
    }
    
    // MARK: - Error Handling Tests
    
    func testDecryptionWithWrongKey() async throws {
        let keyStore1 = InMemoryKeyStore()
        let encryptor1 = await CommandEncryptor(keyStore: keyStore1)
        
        let keyStore2 = InMemoryKeyStore()
        let encryptor2 = await CommandEncryptor(keyStore: keyStore2)
        
        let command = PaymentCommand(
            cardNumber: "1234-5678-9012-3456",
            cvv: "123",
            amount: 99.99
        )
        
        let encrypted = try await encryptor1.encrypt(command)
        
        // Try to decrypt with different encryptor (different key)
        do {
            _ = try await encryptor2.decrypt(encrypted)
            XCTFail("Expected decryption to fail")
        } catch let error as PipelineError {
            if case .encryption(let reason) = error,
               case .keyNotFound = reason {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    // MARK: - Security Tests
    
    func testMaskedField() {
        let field1 = MaskedField(length: 4)
        XCTAssertEqual(field1.description, "****")
        
        let field2 = MaskedField(length: 10)
        XCTAssertEqual(field2.description, "********") // Max 8
        
        let field3 = MaskedField(length: 0)
        XCTAssertEqual(field3.description, "")
    }
    
    func testEncryptionStrength() async throws {
        let keyStore = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(keyStore: keyStore)
        
        let command = PaymentCommand(
            cardNumber: "1234-5678-9012-3456",
            cvv: "123",
            amount: 99.99
        )
        
        // Encrypt the same command multiple times
        let encrypted1 = try await encryptor.encrypt(command)
        let encrypted2 = try await encryptor.encrypt(command)
        
        // Encrypted data should be different due to random nonce
        XCTAssertNotEqual(encrypted1.encryptedData, encrypted2.encryptedData)
        
        // But both should decrypt to the same values
        let decrypted1 = try await encryptor.decrypt(encrypted1)
        let decrypted2 = try await encryptor.decrypt(encrypted2)
        
        XCTAssertEqual(decrypted1.cardNumber, decrypted2.cardNumber)
        XCTAssertEqual(decrypted1.cvv, decrypted2.cvv)
    }
}
