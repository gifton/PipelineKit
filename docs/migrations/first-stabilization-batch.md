# First stabilization batch migration — draft

This draft currently covers S01 validation/sanitization, S02 command encryption, and R02
bulkhead queue-timeout validation. I01
owns the completed batch migration guide, compilation of all examples, and the consolidated
Breaking entry. These snippets have not yet been compiled as standalone migration examples;
the task contract suites exercise their public APIs. Remaining batch migrations are pending.

## Breaking: explicit validation and sanitization capabilities

For the next minor release under [VERSIONING.md](../../VERSIONING.md), commands used with
`ValidationMiddleware()` must conform to `ValidatableCommand`, and commands used with
`SanitizationMiddleware()` must conform to `SanitizableCommand`. The default policy is
`.required`. Missing conformance throws `SecurityCapabilityError.missingValidation` or
`.missingSanitization` before the next stage runs.

The old extension-only hooks did not dispatch to command-specific implementations from a
generic pipeline. Move the implementation into an explicit conformance and use these
async signatures:

- `func validate() async throws`
- `func sanitize() async throws -> Self`

There are no no-op witnesses. `validateAsync()`, `sanitizeAsync()`, `requiresValidation`,
`requiresSanitization` and `hasSensitiveFields` have been removed. Update direct callers to
`try await command.validate()` or `let replacement = try await command.sanitize()`.
Validation and sanitization errors propagate unchanged. Sanitization middleware passes the
returned command downstream; immutable caller values remain unchanged.

```swift
import Foundation
import PipelineKit
import PipelineKitSecurity

enum PostInputError: Error { case emptyTitle }

struct CreatePostCommand: ValidatableCommand, SanitizableCommand {
    typealias Result = String
    let title: String

    func validate() async throws {
        guard !title.isEmpty else { throw PostInputError.emptyTitle }
    }

    func sanitize() async throws -> Self {
        Self(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct CreatePostHandler: CommandHandler {
    func handle(_ command: CreatePostCommand, context: CommandContext) async throws -> String {
        command.title
    }
}

func makePostPipeline() async throws -> StandardPipeline<CreatePostCommand, CreatePostHandler> {
    let builder = PipelineBuilder(handler: CreatePostHandler())
    // Equal effective priority retains insertion order: sanitize, then validate.
    await builder.with(SanitizationMiddleware(), order: .validation)
    await builder.with(ValidationMiddleware())
    return try await builder.build()
}
```

Intrinsic priorities still put validation (200) before sanitization (300). The explicit
order above makes validation inspect normalized input. Choose that ordering deliberately
for your command's contract. Sanitization is application-defined transformation, not a
universal injection defense.

For a pipeline that intentionally handles both capable and unrelated commands, opt out of
required conformance explicitly with `ValidationMiddleware(requirement: .ifPresent)` and/or
`SanitizationMiddleware(requirement: .ifPresent)`. Present capabilities still execute and
still propagate their errors. Avoid applying this opt-out to routes that require validation
or sanitization of every command.

`SecurityValidatable` remains the separate security-policy protocol; `EncryptableCommand`
remains the separate encryption-middleware protocol. Neither substitutes for the new
capabilities. The encryption-only `Command` extension hooks `sensitiveFields` and
`updateSensitiveFields` are also removed by S02; migrate encryptor callers as below.


## Breaking: ciphertext-only complete commands and atomic key snapshots

`CommandEncryptor.encrypt` and `decrypt` now require `T: Command & Codable`. Encode all
state required to reconstruct your command. The encryptor JSON-encodes the complete command,
seals it with AES-GCM-256, and reconstructs a new `T` by opening and decoding that payload.
It no longer calls the extension-only `sensitiveFields` or `updateSensitiveFields` hooks.

`EncryptedCommand<T>` contains only `encryptedData`, `keyIdentifier`, and `algorithm`.
`T` is a phantom type; no command, redacted shell, closure, or plaintext reference is retained.
Remove uses of `originalCommand` and replace the old initializer with the three-field one:

```swift
import Foundation
import PipelineKit
import PipelineKitSecurity

struct StoredCommand: Command, Codable {
    typealias Result = Void
    let accountIdentifier: String
    let payload: Data
}

func storeAndRestore(
    _ command: StoredCommand,
    using encryptor: CommandEncryptor
) async throws -> StoredCommand {
    let encrypted = try await encryptor.encrypt(command)
    // Persist or transmit these three fields; retain the expected command type separately.
    let restoredEnvelope = EncryptedCommand<StoredCommand>(
        encryptedData: encrypted.encryptedData,
        keyIdentifier: encrypted.keyIdentifier,
        algorithm: encrypted.algorithm
    )
    return try await encryptor.decrypt(restoredEnvelope)
}
```

