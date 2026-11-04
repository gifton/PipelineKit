import Foundation
import XCTest
#if canImport(CryptoKit)
@preconcurrency import CryptoKit
#else
@preconcurrency import Crypto
#endif
import PipelineKit
@testable import PipelineKitSecurity

final class EncryptedResultSerializationTests: XCTestCase {
    func testCustomObjectHintPreservesJSONForExplicitResultDecoding() async throws {
        let service = StandardEncryptionService()
        let value = Record(name: "private", scores: [3, 7])
        let encrypted = try await service.encrypt(value)
        let result = try await execute(["record": replacingHint(encrypted, with: "Record")], service: service)
        let data = try XCTUnwrap(result.values["record"]?.get(as: TypedData.self))
        XCTAssertEqual(data.originalType, "Record")
        XCTAssertEqual(try data.decode(as: Record.self), value)
    }

    func testCustomArrayHintPreservesJSONForExplicitResultDecoding() async throws {
        let service = StandardEncryptionService()
        let value = [Record(name: "first", scores: []), Record(name: "second", scores: [2])]
        let encrypted = try await service.encrypt(value)
        let result = try await execute(["records": replacingHint(encrypted, with: "Array<Record>")], service: service)
        let data = try XCTUnwrap(result.values["records"]?.get(as: TypedData.self))
        XCTAssertEqual(try data.decode(as: [Record].self), value)
    }

    func testMissingTypeHintReturnsSerializedObjectAndArrayBytes() async throws {
        let service = StandardEncryptionService()
        let value = Record(name: "private", scores: [3, 7])
        let object = try await service.encrypt(value)
        let array = try await service.encrypt([value])
        let result = try await execute([
            "object": replacingHint(object, with: nil),
            "array": replacingHint(array, with: nil)
        ], service: service)
        let objectBytes = try XCTUnwrap(result.values["object"]?.get(as: Data.self))
        let arrayBytes = try XCTUnwrap(result.values["array"]?.get(as: Data.self))
        XCTAssertEqual(try JSONDecoder().decode(Record.self, from: objectBytes), value)
        XCTAssertEqual(try JSONDecoder().decode([Record].self, from: arrayBytes), [value])
    }

