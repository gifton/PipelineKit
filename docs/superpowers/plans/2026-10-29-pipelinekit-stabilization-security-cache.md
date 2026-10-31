# PipelineKit security and cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make security customization executable, encrypted envelopes free of retained commands, cache identity explicit and decompression complete.

**Architecture:** Use real capability protocols, ciphertext-only Codable envelopes and atomic key snapshots. Require one explicit cache-key contract across implementations and completion-aware bounded decoding.

**Tech Stack:** Swift 6.2, XCTest, CryptoKit/swift-crypto, Foundation, Apple Compression where available.

**Spec:** [Stabilization design](../specs/2026-10-29-pipelinekit-stabilization-design.md), “Security, identity and data.”

## Global Constraints

- Swift tools version remains 6.2; preserve existing language/concurrency settings and declared platform floors.
- Add no third-party dependencies. Use existing Atomics, CryptoKit/swift-crypto, Compression, Network and Foundation where already supported.
- Breaking changes are permitted; ship them in the next minor release under VERSIONING.md, with a Breaking entry and compiled migration examples. Do not invent or publish a release tag during implementation.
- Preserve the completed audit artifacts. Store remediation evidence separately and identify the exact source revision and local diff for each run.
- Do not lower assertions, skip failed regression cases, relax Sendable checking or replace production failures with successful defaults to make validation pass.
- Tests that coordinate races must acknowledge entry, grant, cancellation and settlement; sleeps alone do not establish ordering. Join all work created by the fixture. Use an external process watchdog for hang/crash probes.
- Resource permits remain owned until downstream work settles. This batch does not promise preemptive cancellation, hard deadlines for arbitrary handlers, durable execution or exactly-once side effects.
- Migrate all live callers of a changed API in the same task, including test fixtures; integration is not a holding area for uncompilable intermediate commits.
- A new gate or routing change requires tests of every newly reachable branch. A repeated defect class requires a mechanical regression matrix across its implementations.

Read the [master plan](2026-10-29-pipelinekit-stabilization.md) and [design](../specs/2026-10-29-pipelinekit-stabilization-design.md) before executing. All paths below are repository-relative. New test names are planned tests, not claims of current coverage. Commands are future execution instructions; retain their actual test counts and exit status. Each task ends with its own reviewed commit and a closure-ledger update; use explicit file lists, never blanket stage unrelated local work.

## Review Focus

1. A concrete method can appear to work while generic dispatch ignores it: S01 exercises actual pipelines and handler-entry sentinels.
2. Rotation can pair ciphertext with another key's ID: S02 uses two encryptors and a shared, gated store.
3. Equal hashes or delimiter collisions are not equal cache identities: S03 covers all cache entry points with explicit principals.
4. A positive decode byte count can be an incomplete prefix: S05 covers limits n−1/n/n+1, wrong hints, corrupt input and small payloads.
5. Zero capacity, Unicode suffix lengths and multi-node ownership differ from ordinary inputs: S04/S06 cover these boundaries explicitly.

## Task S01: Replace ineffective hooks with security capabilities

**Finding ID:** SCP-01. **Dependencies:** C01 before integration closure; V02 before using event-match assertions.

**Files:** Modify `Sources/PipelineKitSecurity/Command+Security.swift`, `Sources/PipelineKitSecurity/Middleware/Validation/ValidationMiddleware.swift`, `Sources/PipelineKitSecurity/Middleware/Sanitization/SanitizationMiddleware.swift`. Create `Sources/PipelineKitSecurity/SecurityCapabilityError.swift`, `Tests/PipelineKitSecurityTests/SecurityCapabilityContractTests.swift`. Migrate existing `Tests/PipelineKitSecurityTests/ValidationDispatchTests.swift`, `Tests/PipelineKitSecurityTests/Security/ValidationTests.swift`, `Tests/PipelineKitSecurityTests/Security/SanitizationTests.swift`.

**Interfaces:** Produce the exact ValidatableCommand, SanitizableCommand and SecurityCapabilityRequirement protocols/enum from the design. Both middleware initializers become `init(requirement: SecurityCapabilityRequirement = .required)`. Public SecurityCapabilityError: Error, Sendable, Equatable cases are `missingValidation(commandType: String)`, `missingSanitization(commandType: String)`, `invalidSanitizedType(expected: String, actual: String)`. No default no-op witness.