Every `KeyStore` conformer must replace its separate `currentKey` and `currentKeyIdentifier`
requirements with `var currentKeySnapshot: EncryptionKeySnapshot? { get async }`. Capture the
key and identifier together under the store's isolation; never assemble a pair from independent
async reads. Keep key lookup, storage and expiration methods. For example, this in-memory
teaching store publishes a pair in the same actor turn as its key write:

```swift
import Foundation
import PipelineKitSecurity

actor ExampleVersionedKeyStore: KeyStore {
    private var keys: [String: SendableSymmetricKey] = [:]
    private var dates: [String: Date] = [:]
    private(set) var currentKeySnapshot: EncryptionKeySnapshot?

    func key(for identifier: String) -> SendableSymmetricKey? { keys[identifier] }

    func store(key: SendableSymmetricKey, identifier: String) {
        keys[identifier] = key
        dates[identifier] = Date()
        currentKeySnapshot = EncryptionKeySnapshot(key: key, identifier: identifier)
    }

    func removeExpiredKeys(before cutoff: Date) {
        for (identifier, date) in dates where date < cutoff && identifier != currentKeySnapshot?.identifier {
            keys.removeValue(forKey: identifier)
            dates.removeValue(forKey: identifier)
        }
    }
}
```

Use a fresh identifier for each stored key version and supply only 256-bit keys. Encryption
captures one immutable pair; another encryptor rotating the same store does not change the
identifier attached to an already captured key. Old keys remain available until the store
explicitly expires them. Missing or expired keys fail with `.keyNotFound`; a key of the wrong
size fails with `.invalidKey`. Decryption accepts only the exact `AES-GCM-256` algorithm label,
and cryptographic authentication and Codable failures propagate instead of returning a
retained original command.

The previous partial-field ciphertext format is incompatible with complete-command decoding.
Migrate before removing the old consumer or losing its original command objects: use that
consumer and its keys to recover the complete application command, then re-encrypt it through
the new Codable API. The old generic hooks could seal an empty JSON object, so old ciphertext
alone is not evidence that lost command fields can be recovered. Keep both the original
command data and required old keys until migration is verified; if either is already lost,
recovery may be impossible. Migration validation should record counts and pass/fail results,
never synthetic or real plaintext.

The separate `EncryptionMiddleware` / `EncryptableCommand` custom-result path is unchanged;
SCP-09 remains open. This change makes no key-memory zeroization promise.


## Breaking: bounded positive bulkhead queue timeouts

`BulkheadMiddleware.Configuration.queueTimeout` and
`PartitionedBulkheadMiddleware.PartitionConfig.queueTimeout` now accept `nil`, any finite
nonpositive value, or a finite positive value no greater than 86,400 seconds (24 hours). Middleware
initialization explicitly fails its configuration precondition for a larger positive value,
NaN or either infinity, including when the queue has `maxQueueSize: 0` or `queueSize: 0`. The 24-hour
cap is a deliberate PipelineKit policy, not Swift Duration's intrinsic range limit. It bounds
the TimeInterval conversion and leaves headroom for the default sleeper's immediate deadline
addition. I01 must include this behavior change in the next minor release's consolidated
**Breaking** entry.

Previously accepted configurations with a longer finite queue budget must revisit that
policy. Using `nil` plus application-managed cancellation is one option, but `nil` means an
unbounded admission wait: it does not preserve the old finite deadline. An admitted handler
continues to own its capacity until it settles; this change adds no hard handler deadline or
preemptive cancellation.

Partitioned bulkheads also validate positive partition capacities, nonnegative queue sizes,
and a finite reserved-capacity percentage in `0...1` before creating admission gates. The
deprecated `maxBorrowPercentage` alias retains the same reserved-share semantics and validation.

Finite nonpositive values normalize to zero without converting their magnitude, so even very
large negative values permit immediate free capacity and return the existing queue-timeout
error if a wait would be required. Positive values round to the nearest attosecond; a tiny
positive value rounding to zero has the same no-wait behavior. Positive values that remain
nonzero return the existing full-queue error when capacity is occupied and the queue limit is
zero. Existing normal timeout, queue reuse, and handler-settlement policies are unchanged.
