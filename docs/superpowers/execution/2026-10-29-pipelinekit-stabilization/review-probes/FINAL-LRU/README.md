# Final review: cache destructor reentry

Reviewed branch `2c3001b`; original baseline `a93a713`. The final public consumer imports PipelineKitCache from the retained I01 Debug build. The comparison compiles the exact two original cache source files against final supporting dependency objects; it is not a full baseline package build. Original source hashes were checked with `git show`.

`FINAL-RV-LRU-REENTER-001` reaches `BEFORE-CLEAR`, `PAYLOAD-DEINIT-ENTER` and `BEFORE-GET-STATS`, then times out: root -15, runner124. Cleanup settled with no survivors. `CONTROL-001` disables destructor reentry and returns after releasing both payloads. Clean `BASELINE-002` returns after clearing entries but releases zero payloads, demonstrating the old two-node leak. The source shows the same release-under-lock class at expiry, eviction and replacement; those paths were not separately probed by this review.

The first compile attempt is a rejected Sendable captured-var fixture, not a production reproduction. Corrected compilations retain an implicit-strong-capture warning around the weak destructor capture; the outer closure settles before the clear probe. The first baseline executable links duplicate support objects and is superseded by the clean-link baseline002. All attempts remain in raw evidence.

The seven original probe inputs are byte-identical to the review directory. Two additional final-source snapshots are exact `git show 2c3001b` bytes and retain the reviewed cache implementation independently of later fixes. `preservation.json` records their hashes, all21 raw artifacts, exact commands, statuses and checked source/object/binary manifest paths. Binaries and caches remain outside Git. Reproduction depends on the paths and exact support objects recorded in the original manifest; it must use the original reviewed execution runner with a fresh bounded ID.

This is evidence for final-review finding FINAL-RV-F1. It does not claim that a repair has been implemented or accepted. Final whole-branch review, the combined correction pass and scoped review determine the final disposition.