- [ ] Add `testGenericPipelineInvokesValidationWitness`, `testGenericPipelinePassesReturnedSanitizedValue`, `testMissingRequiredCapabilityRejectsBeforeHandler`, `testIfPresentAllowsUnrelatedCommand`. Assert rejection means handlerEntries=0; sanitized immutable command reaches the handler with transformed fields and the original caller value unchanged. Exercise Standard, AnyStandard and Dynamic routes, including a mixed named/plain builder.
- [ ] Run `swift test --filter 'SecurityCapabilityContractTests|ValidationDispatchTests'`. Before adding declarations, expected compile failure on the new API; preserve the old behavioral counterexample from V202b. A compile-red alone is not runtime proof.
- [ ] Add real async protocol requirements, remove extension-only validation/sanitization hooks and their heuristic APIs, and dispatch through capability existentials. Retain the encryption-only extension block temporarily until S02 replaces its callers, so S01 builds independently; S02 removes that block before batch integration. Preserve the unrelated SecurityValidatable and EncryptableCommand protocols. Use a checked erased-result cast for sanitization; propagate the concrete validation error unchanged.
- [ ] Migrate existing affected test conformances to explicit capability conformance and async methods. Run `swift test --filter PipelineKitSecurityTests` plus the C01 composition filter. Expected missing conformance fails explicitly and capability invocation reaches the supplied witness.
- [ ] Update public symbol documentation and the migration draft; commit `fix(security): require explicit validation and sanitization capabilities`.

## Task S02: Encrypt the whole command with one key snapshot

**Finding IDs:** SCP-02, SCP-03; closes the encryptor-specific part of SCP-01 together with S01. **Dependencies:** S01 removes old hook claims.

**Files:** Modify `Sources/PipelineKitSecurity/Command+Security.swift`, `Sources/PipelineKitSecurity/Encryption/CommandEncryptor.swift`, `Sources/PipelineKitTestSupport/Mocks/InMemoryKeyStore.swift`, `Tests/PipelineKitSecurityTests/InMemoryKeyStoreTests.swift`, `Tests/PipelineKitSecurityTests/Security/EncryptionTests.swift`. Create `Sources/PipelineKitSecurity/Encryption/EncryptionKeySnapshot.swift`, `Tests/PipelineKitSecurityTests/CommandEncryptorContractTests.swift`.

**Interfaces:** Produce `EncryptionKeySnapshot(key: SendableSymmetricKey, identifier: String)` and KeyStore's atomic async `currentKeySnapshot`. Replace encrypt/decrypt with the exact `T: Command & Codable` signatures in the design. EncryptedCommand initializer becomes `init(encryptedData: Data, keyIdentifier: String, algorithm: String)`; no T instance is stored.

- [ ] Add `testEnvelopeContainsOnlyCiphertextAndMetadata` and `testCodableCommandRoundTripReconstructsAllFields`. Use synthetic secrets, assert exact full-command equality after decrypt, and inspect the envelope's declared fields/retained references. A compile-only negative consumer fixture must reject access to originalCommand; do not rely on a ciphertext substring search as the secrecy proof.
- [ ] Add `testSharedStoreRotationPreservesCiphertextKeyIdentity`: encryptor A initializes, B rotates the shared store, A encrypts and both decrypt correctly using envelope IDs. Gate overlapping store/rotation calls and verify every emitted envelope opens with the key looked up by its own ID. Include missing-key, tampered ciphertext and unsupported algorithm controls.
- [ ] Run `swift test --filter 'CommandEncryptorContractTests|InMemoryKeyStoreTests'`; expected red/new-API compile red, with V203b/V204b retained as behavioral baseline evidence.
- [ ] Implement complete JSON encode/seal and open/decode, then remove the obsolete sensitiveFields/updateSensitiveFields/hasSensitiveFields extension block from `Sources/PipelineKitSecurity/Command+Security.swift`. Cache/capture an immutable key+ID pair, atomically read the store snapshot, and return the captured ID. Rotation publishes a stored pair; no separate ID read or default-ID fallback. Restrict accepted algorithm to the produced AES-GCM-256 format and propagate cryptographic authentication failure.
- [ ] Run the new filter and existing EncryptionTests in Debug and Release, including crypto-supported Linux CI when available. Assert old keys remain usable until explicitly expired; missing keys fail, never return retained plaintext.
- [ ] Document the incompatible old partial-field format and recovery limits in the migration draft. Update the three linked closure rows without claiming SCP-09 is fixed; commit `fix(encryption): remove plaintext envelope ownership and bind key identity`.

## Task S03: Require complete explicit identity on every cache API

**Finding IDs:** SCP-04, SCP-05. **Dependencies:** C01 for integration; independent of S02.

