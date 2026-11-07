import Foundation
import CryptoKit
import PipelineKit
import PipelineKitCore
import PipelineKitSecurity

// Every stored field is encoded, encrypted, authenticated and reconstructed.
struct CreateUserCommand: Command, Codable, Equatable {
    typealias Result = String
    let username: String
    let email: String
    let password: String
    let age: Int
    let isActive: Bool
    let joinDate: Date
    let metadata: [String: String]
}

// Ephemeral demonstration storage. An application must choose its key persistence
// and expiration policy; this example keeps keys only for this process.
private actor ExampleKeyStore: KeyStore {
    private var keys: [String: SendableSymmetricKey] = [:]
    private var dates: [String: Date] = [:]
    private(set) var currentKeySnapshot: EncryptionKeySnapshot?

    func key(for identifier: String) -> SendableSymmetricKey? { keys[identifier] }

    func store(key: SendableSymmetricKey, identifier: String) {
        keys[identifier] = key
        dates[identifier] = Date()
        currentKeySnapshot = EncryptionKeySnapshot(key: key, identifier: identifier)
    }

    func removeExpiredKeys(before date: Date) {
        for (identifier, created) in dates where created < date && identifier != currentKeySnapshot?.identifier {
            keys.removeValue(forKey: identifier)
            dates.removeValue(forKey: identifier)
        }
    }
}

@main
enum TypeSafeEncryptionExample {
    static func main() async throws {
        let keyStore = ExampleKeyStore()
        let encryptor = await CommandEncryptor(keyStore: keyStore)
        let command = CreateUserCommand(
            username: "synthetic_user",
            email: "synthetic@example.invalid",
            password: "synthetic-example-only",
            age: 30,
            isActive: true,
            joinDate: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ["team": "example", "purpose": "roundtrip"]
        )
        let encrypted = try await encryptor.encrypt(command)
        guard encrypted.algorithm == "AES-GCM-256", !encrypted.encryptedData.isEmpty else {
            throw ExampleFailure.invalidEnvelope
        }
        // A second encryptor uses the key store and ciphertext, not the original command.
        let reader = await CommandEncryptor(keyStore: keyStore)
        let restored: CreateUserCommand = try await reader.decrypt(encrypted)
        guard restored == command else { throw ExampleFailure.incorrectReconstruction }

        var corrupted = encrypted.encryptedData
        // Flip a byte in the authentication tag while preserving the envelope format.
        corrupted[corrupted.count - 1] ^= 1
        let tampered = EncryptedCommand<CreateUserCommand>(
            encryptedData: corrupted,
            keyIdentifier: encrypted.keyIdentifier,
            algorithm: encrypted.algorithm
        )
        var authenticationRejected = false
        do {
            _ = try await reader.decrypt(tampered)
        } catch CryptoKitError.authenticationFailure {
            authenticationRejected = true
        }
        guard authenticationRejected else { throw ExampleFailure.tamperingAccepted }
        print("Verified complete Codable command reconstruction and AES-GCM tamper rejection.")
        print("This is a current-format round trip; it does not migrate legacy ciphertext.")
        print("PASS: TypeSafeEncryptionExample")
    }
}

enum ExampleFailure: Error { case invalidEnvelope, incorrectReconstruction, tamperingAccepted }
