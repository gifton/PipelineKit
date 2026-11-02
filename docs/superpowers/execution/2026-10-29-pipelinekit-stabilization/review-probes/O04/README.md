# O04 independent duration boundary probe

Exact helper source at `45f7404` was copied into an isolated standalone probe. Apple Swift 6.4.2 compiles one fixture with three bounded cases. A first copied-runner version query waited for sandbox approval and was interrupted before execution; it supplied no runtime evidence. The five actual runs use the original approved V04 runner. Their raw logs, metadata and process traces are retained under `../../logs/O04-RV-001` through `O04-RV-005`.

- 001 records the toolchain version; 002 compiles the probe.
- 003 constructs a positive duration of 2^63 seconds, then traps during component narrowing before saturation (root/runner -5).
- 004 verifies the negative counterpart returns zero.
- 005 verifies the ordinary 18,446,744,074-second control saturates at UInt64.max.

All observed processes settled. These checks establish the specific boundary defect and controls, not every duration representation or platform. See the independent task review for exact source and diagnostic references. Source, manifest and runner bytes are preserved here; binaries and caches remain in the original temporary directory. `preservation.json` records source and raw-artifact hashes.