**Files:** Modify `Sources/PipelineKitCache/CachedMiddleware.swift`, `Sources/PipelineKitCache/CachingMiddleware.swift`, `Sources/PipelineKitCache/SimpleCachingMiddleware.swift`. Create `Sources/PipelineKitCache/CacheKeyNamespace.swift`, `Tests/PipelineKitCacheTests/CacheIdentityContractTests.swift`. Migrate existing `Tests/PipelineKitCacheTests/CachingMiddlewareTests.swift`, `Tests/PipelineKitCacheTests/SimpleCachingMiddlewareTests.swift`, `Tests/PipelineKitCacheTests/NextGuardSuppressionTests.swift`, and the live cache-constructor callers in `Tests/PipelineKitCacheTests/LRUEvolutionTests.swift`. S04 retains ownership of LRU predecessor/lifetime changes.

**Interfaces:** All four constructors/factories require `keyGenerator: any CacheKeyGenerator` with no default. Add public `ClosureCacheKeyGenerator.init(_ generate: @escaping @Sendable (any Command, CommandContext, String) async -> String)`, implementing the existing generic protocol method. Internal `CacheKeyNamespace.encode(commandType: String, resultType: String, middleware: String, callerKey: String) -> String` uses UTF-8 length prefixes. Preserve existing TTL/cache backend parameters.

- [ ] Add `testCacheIdentityMatrix` over Cached, ConditionalCached, SimpleCachingMiddleware and CachingMiddleware. Two command arguments × two typed userIDs produce four distinct results; repeating one identity hits exactly once. Change correlation alone and assert behavior follows the caller's explicit identity contract, not a wrapper's fallback.
- [ ] Add `testEqualHashValuesDoNotShareResults` using different values whose Hashable implementation deliberately collides, and `testNamespaceEncodingIsUnambiguous` with separators, empty keys, Unicode and distinct fully qualified command/result types. Include the conditional true/false branches and an authenticated pipeline with principal-dependent results.
- [ ] Run `swift test --filter CacheIdentityContractTests`; retain V207b/V208b for old defaults/conveniences. New mandatory APIs may initially fail compilation; label that accurately.
- [ ] Remove DefaultCacheKeyGenerator, hash/type-only convenience generation and silent fallback branches. Route every entry point through the generator and common namespace encoder. Await key generation outside synchronous cache locks. Document that callers supply principal, arguments and relevant configuration, and intentional shared keys are explicit.
- [ ] Update existing call sites with real complete fixture keys, not a constant that hides collisions. Run `swift test --filter PipelineKitCacheTests` in Debug and Release. Expected wrong-principal/argument results never occur and hit/TTL/invalidation behavior remains.
- [ ] Add migration examples and require invalidation of old cache contents. Update both rows; commit `fix(cache): require explicit complete keys across caching APIs`.

## Task S04: Remove LRU predecessor ownership cycles

**Finding ID:** SCP-06. **Dependencies:** none; land separately from key changes.

**Files:** Modify `Sources/PipelineKitCache/LRUStorage.swift`; add cases to `Tests/PipelineKitCacheTests/LRUEvolutionTests.swift`.

**Interfaces:** No API change. Node.prev becomes weak; the map/forward chain own live nodes.

- [ ] Add `testMultiNodeValuesReleaseOnClearAndContainerDrop`, `testPromoteThenEvictReleasesOnlyVictim`. Test 0, 1, 2 and 3 nodes using weak reference witnesses; verify remaining values/order, then nil after clear/drop.
- [ ] Run `swift test --filter LRUEvolutionTests`; expected multi-node retention red.
- [ ] Make the predecessor non-owning and verify unlink/promotion/tail/head updates retain a reachable forward chain.
- [ ] Re-run the filter in Debug and Release. Expected all weak witnesses and LRU order assertions pass, with no sleeps or explicit user cleanup required.
- [ ] Update SCP-06; commit `fix(cache): break LRU node ownership cycles`.

## Task S05: Bound decompression and require stream completion

**Finding ID:** SCP-07. **Dependencies:** none; preserve conditional platform compilation.

**Files:** Modify `Sources/PipelineKitCache/CompressionMiddleware.swift`; add cases to `Tests/PipelineKitCacheTests/CompressionMiddlewareTests.swift` and create `Tests/PipelineKitCacheTests/CompressionCompletionContractTests.swift`.

**Interfaces:** `CompressionUtility.decompress(_ data: Data, using algorithm: CompressionAlgorithm, originalSize: Int? = nil, maxOutputSize: Int) throws -> Data`. Keep existing compress signature; remove its unmarked nonempty-small-data passthrough. Use existing CompressionError.decompressionFailed/dataTooLarge for invalid/incomplete/over-limit results, documenting each path.

