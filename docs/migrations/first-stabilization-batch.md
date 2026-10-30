# First stabilization batch migration — draft

This draft currently covers S01 validation and sanitization only. I01 owns the completed
batch migration guide and compilation of its examples. The snippet below has not yet been
compiled as a standalone migration example; the S01 contract suite exercises the same
capability and pipeline APIs. Encryption and the remaining batch migrations are pending.

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
capabilities. S01 temporarily retains the legacy encryption-only `Command` extension
(`sensitiveFields` and `updateSensitiveFields`) so S02 can migrate its callers in one
buildable change. This draft makes no claim that the legacy encryptor is repaired.
