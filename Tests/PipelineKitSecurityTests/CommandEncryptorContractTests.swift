import Foundation
import XCTest
import PipelineKit
import PipelineKitSecurity
import PipelineKitTestSupport
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class CommandEncryptorContractTests: XCTestCase {
    func testEnvelopeContainsOnlyCiphertextAndMetadata() async throws {
        let encryptor = await CommandEncryptor(keyStore: InMemoryKeyStore())
        var command: ReferenceCommand? = ReferenceCommand(payload: fixtureCommand())
        let original = WeakCommandReference(value: command)
        let encrypted = try await encryptor.encrypt(try XCTUnwrap(command))
        command = nil

        XCTAssertNil(original.value, "The envelope and encryptor must not retain the command object")
        let fields = Array(Mirror(reflecting: encrypted).children)
        XCTAssertEqual(fields.compactMap(\.label).sorted(), ["algorithm", "encryptedData", "keyIdentifier"])
        XCTAssertEqual(fields.count, 3)
        for field in fields {
            switch field.label {
            case "encryptedData": XCTAssertTrue(field.value is Data)
            case "keyIdentifier", "algorithm": XCTAssertTrue(field.value is String)
            default: XCTFail("Unexpected retained envelope field")
            }
        }
        let reconstructed = try await encryptor.decrypt(encrypted)
        XCTAssertTrue(reconstructed.payload == fixtureCommand(), "Every command field must be reconstructed")
    }

    func testCodableCommandRoundTripReconstructsAllFields() async throws {
        let store = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(keyStore: store)
        let command = fixtureCommand()
        let encrypted = try await encryptor.encrypt(command)
        let restoredEnvelope = EncryptedCommand<CompleteCommand>(
            encryptedData: encrypted.encryptedData,
            keyIdentifier: encrypted.keyIdentifier,
            algorithm: encrypted.algorithm
        )
        let restored = try await encryptor.decrypt(restoredEnvelope)
        XCTAssertTrue(restored == command, "Complete Codable equality must survive envelope reconstruction")
        try await assertEnvelopeOpensUsingOwnIdentifier(restoredEnvelope, expected: command, store: store)
    }

    func testSharedStoreRotationPreservesCiphertextKeyIdentity() async throws {
        let store = InMemoryKeyStore()
        let first = await CommandEncryptor(keyStore: store)
        let beforeRotation = try await first.encrypt(fixtureCommand(sequence: 1))
        let second = await CommandEncryptor(keyStore: store)
        await second.rotateKey()
        let afterRotationFromFirst = try await first.encrypt(fixtureCommand(sequence: 2))
        let afterRotationFromSecond = try await second.encrypt(fixtureCommand(sequence: 3))
        XCTAssertEqual(beforeRotation.keyIdentifier, afterRotationFromFirst.keyIdentifier)
        XCTAssertNotEqual(beforeRotation.keyIdentifier, afterRotationFromSecond.keyIdentifier)

        for (envelope, sequence) in [(beforeRotation, 1), (afterRotationFromFirst, 2), (afterRotationFromSecond, 3)] {
            let expected = fixtureCommand(sequence: sequence)
            try await assertEnvelopeOpensUsingOwnIdentifier(envelope, expected: expected, store: store)
            let fromFirst = try await first.decrypt(envelope)
            let fromSecond = try await second.decrypt(envelope)
            XCTAssertTrue(fromFirst == expected, "First encryptor must reconstruct every field")
            XCTAssertTrue(fromSecond == expected, "Second encryptor must reconstruct every field")
        }
    }

    func testOverlappingSnapshotAndRotationKeepCapturedPairs() async throws {
        let store = GatedKeyStore()
        let first = await CommandEncryptor(keyStore: store)
        let before = try await first.encrypt(fixtureCommand(sequence: 1))
        let snapshotGate = SuspensionGate()
        await store.pauseNextSnapshot(at: snapshotGate)
        async let initializing = CommandEncryptor(keyStore: store)
        await snapshotGate.waitUntilEntered()

        let storeGate = SuspensionGate()
        await store.pauseNextStore(at: storeGate)
        async let rotating: Void = first.rotateKey()
        await storeGate.waitUntilEntered()

        // Capture errors until both child operations have been granted and joined.
        let duringRotation: Result<EncryptedCommand<CompleteCommand>, any Error>
        do {
            duringRotation = .success(try await first.encrypt(fixtureCommand(sequence: 2)))
        } catch {
            duringRotation = .failure(error)
        }
        await snapshotGate.grant()
        let second = await initializing
        let afterSnapshot: Result<EncryptedCommand<CompleteCommand>, any Error>
        do {
            afterSnapshot = .success(try await second.encrypt(fixtureCommand(sequence: 3)))
        } catch {
            afterSnapshot = .failure(error)
        }
        await storeGate.grant()
        await rotating
        let snapshotSettled = await snapshotGate.isSettled
        let storeSettled = await storeGate.isSettled
        XCTAssertTrue(snapshotSettled)
        XCTAssertTrue(storeSettled)

        let during = try duringRotation.get()
        let fromSecond = try afterSnapshot.get()
        let after = try await first.encrypt(fixtureCommand(sequence: 4))
        XCTAssertEqual(before.keyIdentifier, during.keyIdentifier)
        XCTAssertEqual(before.keyIdentifier, fromSecond.keyIdentifier)
        XCTAssertNotEqual(before.keyIdentifier, after.keyIdentifier)
        for (envelope, sequence) in [(before, 1), (during, 2), (fromSecond, 3), (after, 4)] {
            let expected = fixtureCommand(sequence: sequence)
            try await assertEnvelopeOpensUsingOwnIdentifier(envelope, expected: expected, store: store)
            let fromFirst = try await first.decrypt(envelope)
            let fromSecond = try await second.decrypt(envelope)
            XCTAssertTrue(fromFirst == expected)
            XCTAssertTrue(fromSecond == expected)
        }
    }

    func testOldKeysRemainUsableUntilExplicitlyExpired() async throws {
        let store = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(keyStore: store)
        let old = try await encryptor.encrypt(fixtureCommand())
        await encryptor.rotateKey()
        let current = try await encryptor.encrypt(fixtureCommand(sequence: 2))
        let beforeExpiry = try await encryptor.decrypt(old)
        XCTAssertTrue(beforeExpiry == fixtureCommand())
        await store.removeExpiredKeys(before: Date.distantFuture)
        do {
            _ = try await encryptor.decrypt(old)
            XCTFail("An expired key must fail instead of returning plaintext")
        } catch PipelineError.encryption(reason: .keyNotFound(let identifier)) {
            XCTAssertEqual(identifier, old.keyIdentifier)
        }
        let afterExpiry = try await encryptor.decrypt(current)
        XCTAssertTrue(afterExpiry == fixtureCommand(sequence: 2))
    }

    func testMissingKeyFailsWithoutPlaintextFallback() async throws {
        let writer = await CommandEncryptor(keyStore: InMemoryKeyStore())
        let reader = await CommandEncryptor(keyStore: InMemoryKeyStore())
        let encrypted = try await writer.encrypt(fixtureCommand())
        do {
            _ = try await reader.decrypt(encrypted)
            XCTFail("A missing key must fail")
        } catch PipelineError.encryption(reason: .keyNotFound(let identifier)) {
            XCTAssertEqual(identifier, encrypted.keyIdentifier)
        }
    }

    func testTamperedCiphertextPropagatesAuthenticationFailure() async throws {
        let encryptor = await CommandEncryptor(keyStore: InMemoryKeyStore())
        let encrypted = try await encryptor.encrypt(fixtureCommand())
        var tamperedData = encrypted.encryptedData
        tamperedData[tamperedData.index(before: tamperedData.endIndex)] ^= 0x01
        let tampered = EncryptedCommand<CompleteCommand>(
            encryptedData: tamperedData,
            keyIdentifier: encrypted.keyIdentifier,
            algorithm: encrypted.algorithm
        )
        do {
            _ = try await encryptor.decrypt(tampered)
            XCTFail("Tampering must fail authentication")
        } catch CryptoKitError.authenticationFailure {
            // Cryptographic authentication failure propagates unchanged.
        }
    }

    func testUnsupportedAlgorithmIsRejected() async throws {
        let encryptor = await CommandEncryptor(keyStore: InMemoryKeyStore())
        let encrypted = try await encryptor.encrypt(fixtureCommand())
        for algorithm in ["", "AES-GCM-128", "aes-gcm-256", "unknown"] {
            let unsupported = EncryptedCommand<CompleteCommand>(
                encryptedData: encrypted.encryptedData,
                keyIdentifier: encrypted.keyIdentifier,
                algorithm: algorithm
            )
            do {
                _ = try await encryptor.decrypt(unsupported)
                XCTFail("Only the produced AES-GCM-256 format is accepted")
            } catch PipelineError.encryption(reason: .algorithmNotSupported(let rejected)) {
                XCTAssertEqual(rejected, algorithm)
            }
        }
    }

    func testNon256BitKeysAreRejectedForEncryptionAndDecryption() async throws {
        for size in [SymmetricKeySize.bits128, .bits192] {
            let store = InMemoryKeyStore()
            let key = SendableSymmetricKey(size: size)
            await store.store(key: key, identifier: "wrong-size")
            let encryptor = await CommandEncryptor(keyStore: store)
            do {
                _ = try await encryptor.encrypt(fixtureCommand())
                XCTFail("AES-GCM-256 requires a 256-bit encryption key")
            } catch PipelineError.encryption(reason: .invalidKey) {}

            let data = try JSONEncoder().encode(fixtureCommand())
            let sealed = try AES.GCM.seal(data, using: key.key)
            let encrypted = EncryptedCommand<CompleteCommand>(
                encryptedData: try XCTUnwrap(sealed.combined),
                keyIdentifier: "wrong-size",
                algorithm: "AES-GCM-256"
            )
            do {
                _ = try await encryptor.decrypt(encrypted)
                XCTFail("AES-GCM-256 requires a 256-bit decryption key")
            } catch PipelineError.encryption(reason: .invalidKey) {}
        }
    }

    func testAuthenticatedIncompletePayloadFailsDecoding() async throws {
        let store = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(keyStore: store)
        let current = await store.currentKeySnapshot
        let snapshot = try XCTUnwrap(current)
        let sealed = try AES.GCM.seal(Data("{}".utf8), using: snapshot.key.key)
        let legacyPayload = EncryptedCommand<CompleteCommand>(
            encryptedData: try XCTUnwrap(sealed.combined),
            keyIdentifier: snapshot.identifier,
            algorithm: "AES-GCM-256"
        )
        do {
            _ = try await encryptor.decrypt(legacyPayload)
            XCTFail("Incomplete authenticated JSON must not fabricate a command")
        } catch DecodingError.keyNotFound {}
    }

    func testEncodingFailurePropagates() async throws {
        let encryptor = await CommandEncryptor(keyStore: InMemoryKeyStore())
        do {
            _ = try await encryptor.encrypt(EncodingFailureCommand())
            XCTFail("Encoding failure must propagate")
        } catch FixtureError.encoding {}
    }

    private func assertEnvelopeOpensUsingOwnIdentifier(
        _ envelope: EncryptedCommand<CompleteCommand>,
        expected: CompleteCommand,
        store: any KeyStore
    ) async throws {
        let found = await store.key(for: envelope.keyIdentifier)
        let key = try XCTUnwrap(found)
        let sealed = try AES.GCM.SealedBox(combined: envelope.encryptedData)
        let data = try AES.GCM.open(sealed, using: key.key)
        let decoded = try JSONDecoder().decode(CompleteCommand.self, from: data)
        XCTAssertTrue(decoded == expected, "The envelope's own key identifier must open every encoded field")
    }
}

