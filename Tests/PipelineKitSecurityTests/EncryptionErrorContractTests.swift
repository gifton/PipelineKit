import Foundation
import XCTest
import PipelineKit
import PipelineKitSecurity

final class EncryptionErrorContractTests: XCTestCase {
    func testEncryptionFailureUsesPipelineEncryptionCase() async {
        let middleware = EncryptionMiddleware(encryptionService: FailingService(error: FixtureError.failed))
        let context = CommandContext()
        do {
            _ = try await middleware.execute(WriteCommand(), context: context) { _, _ in
                XCTFail("Failed encryption must prevent handler entry")
                return ()
            }
            XCTFail("Expected encryption failure")
        } catch PipelineError.encryption(reason: .encryptionFailed(let reason)) {
            XCTAssertTrue(reason.contains("secret"))
            XCTAssertEqual(context.getMetadata()["encryption.failed"] as? Bool, true)
        } catch {
            XCTFail("Expected typed pipeline encryption failure, got \(error)")
        }
    }

    func testDecryptionFailureUsesPipelineEncryptionCase() async {
        do {
            _ = try await read(service: FailingService(error: FixtureError.failed), partial: false)
            XCTFail("Expected decryption failure")
        } catch PipelineError.encryption(reason: .decryptionFailed(let reason)) {
            XCTAssertTrue(reason.contains("secret"))
        } catch {
            XCTFail("Expected typed pipeline decryption failure, got \(error)")
        }
    }

    func testMissingSerializedCapabilityUsesPipelineEncryptionCase() async {
        do {
            _ = try await read(service: FailingService(error: FixtureError.failed), partial: false, hint: nil)
            XCTFail("Expected missing capability rejection")
        } catch PipelineError.encryption(reason: .decryptionFailed(let reason)) {
            XCTAssertTrue(reason.contains("SerializedPlaintextDecrypting"))
        } catch {
            XCTFail("Expected typed pipeline decryption failure, got \(error)")
        }
    }

    func testEncryptionCancellationIsNotReclassifiedAsEncryptionFailure() async {
        for error in [CancellationError(), PipelineError.cancelled(context: "service cancelled")] as [any Error] {
            let context = CommandContext()
            let middleware = EncryptionMiddleware(encryptionService: FailingService(error: error))
            do {
                _ = try await middleware.execute(WriteCommand(), context: context) { _, _ in
                    XCTFail("Cancelled encryption must prevent handler entry")
                    return ()
                }
                XCTFail("Expected cancellation")
            } catch PipelineError.cancelled {
                XCTAssertNil(context.getMetadata()["encryption.failed"])
            } catch {
                XCTFail("Expected pipeline cancellation, got \(error)")
            }
        }
    }

    func testDecryptionCancellationCannotBecomePartialSuccess() async {
        for partial in [false, true] {
            for error in [CancellationError(), PipelineError.cancelled(context: "service cancelled")] as [any Error] {
                let context = CommandContext()
                do {
                    _ = try await read(service: FailingService(error: error), partial: partial, context: context)
                    XCTFail("Cancellation must terminate decryption, including partial mode")
                } catch PipelineError.cancelled {
                    XCTAssertNil(context.getMetadata()["decryption.failed.secret"])
                    XCTAssertNil(context.getMetadata()["encryption.decrypted"])
                } catch {
                    XCTFail("Expected pipeline cancellation, got \(error)")
                }
            }
        }
    }

    func testHandlerErrorsAreNotReclassifiedAsEncryptionFailures() async {
        let middleware = EncryptionMiddleware(encryptionService: FailingService(error: FixtureError.failed))
        do {
            _ = try await middleware.execute(ReadCommand(), context: CommandContext()) { _, _ -> ReadResult in
                throw EncryptionError.keyNotFound("handler-owned")
            }
            XCTFail("Expected handler error")
        } catch EncryptionError.keyNotFound(let key) {
            XCTAssertEqual(key, "handler-owned")
        } catch {
            XCTFail("Handler errors must retain their identity, got \(error)")
        }
    }
}

private extension EncryptionErrorContractTests {
    enum FixtureError: Error { case failed }

    struct FailingService: EncryptionService {
        let error: any Error
        func encrypt<T: Encodable>(_ value: T) async throws -> EncryptedData { throw error }
        func decrypt<T: Decodable>(_ data: EncryptedData, as type: T.Type) async throws -> T { throw error }
        func validate() async throws { }
    }

    struct WriteCommand: EncryptableCommand {
        typealias Result = Void
        var sensitiveData: [String: any Encodable] { ["secret": "fixture"] }
        func withEncryptedData(_ encryptedData: [String: EncryptedData]) -> Self { self }
    }

    struct ReadCommand: Command { typealias Result = ReadResult }

    struct ReadResult: DecryptableResult, Sendable {
        let encryptedData: [String: EncryptedData]?
        func withDecryptedData(_ decryptedData: [String: DecryptedValue]) -> Self { Self(encryptedData: nil) }
    }

    func read(
        service: any EncryptionService, partial: Bool, hint: String? = "String",
        context: CommandContext = CommandContext()
    ) async throws -> ReadResult {
        let middleware = EncryptionMiddleware(encryptionService: service, allowPartialDecryption: partial)
        let data = EncryptedData(ciphertext: Data([1]), nonce: Data([2]), typeHint: hint)
        return try await middleware.execute(ReadCommand(), context: context) { _, _ in
            ReadResult(encryptedData: ["secret": data])
        }
    }
}