    func testKnownTypeHintsPreservePrimitiveAndDataValues() async throws {
        let service = StandardEncryptionService()
        let fields: [String: EncryptedData] = [
            "string": replacingHint(try await service.encrypt("secret"), with: "String"),
            "integer": replacingHint(try await service.encrypt(42), with: "Int"),
            "double": replacingHint(try await service.encrypt(1.25), with: "Double"),
            "bool": replacingHint(try await service.encrypt(true), with: "Bool"),
            "date": replacingHint(try await service.encrypt(Date(timeIntervalSinceReferenceDate: 100)), with: "Date"),
            "data": replacingHint(try await service.encrypt(Data([0, 255, 17])), with: "Data")
        ]
        let result = try await execute(fields, service: service)
        XCTAssertEqual(result.values["string"]?.get(as: String.self), "secret")
        XCTAssertEqual(result.values["integer"]?.get(as: Int.self), 42)
        XCTAssertEqual(try XCTUnwrap(result.values["double"]?.get(as: Double.self)), 1.25, accuracy: 0.000001)
        XCTAssertEqual(result.values["bool"]?.get(as: Bool.self), true)
        XCTAssertEqual(result.values["date"]?.get(as: Date.self), Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(result.values["data"]?.get(as: Data.self), Data([0, 255, 17]))
    }

    func testPartialDecryptionReportsOnlyTamperedField() async throws {
        let service = StandardEncryptionService()
        let value = Record(name: "valid", scores: [1])
        let good = replacingHint(try await service.encrypt(value), with: "Record")
        var corrupted = good.ciphertext
        corrupted[corrupted.startIndex] ^= 1
        let bad = EncryptedData(ciphertext: corrupted, nonce: good.nonce, tag: good.tag, typeHint: "Record")
        let context = CommandContext()
        let result = try await execute(["good": good, "bad": bad], service: service, partial: true, context: context)
        let data = try XCTUnwrap(result.values["good"]?.get(as: TypedData.self))
        XCTAssertEqual(try data.decode(as: Record.self), value)
        XCTAssertNil(result.values["bad"])
        XCTAssertEqual(context.getMetadata()["decryption.failedFields"] as? [String], ["bad"])
        XCTAssertEqual(context.getMetadata()["decryption.failedCount"] as? Int, 1)
        XCTAssertEqual(context.getMetadata()["decryption.fieldCount"] as? Int, 1)
        XCTAssertNil(context.getMetadata()["decryption.failed.good"])
    }

    func testCustomAndMissingHintsPreserveExactAuthenticatedBytes() async throws {
        let key = SymmetricKey(size: .bits256)
        let service = StandardEncryptionService(key: key)
        let plaintext = Data(#" { "scores" : [3, 7], "name" : "pr\u0069vate" } "#.utf8)
        for hint in ["Unregistered.Type<Name>", nil] as [String?] {
            let encrypted = try seal(plaintext, using: key, hint: hint)
            let result = try await execute(["value": encrypted], service: service)
            let bytes: Data
            if let hint {
                let typed = try XCTUnwrap(result.values["value"]?.get(as: TypedData.self))
                XCTAssertEqual(typed.originalType, hint)
                bytes = typed.data
                XCTAssertEqual(try typed.decode(as: Record.self), Record(name: "private", scores: [3, 7]))
            } else {
                bytes = try XCTUnwrap(result.values["value"]?.get(as: Data.self))
            }
            XCTAssertEqual(bytes, plaintext, "Whitespace and escape spelling must survive authentication unchanged")
        }
    }

    func testMissingHintDistinguishesSerializedDataAndStringFromDecodedValues() async throws {
        let service = StandardEncryptionService()
        let blob = replacingHint(try await service.encrypt(Data([0, 255, 17])), with: nil)
        let string = replacingHint(try await service.encrypt("secret"), with: nil)
        let result = try await execute(["blob": blob, "string": string], service: service)
        XCTAssertEqual(result.values["blob"]?.get(as: Data.self), Data(#""AP8R""#.utf8))
        XCTAssertEqual(result.values["string"]?.get(as: Data.self), Data(#""secret""#.utf8))
    }

    func testUnknownNonJSONEncodingReturnsRawBytesWithoutDecoding() async throws {
        let key = SymmetricKey(size: .bits256)
        let service = StandardEncryptionService(key: key)
        let plaintext = Data([0, 255, 17, 32])
        let encrypted = try seal(plaintext, using: key, hint: "BinaryRecord", format: "custom-binary")
        let result = try await execute(["value": encrypted], service: service)
        XCTAssertEqual(result.values["value"]?.get(as: Data.self), plaintext)
    }

    func testNewStandardEnvelopesPreserveTypedPrimitiveAndDataResults() async throws {
        let service = StandardEncryptionService()
        let result = try await execute([
            "string": try await service.encrypt("secret"),
            "blob": try await service.encrypt(Data([0, 255, 17]))
        ], service: service)
        XCTAssertEqual(result.values["string"]?.get(as: String.self), "secret")
        XCTAssertEqual(result.values["blob"]?.get(as: Data.self), Data([0, 255, 17]))
    }

    func testLegacyServiceKeepsTypedFieldsAndReportsUnsupportedSerializedFields() async throws {
        let service = LegacyTypedService()
        let encrypted = try await service.encrypt(Data([0, 255, 17]))
        for hint in ["CustomBlob", nil] as [String?] {
            let context = CommandContext()
            let result = try await execute([
                "supported": replacingHint(encrypted, with: "Data"),
                "unsupported": replacingHint(encrypted, with: hint)
            ], service: service, partial: true, context: context)
            XCTAssertEqual(result.values["supported"]?.get(as: Data.self), Data([0, 255, 17]))
            XCTAssertNil(result.values["unsupported"])
            XCTAssertEqual(context.getMetadata()["decryption.failedFields"] as? [String], ["unsupported"])
            XCTAssertEqual(context.getMetadata()["decryption.fieldCount"] as? Int, 1)
            XCTAssertEqual(context.getMetadata()["decryption.failedCount"] as? Int, 1)
            let reason = try XCTUnwrap(context.getMetadata()["decryption.error.unsupported"] as? String)
            XCTAssertTrue(reason.contains("serialized plaintext"), reason)
        }
    }

    func testLegacyServiceRejectsUnsupportedSerializedFieldWithoutPartialMode() async throws {
        let service = LegacyTypedService()
        let encrypted = replacingHint(try await service.encrypt(Data([0, 255, 17])), with: "CustomBlob")
        do {
            _ = try await execute(["unsupported": encrypted], service: service)
            XCTFail("Legacy services must opt in before being asked for serialized plaintext")
        } catch EncryptionError.decryptionFailed(let reason) {
            XCTAssertTrue(reason.contains("serialized plaintext"), reason)
        }
    }

    func testAuthenticationFailuresNeverAppearInPartialResult() async throws {
        let key = SymmetricKey(size: .bits256)
        let service = StandardEncryptionService(key: key)
        let bytes = Data(#"{"name":"valid","scores":[]}"#.utf8)
        let valid = try seal(bytes, using: key, hint: "Record")
        var ciphertext = valid.ciphertext
        ciphertext[ciphertext.startIndex] ^= 1
        var nonce = valid.nonce
        nonce[nonce.startIndex] ^= 1
        var tag = try XCTUnwrap(valid.tag)
        tag[tag.startIndex] ^= 1
        let failures: [String: EncryptedData] = [
            "ciphertext": EncryptedData(ciphertext: ciphertext, nonce: valid.nonce, tag: valid.tag, typeHint: "Record"),
            "nonce": EncryptedData(ciphertext: valid.ciphertext, nonce: nonce, tag: valid.tag, typeHint: "Record"),
            "tag": EncryptedData(ciphertext: valid.ciphertext, nonce: valid.nonce, tag: tag, typeHint: "Record"),
            "missingTag": EncryptedData(ciphertext: valid.ciphertext, nonce: valid.nonce, typeHint: "Record"),
            "invalidNonce": EncryptedData(ciphertext: valid.ciphertext, nonce: Data(), tag: valid.tag, typeHint: "Record"),
            "algorithm": EncryptedData(ciphertext: valid.ciphertext, nonce: valid.nonce, tag: valid.tag,
                                       algorithm: "unsupported", typeHint: "Record"),
            "wrongKey": try seal(bytes, using: SymmetricKey(size: .bits256), hint: "Record")
        ]
        let context = CommandContext()
        let result = try await execute(failures.merging(["valid": valid]) { lhs, _ in lhs },
                                       service: service, partial: true, context: context)
        XCTAssertEqual(Set(result.values.keys), ["valid"])
        XCTAssertEqual(result.values["valid"]?.get(as: TypedData.self)?.data, bytes)
        XCTAssertEqual((context.getMetadata()["decryption.failedFields"] as? [String])?.sorted(), failures.keys.sorted())
        XCTAssertEqual(context.getMetadata()["decryption.failedCount"] as? Int, failures.count)
        XCTAssertEqual(context.getMetadata()["decryption.fieldCount"] as? Int, 1)
    }

    func testTamperedCustomFieldRejectsWithoutPartialMode() async throws {
        let service = StandardEncryptionService()
        let encrypted = replacingHint(try await service.encrypt(Record(name: "secret", scores: [])), with: "Record")
        var corrupted = encrypted.ciphertext
        corrupted[corrupted.startIndex] ^= 1
        let bad = EncryptedData(ciphertext: corrupted, nonce: encrypted.nonce, tag: encrypted.tag, typeHint: "Record")
        let context = CommandContext()
        do {
            _ = try await execute(["bad": bad], service: service, context: context)
            XCTFail("Authentication failure must reject the result")
        } catch EncryptionError.decryptionFailed {
            XCTAssertEqual(context.getMetadata()["decryption.failed.bad"] as? Bool, true)
            XCTAssertNil(context.getMetadata()["encryption.decrypted"])
        }
    }

}

private extension EncryptedResultSerializationTests {
    struct LegacyTypedService: EncryptionService {
        let base = StandardEncryptionService()

        func encrypt<T: Encodable>(_ value: T) async throws -> EncryptedData {
            try await base.encrypt(value)
        }

        func decrypt<T: Decodable>(_ data: EncryptedData, as type: T.Type) async throws -> T {
            try await base.decrypt(data, as: type)
        }

        func validate() async throws {
            try await base.validate()
        }
    }

    struct Record: Codable, Equatable, Sendable {
        let name: String
        let scores: [Int]
    }

    struct Result: DecryptableResult, Sendable {
        let encryptedData: [String: EncryptedData]?
        var values: [String: DecryptedValue] = [:]

        func withDecryptedData(_ decryptedData: [String: DecryptedValue]) -> Self {
            Self(encryptedData: nil, values: decryptedData)
        }
    }

    struct ReadCommand: Command {
        typealias Result = EncryptedResultSerializationTests.Result
    }

    func execute(
        _ fields: [String: EncryptedData], service: any EncryptionService,
        partial: Bool = false, context: CommandContext = CommandContext()
    ) async throws -> Result {
        let middleware = EncryptionMiddleware(encryptionService: service, allowPartialDecryption: partial)
        return try await middleware.execute(ReadCommand(), context: context) { _, _ in
            Result(encryptedData: fields)
        }
    }

    func seal(
        _ bytes: Data, using key: SymmetricKey, hint: String?, format: String = "json"
    ) throws -> EncryptedData {
        let box = try AES.GCM.seal(bytes, using: key)
        return EncryptedData(
            ciphertext: box.ciphertext, nonce: box.nonce.withUnsafeBytes { Data($0) },
            tag: box.tag, typeHint: hint, encodingFormat: format
        )
    }

    func replacingHint(_ data: EncryptedData, with hint: String?) -> EncryptedData {
        EncryptedData(
            ciphertext: data.ciphertext, nonce: data.nonce, tag: data.tag,
            algorithm: data.algorithm, encryptedAt: data.encryptedAt,
            typeHint: hint, encodingFormat: data.encodingFormat
        )
    }
}
