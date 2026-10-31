# C05 — synchronized warning configuration and scoped suppression

Findings: PK-F006 and PK-F007. Base `909303f666baf6926b708eb1d1c3af85aa60cffb`, branch `fix/stabilization-batch-1`. Workdir throughout: `/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/pipelinekit-stabilization`. Initial tracked diff was empty; only the original `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md` were untracked. Neither was changed or staged. Implementation and evidence are committed together with subject `fix(diagnostics): synchronize configuration and isolate warning suppression`; the task report records the resulting SHA. Independent review and closure remain controller-owned.

## Implementation

`WarningConfigurationSnapshot: Sendable` is an immutable pair of the enabled flag and optional `@Sendable` callback. `NextGuardConfiguration` stores that pair in one `Mutex`, uses checked `Sendable` conformance, and exposes the existing public properties through synchronized computed accessors. `snapshot()` takes the lock once and returns a value retaining the callback. The private update operation derives and publishes a complete pair while holding the same lock. Both public set-handler helpers publish `(true, handler)` together; reset publishes `(true, nil)` together. Individual property writes preserve the other field within their critical section. Existing environment-based disabling uses the synchronized property.

The replaced snapshot is returned from the critical section and passed to `withExtendedLifetime` after `withLock` has returned. Thus replacing or resetting a callback cannot destroy its last captured owner while holding the nonrecursive lock. The bounded replacement regression exercises property assignment, both set-handler APIs, and reset with a captured owner whose deinit reads and writes configuration. This is distinct from invoking a warning callback outside the lock; both paths are covered. A reentrant owner may perform a later configuration transaction before the original setter returns, as the replacement test intentionally demonstrates.

Debug `NextGuard.deinit` reads one snapshot, tests its enabled flag, and uses that same retained callback after the lock has been released. It no longer reads two independently changing public properties. Existing pending-state, task-cancellation, throw-exit, and explicit per-instance suppression checks remain intact. The `errorExit` storage and diagnostic deinit stay inside `#if DEBUG`; Release compiled and exercised the available contract cases.

`NextGuardWarningScope.isSuppressed` is an internal `@TaskLocal` Boolean defaulting to false. Both `withoutWarnings` overloads bind it to true without touching shared configuration. Guard construction stores `suppressDeinitWarning || NextGuardWarningScope.isSuppressed`, so scope exit cannot change the diagnostic decision of an escaped guard. The async overload is explicitly `nonisolated(nonsending)`; all public parameter labels, parameter/result types, generic result behavior, and `rethrows` behavior are retained. A compile-and-run test assigns both overloads to their preexisting function-reference call shapes.

## Isolation, floor evidence, and resolved iteration warning

The package still declares tools 6.2 and all Apple platform floors at 26. `Package.swift` is unchanged, including the current StrictConcurrency, AccessLevelOnImport, and ExistentialAny flags; no default-isolation or NonisolatedNonsendingByDefault setting was added.

The first implementation forwarded `operation` directly to `TaskLocal.withValue`. The host SDK selected its deprecated overload with an isolated parameter, emitting one new diagnostic in C05-002. The final implementation wraps the invocation in a trailing closure; this selects the host SDK's newer overload without changing the public operation type. C05-003 rebuilt that source and emitted no compiler warning. C05-004's Release compile likewise contains no new diagnostic.

[SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md) identifies explicit `nonisolated(nonsending)` as implemented in Swift 6.2 and describes its caller-isolation behavior. The [Swift 6.2 TaskLocal source](https://github.com/swiftlang/swift/blob/swift-6.2-RELEASE/stdlib/public/Concurrency/TaskLocal.swift#L195-L208) has the async overload with the default `isolation: #isolation` argument; the final trailing-closure call remains expressible with that older overload. This is source/API support evidence, not an executed floor-toolchain result. The installed SDK `_Concurrency.swiftinterface` was inspected at `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/swift/_Concurrency.swiftmodule/arm64e-apple-macos.swiftinterface`, SHA-256 `35d96630ffba2c68d1077b5658a1562d5b14b722ba7547137f4609077717037b`; its modern and deprecated declarations occur around lines 3624–3646. The existing [Mutex availability assessment](../logs/R01-mutex-availability.json) remains applicable.

`testAsyncSuppressionPreservesCallerIsolation` accesses a non-Sendable object before and after suspension from a MainActor caller, asserts MainActor isolation at both points, returns the same object, and observes the two mutations. It passes on the installed host toolchain. Swift 6.2/OS26 execution and Linux are unavailable locally and remain unclaimed.

## TDD evidence

The first four required tests were added before any production edit. C05-001 compiled and ran all four against the old production source. Three failed with nine assertions; callback reentry passed as the control.

- `testConcurrentWarningConfigurationUsesCoherentSnapshots` failed with `A disabled configuration's callback must never run`. The writer installs an enabled callback, disables warnings, and replaces the callback while disabled. Every published enabled state therefore has the enabled callback. Concurrent guard destruction invoked the disabled-state callback on the old two-read implementation. This is observed incoherent diagnostic behavior, not a TSan claim or proof of an individual low-level race schedule.
- `testOverlappingSuppressionDoesNotRestoreGlobalState` failed because both held scopes changed the global flag, the unrelated guard produced zero warnings instead of one, and the first exit restored true after the test permanently disabled warnings. Its old final warning count was three instead of two, and the unrelated warning was absent. Entry, release observation, and settlement are gated; the first scope is joined before checking the permanent toggle, and the second scope is also released and joined.
- `testNestedAndEscapedGuardSuppression` failed because sync and async escaped guards emitted warnings after scope exit. Its final warning count was three instead of one.

No compiler failure is represented as red evidence. Production changes then made the original cases pass. Additional bounded regression controls cover callback-owner destruction, retained snapshot lifetime, caller isolation, error propagation/restoration, inherited child-task suppression, and function-reference compatibility. These controls were not claimed as additional old-code behavioral reds.

## Final test contract and gate reachability

The final new test file contains nine XCTest cases:

1. `testConcurrentWarningConfigurationUsesCoherentSnapshots`: one writer and three readers acknowledge a common start gate, each performs 256 iterations, and all four mark settlement before the task group returns. It rejects a disabled-state callback and checks an enabled control. Passing does not prove absence of all races.
2. `testWarningCallbackCanReenterConfiguration`: a warning handler resets configuration and installs the handler for the next guard. Two guard releases deliver to the expected handlers without deadlock in Debug; Release emits none.
3. `testReplacingCallbackCanReenterConfiguration`: four public callback replacement paths release a captured owner that immediately reads and writes configuration. Each owner is released once after unlock.
4. `testSnapshotRetainsCallbackAcrossReset`: a snapshot keeps its callback owner alive after global reset; the callback remains invocable, and releasing the snapshot releases the owner.
5. `testAsyncSuppressionPreservesCallerIsolation`: MainActor assertions, non-Sendable state access across suspension, and identity-preserving return.
6. `testHelpersRetainFunctionReferenceCallShapes`: sync and async overloads convert to the old parameter/result function types and return literal values.
7. `testThrowingScopesRestoreSuppressionWithoutChangingGlobalState`: sync and async errors propagate, guards created before the errors remain suppressed, and an unrelated guard warns afterward in Debug.
8. `testOverlappingSuppressionDoesNotRestoreGlobalState`: unrelated diagnostics remain enabled while two scopes overlap; a permanent global disable survives each scope exit; outside diagnostics resume when explicitly enabled.
9. `testNestedAndEscapedGuardSuppression`: nested sync and async scope exits restore the parent scope, an explicitly joined child task inherits suppression, and escaped guards remain suppressed. A later outside guard warns in Debug.

No fixture sleep establishes ordering. The two held tasks, the inherited child task, and all configuration-reader/writer children are joined. These fixtures initiate no cancellation; existing NextGuard cancellation cases still run. No test-only hook was added to production.

The relevant changed gate is global versus scoped warning suppression. Its newly reachable branch is an unrelated unsuppressed guard warning while another task has a suppression scope; the overlap case directly exercises it. The unchanged branch checks remain: disabled global configuration suppresses all diagnostics; explicit middleware markers suppress intentional returns; cancellation and marked throw exits suppress their warnings; unmarked silent returns warn; completed guards do not warn. Focused existing tests cover the ordinary guard, throw-exit, and security/resilience marker contracts. The full suite includes cache suppression, C01 builder capability/ordering contracts, and C04 routing tests. `MiddlewareChainBuilder` is byte-for-byte unchanged, including both Array and ContiguousArray capability and throw-marking paths.

## Commands, outcomes, and warning accounting

Every Swift command used escalation and the approved V04 runner. Exact prefix for each ID: `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 --`.

| ID | Command after runner prefix | Root / runner | Result | Elapsed |
| --- | --- | --- | --- | --- |
| C05-001 | `swift test --filter NextGuardConfigurationContractTests` | 1 / 1 | Old production: 4 tests, 3 failing tests / 9 assertions | 10.280 s |
| C05-002 | `swift test --filter NextGuardConfigurationContractTests` | 0 / 0 | 8 passed; one introduced deprecation diagnostic identified | 12.629 s |
| C05-003 | `swift test --filter 'NextGuardConfigurationContractTests\|NextGuardErrorExitTests\|NextGuardTests\|NextGuardSuppressionConformanceTests'` | 0 / 0 | 24 Debug tests passed; iteration diagnostic removed | 8.317 s |
| C05-004 | `swift test -c release --filter 'NextGuardConfigurationContractTests\|NextGuardErrorExitTests\|NextGuardTests\|NextGuardSuppressionConformanceTests'` | 0 / 0 | 22 Release tests passed, including all 9 new cases; DEBUG-only cases absent | 28.070 s |
| C05-005 | `swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0 | Full final Debug: 1,039 unique XCTest progress records and 20 passing Swift Testing cases | 21.007 s |

All five records report `completion_reason = root_exit`, no watchdog timeout or runner error, settled cleanup, no surviving owned work, and zero termination actions. Raw logs, runner JSON, and process records are retained for every ID. The only nonzero statuses are the intentional C05-001 assertion failures. No redundant full suite was run at unchanged source.

| Run | Unique located compiler diagnostics | Located occurrences | New relative to supplied baseline | Runtime/configuration occurrences |
| --- | --- | --- | --- | --- |
| C05-001 | 0 | 0 | 0 | 0 |
| C05-002 | 19 | 51 | 1, resolved in final source | 0 |
| C05-003 | 0 | 0 | 0 | 0 |
| C05-004 | 20 | 50 | 0 | 0 |
| C05-005 | 0 | 0 | 0 | 0 |

[C05-validation-summary.json](../logs/C05-validation-summary.json) retains normalized diagnostics, occurrence counts, raw log hashes, source-state hashes, outcomes, and exact test counts. Normalization uses relative path plus diagnostic text and omits shifted line/column positions. Runtime/unlocated warnings are scanned separately with a case-insensitive whole-word pattern that includes SwiftLog `warning PipelineKit.Core:`; compiler excerpt repeats are excluded. No runtime/configuration lines were captured in these five logs. This does not resolve the preexisting four SimpleSemaphore lifetime-fixture warnings (C02-N1); they remain separate deferred debt. Existing compiler warnings are not claimed clean. The one iteration warning and its removal are explicitly preserved rather than omitted.

## Source identities and changed files

`repros/c05_source_state.py` captured each ID before its Swift run, preserving HEAD, branch, status, SHA-256, and full local diffs, including the then-untracked new test. C05-001 is the original production plus four red tests; C05-002 is the first implementation plus eight tests; C05-003 changes only async forwarding; C05-004 adds the ninth function-reference test; C05-005 has the same final production/test hashes as C05-004. `repros/c05_validation_summary.py` derives the summary from the immutable raw evidence and supplied warning baseline.

| File | Original production SHA-256 | Final SHA-256 |
| --- | --- | --- |
| `NextGuardConfiguration.swift` | `7566e5773bc8ca191144c5b48085c0b97d8f6fb41f6c0bf58640714917800e7b` | `8d5ac814bd13df6c5e2d84f87f405195b78f55e861875fadfe585513b72e7c81` |
| `NextGuard+Configuration.swift` | `fe83c2a38317a516b8f03c2cfc0227cf86b256b548c953ebc47336db52e6f398` | `067f522cb0a24a78f1dcc00cb9cbb0799773d60c3e96b635a4010b30614e25f8` |
| `NextGuard.swift` | `6feb5d2992af3c5fa2471ef8addd87fb9ac20fa57551a47e25e52f5560b70b9f` | `d2b88941c4242de15b219c80a5f21f7d84e27f718557b2b4cde0ec2d87e0af9d` |
| `NextGuardConfigurationContractTests.swift` | Added in C05 | `46a2ec3673ee7352a4edf8aa0d277d11bdaa9e6880a5ceab0150b8e05312e0c0` |

Unchanged manifest SHA-256: `f9e66a25c968fd8d4a1461efd4c4a62fcc0e1e63bcca2f0bd617e8edd9f18adb`; unchanged chain builder: `1b4dab96aa3a87fcea7ab4bcb8645e8e97ffeb9f7d7d39a8e3b4ffde82cf0148`; unchanged runner: `9fad75b0f9d7216c7467bab2d3b9fd341ef5e2313fd4365c491234eafb480dd0`.

Task changes are the three assigned production files, one new test file, two reproduction/evidence scripts, this report, the appended VALIDATION entries, and precisely named C05 logs/JSON/process/source-state evidence. Self-review checked all lock and callback-release paths, single-snapshot consumption, throw/cancellation and explicit marker preservation, public function-reference shapes, creation-time suppression, gate reachability, task settlement, warning normalization, and final source/hash consistency. `git diff --check` passed. No dependency, floor, concurrency setting, original audit artifact, unrelated production file, CLOSURE row, or progress ledger was changed. No push or merge was performed.

No correctness concern remains from self-review. Limits remain: the coherent-pair stress check is not exhaustive, callback lifetime stress and TSan belong to I01, and host Debug/Release success does not establish minimum-toolchain or other-platform execution. This report supplies PK-F006/PK-F007 implementation evidence; it does not claim final integration closure.
