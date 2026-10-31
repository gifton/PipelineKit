# First stabilization batch migration

These source and behavior changes are intended for the next minor release under
[VERSIONING.md](../../VERSIONING.md); no release version or tag is selected here.
All Swift fences in this guide, plus the README/security-guide examples changed by this
batch, are extracted into the ordinary-import Consumer by
[`i01_compile_examples.py`](../superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/i01_compile_examples.py).
The extractor records exact snippet hashes and its import/function harness. Debug and Release
consumer builds compile them; the I01 validation record records results and platform limits.
Unchanged historical examples elsewhere are outside that compilation claim.

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
addition. The consolidated **Breaking** changelog records this behavior change.

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

## Breaking: one StatsD transport startup path

`StatsDExporter.Configuration.useTransport` and the competing async exporter initializer
are removed. All exporters use `MetricsTransport`; the default constructor is synchronous
and lazy, and the first nonempty batch waits for readiness. Remove `useTransport:` and the
constructor's `await`. Where startup must be validated before publishing the exporter,
install its error callback first, then call `try await exporter.start()`:

```swift
import PipelineKitObservability

func makeStatsD() async throws -> StatsDExporter {
    let exporter = StatsDExporter(configuration: .init(host: "127.0.0.1", port: 8125))
    await exporter.setErrorHandler { error in
        print("Metrics export failed: \(error)")
    }
    do {
        try await exporter.start()
        return exporter
    } catch {
        await exporter.close()
        throw error
    }
}

func useInjectedTransport(_ transport: any MetricsTransport) async {
    let exporter = StatsDExporter(configuration: .default, transport: transport)
    await exporter.setErrorHandler(nil) // Callbacks can be cleared before publication.
    await exporter.counter("synthetic.example")
    await exporter.forceFlush()
    await exporter.close()
}
```

The injected initializer takes a nonoptional, already initialized transport and transfers
its shutdown ownership to the exporter, even if no record or `start()` occurs. Concurrent
nonempty batches and explicit `start()` share one startup generation. Startup errors are
thrown by `start()` and reported through the configured callback; each failed batch reports
its terminal error. A later batch can retry failed startup. This does not automatically replay
failed batches or retry a terminal transport's failed sends. Platforms without Network report
an explicit startup error instead of silently discarding default-exporter metrics.

`close()` immediately rejects subsequent recording through the callback, discards buffered
unsent records, cancels the exporter's flush timer and startup, and waits for their settlement
and transport shutdown. A transport produced after close begins is closed by that startup's
owner; repeated/concurrent close shares the same settlement. A cancellation-insensitive factory
or transport can delay close indefinitely. Applications wanting a delivery attempt must quiesce
producers, call `forceFlush()`, then `close()`; UDP completion does not acknowledge remote delivery.

`MetricAggregator.forceFlush` cancels its private timer without joining it. An already
in-flight caller-owned aggregation retry can repopulate its buffer after exporter close.
Exporter closed guards prevent transport revival and post-close sends, but close is not a
barrier for caller-owned recording or full aggregator quiescence. Quiesce and join producers
before the flush/close sequence.

Sampling and aggregation semantics are unchanged; OBS-001, OBS-005 and OBS-009 remain open.
The existing default configuration still disables aggregation. The public consumer mode
`statsd-startup` compiles this construction/start/flush/close shape and verifies the first
nonempty default-exporter batch on real loopback. See the I01 validation record for example compilation and platform integration checks.

## Breaking: immutable Metrics configuration and explicit flush capability

Replace writes to `Metrics.storage`, `Metrics.exporter`, and `Metrics.errorHandler` with one
`await Metrics.configure(Metrics.Configuration(...))` call. The read-only
`Metrics.configuration` property returns a complete snapshot. `Metrics.configure(with:)`
now requires `await`; it and the host/port convenience preserve the captured storage and
error handler while replacing the exporter. StatsD callbacks are installed or cleared before
publication. Custom recorders remain responsible for their own error reporting.

```swift
import PipelineKitObservability

func configureMetrics(_ exporter: any MetricRecorder) async {
    let storage = MetricsStorage()
    await Metrics.configure(.init(storage: storage, exporter: exporter, errorHandler: { error in
        print("Metrics export failed: \(error)")
    }))
    await Metrics.counter("requests")
    await Metrics.flush()
}

func replaceRecorder(_ replacement: any MetricRecorder) async {
    await Metrics.configure(with: replacement)
    let current = Metrics.configuration
    _ = await current.storage.getAll()
}
```

A record retains one complete configuration across storage and export. Already started work
may finish on a retired configuration. Replacement does not close exporters; callers retain
and explicitly flush/close an old exporter when required. A configuration snapshot does not
clone referenced objects: intentionally reusing a mutable recorder across configurations also
shares its buffered data and callback state. `Metrics.disable()` replaces only the exporter;
local recording and the configured error handler remain available.