private struct CompleteCommand: Command, Codable, Equatable {
    typealias Result = Void
    struct Details: Codable, Equatable {
        let secret: String
        let tags: [String]
    }
    let identifier: UUID
    let sequence: Int
    let details: Details
    let optionalValue: String?
    let absentValue: String?
    let bytes: Data
    let flags: [String: Bool]
}

private func fixtureCommand(sequence: Int = 7) -> CompleteCommand {
    CompleteCommand(
        identifier: UUID(uuidString: "FCD8D80C-382C-4EBE-8DAC-5F2DD7AF3B09")!,
        sequence: sequence,
        details: .init(secret: "synthetic-private-value", tags: ["alpha", "βeta"]),
        optionalValue: "synthetic-nested-value",
        absentValue: nil,
        bytes: Data([0, 1, 127, 255]),
        flags: ["enabled": true, "preview": false]
    )
}

private final class ReferenceCommand: Command, Codable {
    typealias Result = Void
    let payload: CompleteCommand
    init(payload: CompleteCommand) { self.payload = payload }
}

private struct WeakCommandReference {
    weak var value: ReferenceCommand?
}

private enum FixtureError: Error { case encoding }
private struct EncodingFailureCommand: Command, Codable {
    typealias Result = Void
    func encode(to encoder: any Encoder) throws { throw FixtureError.encoding }
}