- [ ] Add `testDecodeCompletesOrThrowsForEverySizeHintAndLimit`. For highly compressible 100,000-byte input, test hints nil/17/n−1/n/n+1 and limits n−1/n/n+1 for every actual platform codec represented by the enum. Limit n−1 throws; limits n/n+1 return exactly n original bytes regardless of hint. Add independently generated incompressible fixture data.
- [ ] Add `testTruncatedCorruptAndStalledStreamsNeverReturnPrefixes`, `testSmallPayloadRoundTrips` for 0/1/99/100/101 bytes, and invalid negative hint/nonpositive limit controls. Empty input with valid limits returns empty. Test trailing input policy explicitly: reject bytes left after the single compressed stream, rather than silently accept concatenated payloads.
- [ ] Run `swift test --filter CompressionCompletionContractTests`; retain V206b as prefix baseline. New signature compile failure is separate from behavioral red.
- [ ] Implement bounded incremental decoding using compression_stream completion/error status. Check arithmetic before allocation, cap hint allocation, destroy state on every path, detect lack of progress and distinguish exact-limit completion from overflow. Remove the utility's small-input bypass; keep the middleware's threshold/benefit decision. Do not silently rename codecs or claim compression level support.
- [ ] Re-run all Compression tests on a Compression-capable host. Expected byte-for-byte full output or explicit error; no positive prefix counted as success. Record Linux's absent Compression branch as unavailable, not a passing decoder run.
- [ ] Update SCP-07 and migration signature examples; leave SCP-08 open; commit `fix(compression): require complete bounded decompression`.

## Task S06: Define sanitizer and audit-log capacity boundaries

**Finding IDs:** SCP-11, SCP-12. **Dependencies:** V02 for any event assertions.

**Files:** Modify `Sources/PipelineKitSecurity/Sanitization/CommandSanitizer.swift`, `Sources/PipelineKitSecurity/Audit/InMemoryAuditLogger.swift`. Add to `Tests/PipelineKitSecurityTests/Security/CommandSanitizerTests.swift`; create `Tests/PipelineKitSecurityTests/AuditLoggerCapacityTests.swift`.

**Interfaces:** Preserve truncate and logger public signatures. Nonpositive truncation bound returns empty; logger negative capacity has an explicit initialization precondition, zero is no-retention, nil is unbounded.

- [ ] Add `testTruncateBoundaryMatrix` for bounds −1/0/1/2/3/4, empty/default/long suffix, short/long input and multi-scalar grapheme clusters. Assert result.count never exceeds max(0,bound), exact specified suffix behavior and no trap.
- [ ] Add `testZeroCapacityCountsDropsWithoutRetainingEvents`, `testOneCapacityEvictsOldest`, `testNilCapacityRetainsAll`; assert retained counts 0/1/all and drop totals/health notifications after 10 dropped events. Run the negative-capacity precondition case in a bounded subprocess.
- [ ] Run `swift test --filter 'CommandSanitizerTests|AuditLoggerCapacityTests'` under the watchdog for the old crash case; expected red/trap, recorded as such.
- [ ] Implement Character-based safe truncation and a separate zero-retention logging branch. Preserve existing health notification cadence and positive-capacity eviction accounting.
- [ ] Repeat the filter; expected complete matrix passes. Check other local truncate/capacity utilities for identical arithmetic and record any unselected broader R-F19 cases without silently closing that class.
- [ ] Update both rows; commit `fix(security): handle short truncation bounds and zero audit capacity`.

## Task S07: Retain standard identity metadata in production audit output

**Finding ID:** SCP-17. **Dependencies:** V02.

**Files:** Modify `Sources/PipelineKitSecurity/Audit/ConsoleAuditLogger.swift`. Create `Tests/PipelineKitSecurityTests/ConsoleAuditLoggerIdentityTests.swift`.

**Interfaces:** Preserve ConsoleAuditLogger.production and formatter APIs; standard keys are userID and sessionID. Keep legacy userId/sessionId aliases if already supported.

- [ ] Add `testProductionIdentityWhitelistUsesStandardContextKeys` with standard identity, legacy identity, unrelated sensitive payload and ordinary event fields. Assert only intended whitelist values appear; sensitive payload does not.
- [ ] Run `swift test --filter ConsoleAuditLoggerIdentityTests`; expected missing standard identity red.
- [ ] Correct the whitelist; use an internal formatting seam or captured output fixture without changing global stdout for concurrent tests.
- [ ] Re-run the filter and audit logging tests. Expected exact identity preservation and no broader field disclosure.
- [ ] Update SCP-17; commit `fix(audit): preserve standard user and session identity keys`.