`Metrics.flush()` drains the captured storage and invokes `flush()` on a captured
`FlushableMetricRecorder`, without calling `record` again on the drained snapshots. Custom
recorders that need a flush operation should conform to `FlushableMetricRecorder` and implement
`func flush() async`. Nonflushable recorders still receive records at recording time, and
facade flush only drains their local storage. StatsD's new public `flush()` forwards to
`forceFlush()`; both retain the same delivery and shutdown limits described above.

Flush is not a barrier for concurrent records and does not flush retired exporters. If a caller
needs a complete flush across reconfiguration, it must quiesce and join its producers, retain
and explicitly flush each relevant exporter, and then close those it owns. This change makes
no new aggregation-quiescence or UDP-delivery guarantee. The standalone Examples package has
no removed-slot or synchronous `configure(with:)` caller; its host/port convenience calls remain
source-compatible. The I01 validation record reports standalone example and migration-snippet compilation separately.


## Breaking: explicit complete cache identity (SCP-04 / SCP-05)

All four cache entry points now require `keyGenerator: any CacheKeyGenerator`:
`CachedMiddleware`, `ConditionalCachedMiddleware`, `SimpleCachingMiddleware`, and
`CachingMiddleware`. Their `.cached`, `.cachedWhen`, and `commandType:` convenience
methods require it too. `DefaultCacheKeyGenerator`, the keyless initializers, and
`useHashableKeys:` are removed. Closure callers must use `ClosureCacheKeyGenerator`;
its async closure receives the command, context, and fully qualified concrete cache
middleware type. Existing generic `CacheKeyGenerator` conformers keep their method signature.

The caller must encode **every result-varying command argument, verified principal/tenant,
and relevant configuration or result-schema version**. Authenticate and authorize before
caching a protected result. Do not substitute `hashValue`, descriptions, type names, or
correlation IDs for equality of those inputs. Include correlation only if the application's
result contract varies by correlation. Intentional shared keys are an explicit application
choice, valid only when the omitted fields cannot affect the result.

This example uses an unambiguous length-prefixed caller key. `authUserId` is written by
`AuthenticationMiddleware`; this application also establishes `verifiedTenantID` before
caching. The guards diagnose incorrect pipeline configuration instead of silently supplying
a shared identity. Extend the key whenever the command or handler gains a result-varying input.

```swift
import Foundation
import PipelineKit
import PipelineKitCache

struct ProfileQuery: Command {
    typealias Result = String
    let accountID: String
    let locale: String
}

struct ProfileStage: Middleware {
    let priority: ExecutionPriority = .preProcessing
    func execute<C: Command>(
        _ command: C, context: CommandContext, next: @escaping MiddlewareNext<C>
    ) async throws -> C.Result {
        try await next(command, context)
    }
}

let profileKeys = ClosureCacheKeyGenerator { command, context, _ in
    guard let query = command as? ProfileQuery,
          let principal = context.getMetadata("authUserId") as? String,
          let tenant = context.getMetadata("verifiedTenantID") as? String else {
        preconditionFailure("Profile caching requires a verified principal and tenant")
    }
    let fields = [query.accountID, query.locale, principal, tenant, "profile-format-v2"]
    return fields.map { "\($0.utf8.count):\($0)" }.joined()
}

let memory = InMemoryMiddlewareCache()
let bytes = InMemoryCache(maxSize: 1000)
let wrapped = CachedMiddleware(
    wrapping: ProfileStage(), cache: memory, keyGenerator: profileKeys, ttl: 300
)
let conditional = ConditionalCachedMiddleware(
    wrapping: ProfileStage(), cache: memory, keyGenerator: profileKeys, ttl: 300,
    shouldCache: { command, _ in command is ProfileQuery }
)
let simple = SimpleCachingMiddleware(
    ttl: 300, maxSize: 1000, commandType: ProfileQuery.self, keyGenerator: profileKeys
)
let encoded = CachingMiddleware(
    cache: bytes, commandType: ProfileQuery.self, keyGenerator: profileKeys, ttl: 300
)
let wrappedFactory = ProfileStage().cached(ttl: 300, cache: memory, keyGenerator: profileKeys)
let conditionalFactory = ProfileStage().cachedWhen(
    ttl: 300, cache: memory, keyGenerator: profileKeys,
    condition: { command, _ in command is ProfileQuery }
)
```

Use the unconditional wrappers only in pipelines whose commands the generator supports.
The type-selective factories and conditional false branch bypass key generation and caching.
Key generation can suspend and occurs before SimpleCachingMiddleware's synchronous storage lock.
No cache API infers a fallback identity, inspects `Hashable`, or adds correlation implicitly.

