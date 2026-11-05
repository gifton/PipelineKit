# Security serialization, compression formats, and numeric boundaries

These changes belong to the next minor release. They follow the
[core stabilization changes](core-admission-and-security.md); no release version
or branch cut is selected here.

## Encrypted result fields

`EncryptionService` keeps its typed `encrypt`, `decrypt`, and `validate` methods.
Services that support custom result objects, arrays, or envelopes without type
hints should also conform to `SerializedPlaintextDecrypting` and implement
`decryptSerializedPlaintext(_:)`. This method must authenticate the payload and
return its exact serialized bytes. It must throw on authentication failure.
Share the authenticated opening operation with typed decryption; do not decode
as `Data.self` or deserialize and re-encode the plaintext.

The [field encryption example](../guides/security-best-practices.md#field-level-encryption)
shows a conforming AES-GCM service. Existing typed-only services continue to
handle recognized String, Int, Double, Bool, Date, and Data hints. Fields that
need serialized bytes fail explicitly when the service lacks the new capability.
With partial decryption enabled, only successful fields reach
`withDecryptedData`; inspect `decryption.failedFields` for failures.

For custom JSON hints, middleware supplies `TypedData`. Choose the expected type
from your application's schema and decode that type explicitly:

```swift
import Foundation
import PipelineKitSecurity

struct AccountPayload: Codable, Sendable {
    let accountID: String
    let labels: [String]
}

func decodeAccountField(_ value: DecryptedValue) throws -> AccountPayload {
    guard let serialized = value.get(as: TypedData.self) else {
        throw EncryptionError.decryptionFailed("Expected serialized account field")
    }
    return try serialized.decode(as: AccountPayload.self)
}
```

`typeHint` and `encodingFormat` remain **untrusted, unauthenticated metadata** in
the current AES-GCM envelope. Do not use either as authorization or proof of the
expected schema. This change does not add authenticated associated data or change
the ciphertext format.

An absent hint, or an unknown hint with a non-JSON encoding, produces serialized
`Data` bytes. This differs from decoding a value originally encoded as `Data`:
JSON encodes that value as a base64 string. An old hintless envelope containing
encoded Data therefore returns the JSON string bytes, including its quotes.
Decode using the known original schema; do not infer the type from byte contents.

`EncryptedResultSerializationTests` covers exact plaintext preservation, custom
objects/arrays, typed values, hintless envelopes, partial failures, and tampering.

## Compression names and stored data

New writes use names that describe the actual formats:

| Previous API / stored label | New API | New stored label | Existing bytes |
| --- | --- | --- | --- |
| `.zlib` / `zlib`, `.gzip` / `gzip` | `.rawDeflate` | `deflate-raw` | Raw DEFLATE, without zlib or gzip wrappers |
| `.lzfse` / `lzfse`, `.brotli` / `brotli` | `.lzfse` | `lzfse` | LZFSE |
| `.lz4` / `lz4` | `.appleLZ4` | `apple-lz4` | Apple's framed LZ4 format |

The default is now named `.rawDeflate`; its codec is unchanged. Remove
`CompressionLevel`, `level:` and `compressionLevel:` arguments. These settings
were ignored. Encoding uses the platform's codec settings, and middleware no
longer publishes `compression.level` metadata. The new API does not advertise
gzip, Brotli, or adjustable compression levels.

Read historical labels through `LegacyCompressionAlgorithm` and
`CompressionUtility.decompressLegacy`, keeping the output limit independent of
untrusted size metadata:

```swift
#if canImport(Compression)
import Foundation
import PipelineKitCache

func readLegacyPayload(_ bytes: Data, storedLabel: String) throws -> Data {
    guard let algorithm = LegacyCompressionAlgorithm(rawValue: storedLabel) else {
        throw CompressionError.decompressionFailed("Unknown legacy compression format")
    }
    return try CompressionUtility.decompressLegacy(
        bytes, using: algorithm, maxOutputSize: 1_048_576
    )
}

func writePayload(_ bytes: Data) throws -> Data {
    try CompressionUtility.compress(bytes, using: .rawDeflate)
}
#endif
```

Deploy readers that recognize the new labels before enabling new writes in a
mixed-version system. The legacy decoder intentionally preserves the old label
mappings; a historical `gzip` label does not mean an RFC 1952 gzip stream.
Old unmarked small payloads still require application-owned metadata or
regeneration, as described in the [earlier migration](first-stabilization-batch.md#breaking-complete-bounded-decompression-scp-07).

All decoding entry points retain complete-stream and output-limit checks.
`maxCompressedSize(for:)` rejects negative input and saturates derived overflow
at `Int.max`; it is an estimate, not permission to allocate that size or a proven
bound for every codec. `CompressionFormatContractTests` covers fixed legacy
fixtures and bounded decoding. `check_compression_formats.py` independently
decodes native raw DEFLATE output with Python's zlib implementation.

## Numeric input policy

Validate configuration from files, networks, or user input before constructing
these APIs. Nonthrowing configuration APIs use preconditions for programmer
errors; they do not silently repair invalid values. Throwing store methods use
their existing validation errors. Derived arithmetic is bounded separately.

| Surface | Accepted behavior |
| --- | --- |
| Admission / semaphore waits | `nil` is unbounded; finite nonpositive timeouts do not wait; positive timeouts are at most 86,400 seconds. Zero AsyncSemaphore capacity remains valid. |
| General timeouts | Finite nonpositive values fail immediately without launching the operation. Positive durations must be representable as UInt64 nanoseconds. Grace periods are nonnegative. |
| Retry delays | Configured delays are finite, nonnegative, and representable; multipliers are finite and nonnegative, and jitter is in 0...1. Derived backoff saturates; final jitter also respects the configured maximum. The legacy RetryPolicy requires at least one attempt; RetryMiddleware still permits zero retries. |
| Periodic work | Intervals must be finite, positive, representable, and at least one nanosecond after conversion. This covers health checks and pool cleanup, collection, and export intervals. |
| Rate limiting | Floating-point capacities/refill rates are finite and nonnegative; integer counts are nonnegative. Windows/leak intervals are finite and positive. Negative or nonfinite costs are denied before consuming or replenishing budget. Zero costs and zero refill remain supported. Adaptive factors must produce finite, nonnegative capacity. |
| Health checks | Success-rate thresholds are finite and in 0...1; count thresholds and response-time limits are nonnegative. Custom check timeouts are also validated before sleeping. |
| Pool configuration | Fractional cleanup/shrink intervals retain their precision. Shrink intervals are finite and nonnegative. History capacity zero retains no samples; negative capacity is invalid. Shrink percentages must be finite and retain the existing clamp to 0...1. |

The 24-hour limit applies to admission waits only. Other nanosecond-based timers
retain their representable range (approximately 584 years). A finite duration is
still invalid if conversion would overflow. Huge valid rate capacities saturate
integer status values; counter overflow fails closed rather than admitting more
work.

`NumericBoundaryTests`, `PoolingNumericBoundaryTests`, and the isolated
`check_numeric_boundaries.py` matrix exercise these contracts in Debug and
Release. Pooling changes in this pass cover numeric inputs only; telemetry
aggregation, export, and lifecycle work remain a separate roadmap item.

## Security guide composition

The guide now registers error sanitization and security metrics outside
authentication using explicit equal-priority insertion order. Audit masking
filters the complete enriched metadata and suppresses task-local audit enrichment
only while forwarding the filtered event. Applications that copied the old
examples should update both the wrappers and their registration order.
`SecurityGuideCompositionTests` exercises authentication rejection, safe error
messages, masking at the production sink, and restoration of the caller context.