/// One-use acknowledgement gate; the test grants every entered operation before joining it.
private actor SuspensionGate {
    private var entered = false
    private var granted = false
    private var settled = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var grantWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if !granted {
            await withCheckedContinuation { grantWaiter = $0 }
        }
        settled = true
    }

    func waitUntilEntered() async {
        if !entered {
            await withCheckedContinuation { entryWaiters.append($0) }
        }
    }

    func grant() {
        granted = true
        grantWaiter?.resume()
        grantWaiter = nil
    }

    var isSettled: Bool { entered && granted && settled }
}

/// Gates completion after the real store has captured or published its atomic snapshot.
private actor GatedKeyStore: KeyStore {
    private let backing = InMemoryKeyStore()
    private var snapshotGate: SuspensionGate?
    private var storeGate: SuspensionGate?

    func pauseNextSnapshot(at gate: SuspensionGate) { snapshotGate = gate }
    func pauseNextStore(at gate: SuspensionGate) { storeGate = gate }

    var currentKeySnapshot: EncryptionKeySnapshot? {
        get async {
            let gate = snapshotGate
            snapshotGate = nil
            let snapshot = await backing.currentKeySnapshot
            if let gate { await gate.enterAndWait() }
            return snapshot
        }
    }

    func store(key: SendableSymmetricKey, identifier: String) async {
        let gate = storeGate
        storeGate = nil
        await backing.store(key: key, identifier: identifier)
        if let gate { await gate.enterAndWait() }
    }

    func key(for identifier: String) async -> SendableSymmetricKey? {
        await backing.key(for: identifier)
    }

    func removeExpiredKeys(before date: Date) async {
        await backing.removeExpiredKeys(before: date)
    }
}