Every implementation applies the same internal framing:
`utf8Length:commandType` + `utf8Length:resultType` + `utf8Length:middlewareType` +
`utf8Length:callerKey`. Type names are fully qualified. Wrapper types include the wrapped
middleware type. Different instances of the same middleware type still need caller keys that
distinguish result-varying instance configuration. The generator's return is the caller portion,
not the complete backend key; backend per-key removal still takes the complete stored key.

**Invalidate all old cache contents when migrating**, including persistent or distributed
backends. Old keys are incompatible with the new namespace. Call `invalidateAll()` on a
`MiddlewareCache`, `clear()` on a `Cache`, and `clear()` on existing `SimpleCachingMiddleware`
instances, as applicable. TTL, cache backend interfaces, and their removal/clear semantics
remain; this change does not add invalidation fencing for in-flight fills or single-flight work.
A deployment must also clear or version entries when result-varying application configuration
changes without an accompanying key change.

The task tests exercise all four APIs and their convenience paths in the root test package.
No existing standalone `Examples/Sources` cache caller required migration. The snippets above are included in the compiled example manifest; the final platform matrix
remains explicit in the I01 validation record.
S04 separately owns LRU predecessor cycles.

## Breaking: complete bounded decompression (SCP-07)

Every `CompressionUtility.decompress` call must now supply a positive `maxOutputSize`:

```swift
#if canImport(Compression)
import Foundation
import PipelineKitCache

func decodeCachedPayload(_ compressed: Data, sizeHint: Int?) throws -> Data {
    try CompressionUtility.decompress(
        compressed,
        using: .zlib,
        originalSize: sizeHint,
        maxOutputSize: 1_048_576
    )
}
#endif
```

Choose the byte limit from the application's payload policy, independently of untrusted
size metadata. `originalSize` remains optional and is only a nonnegative allocation hint;
it neither defines the decoded length nor proves completion. Its initial allocation is
capped at the limit and 64 KiB, including when the hint is `Int.max`. A negative hint or a
nonpositive limit throws `CompressionError.decompressionFailed`, including for empty input.

Successful decoding returns the entire single stream, including when its decoded size
exactly equals the limit. A shorter output buffer no longer returns a successful prefix.
Output beyond the limit throws `CompressionError.dataTooLarge(maxOutputSize)`. Invalid,
truncated or stalled input and bytes following a complete stream throw
`CompressionError.decompressionFailed`; concatenated streams must be framed separately
before passing each compressed payload to this API. Invalid input must be rejected or
replaced from a trusted source rather than retried by raising the output limit. The limit
bounds returned bytes; it is not a bound on the codec's internal state or total process memory.

The utility now compresses every nonempty payload, including sizes 1–100. It no longer
returns unmarked raw bytes for those sizes. Empty input keeps its empty representation
after argument validation. Middleware still applies its configured size threshold and
uses the compressed result only when it is smaller. Old small utility outputs have no
format marker: recover them using application-owned format/size metadata or regenerate
them from trusted originals; do not infer that arbitrary failed decompression is raw data.

Codec mappings and level behavior are unchanged: `.zlib` and `.gzip` use Apple's raw
DEFLATE codec, `.lzfse` and `.brotli` use LZFSE, and `.lz4` uses Apple's framed LZ4.
SCP-08 remains open; these aliases do not establish gzip or Brotli interoperability or
working compression-level selection. The root contract suite compiles the new API and
exercises all five cases on the Compression-capable host. The standalone Examples package
has no decompression caller to migrate. Standalone Examples and migration snippets have separate build evidence in the I01 validation
record; absent platforms remain release-readiness gaps.


## Breaking: rate-limit scope and distributed counter keys (R-F08)

`RateLimiter(scope: .global)` now applies one budget to all supplied identifiers in every
strategy: token bucket, sliding window, fixed window, leaky bucket, adaptive, distributed,
and priority based. The public admission, status, reset and initializer signatures are
unchanged. Keep passing the original user/IP/command identifier; do not pre-encode a key.
Admission and status normalize it once, and supported per-identifier local resets normalize
it the same way. For example, after a one-request global budget admits `"A"`, `"B"` is denied
and its status reports the same remaining budget. Applications that relied on the previous
separate per-caller budgets must select `.perUser`, `.perIP` or `.perCommand` explicitly.

All four scopes now use separate internal namespaces. A distributed store receives these
exact keys, with the caller's complete supplied string appended verbatim in non-global scopes:

| Scope | Key passed to `DistributedRateLimitStore` |
| --- | --- |
| `.global` | `pipelinekit:rate-limit:v1:global` |
| `.perUser` | `pipelinekit:rate-limit:v1:user:` + supplied identifier |
| `.perIP` | `pipelinekit:rate-limit:v1:ip:` + supplied identifier |
| `.perCommand` | `pipelinekit:rate-limit:v1:command:` + supplied identifier |

Treat those incoming keys as opaque in the store. A supplied string that already resembles
an internal key remains caller data and gets its scope prefix; it is never decoded or stripped.
Two distributed limiter instances using the same store budget and `.global` intentionally
share the constant global key. There is no per-instance UUID. **Give distinct logical budgets
separate store namespaces**, such as different Redis prefixes or an application-owned store
adapter that frames its budget namespace before the opaque limiter key. Instances of the same
logical budget must use the same namespace, window size and rate configuration.

Persisted counters under the former raw identifiers are incompatible with the new keys.
Update any direct store inspection, seeding or administrative per-key reset tooling to use
the table above within the correct store namespace. Coordinate deployment: old and new
processes otherwise use independent counters and can admit more than the intended budget.
Quiesce old callers and let their active accounting windows expire before enabling the new
namespace, or explicitly migrate counts under a store-specific coordinated procedure. A new
empty namespace starts a fresh budget. Old per-caller counts cannot simply be renamed to one
global key without deciding how to combine usage and windows; the library does not perform
that migration. No live in-repository caller constructs the old distributed keys directly.

The strategy cost, refill and admission policies are unchanged. Priority based admission and
status still select `.medium`; propagation of a command's priority remains deferred as R-F09.
`reset(identifier:)` supports token bucket, sliding window, fixed window, leaky bucket and
adaptive state; in global scope any supplied identifier resets that shared local budget.
Per-identifier priority reset remains unsupported, while `reset()` clears all local priority
windows. Neither reset form resets distributed counters; R-F10 remains deferred. Use an
explicit administrative store operation for those counters when needed.

The scope contract suite covers the seven strategies, four scopes, exact store keys and
boundaries using an internal clock seam; the public initializer retains wall-clock `Date`
behavior. The I01 validation record covers available platform/Release integration; the consolidated
next-minor **Breaking** entry includes this migration.

## Breaking: structural pipeline timeout classification (R-F21)

Retry and circuit-breaker policies now classify the four typed `PipelineError` timeout
cases by their enum cases. Other `PipelineError` values, including `.wrapped` and
`.retryExhausted`, are treated as ordinary unknown errors even if their descriptions or
payloads contain the word `timeout`. They are not recursively unwrapped. Applications
that intentionally classify wrapped errors should supply an `errorEvaluator` to the
relevant middleware configuration and inspect the wrapper explicitly. Foreign errors
continue through the existing policy and description fallback. `PipelineError.cancelled`
is never retried and follows the circuit breaker’s configured unknown-error policy; native
`CancellationError` and custom evaluators retain each middleware’s existing precedence.
Retry `maxAttempts` semantics are unchanged.


## Other corrected behavior and remaining boundaries

Builder additions from plain, named, array and explicit-order APIs now compose into one
sequence. Explicit effective priority and stable ties survive construction. Security stages
that were previously dropped can now reject commands, so migrate command capabilities before
exercising a repaired route. `NextGuardConfiguration.withoutWarnings` is task-scoped; concurrent
configuration changes remain independent of the scope. Callbacks run after configuration locks
are released.

Truncation uses Swift Characters and returns empty for nonpositive maxima; overlong suffixes
are themselves truncated to the maximum. `InMemoryAuditLogger(capacity: 0)` retains no events
and counts drops; negative capacity violates a precondition. Standard `userID`/`sessionID`
metadata now appears in the production audit identity whitelist. These changes add no arbitrary
sensitive metadata to that whitelist.

Health status queries reevaluate retained request history and probe freshness. They scan retained
history in O(n), a performance cost; this batch does not establish unchanged throughput or close
LS-010. Sufficient recent request failures can take precedence over probe results. Automatic
monitor task ownership and production callback-task settlement remain outside this repair.

Timer snapshots convert seconds to milliseconds once. Pool latency conversion includes whole
seconds, clamps negatives to zero and saturates at UInt64.max, including Duration values whose
whole seconds exceed Int64.max. The final O04 regression is part of I01’s rediscovered full suite.

The selected repairs do not promise hard deadlines for cancellation-insensitive handlers,
preemptive cancellation, durable execution, exactly-once side effects, in-flight cache fill
fencing, key-memory zeroization or UDP delivery acknowledgement. The execution-owned ledger
keeps all 47 deferred findings open. Swift 6.2/OS 26, Linux and hosted security/branch-protection
verification require the named release-owner checks when unavailable locally.
