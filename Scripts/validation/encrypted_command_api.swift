import Foundation
import PipelineKit
import PipelineKitSecurity

struct ProbeCommand: Command, Codable {
    typealias Result = Void
    let number: Int
}

func recover(
    _ envelope: EncryptedCommand<ProbeCommand>,
    using encryptor: CommandEncryptor
) async throws -> ProbeCommand {
#if REJECT_ORIGINAL_COMMAND
    return envelope.originalCommand
#else
    return try await encryptor.decrypt(envelope)
#endif
}
