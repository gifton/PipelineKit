# Runnable examples

This standalone Swift package consumes PipelineKit through ordinary public imports
and a local package dependency. Use macOS 15 or later and Swift 6.2 or later.

From the repository root, run every example in both configurations:

```sh
python3 Scripts/validation/check_examples.py --configuration debug
python3 Scripts/validation/check_examples.py --configuration release
```

The runner seeds the examples' ignored `Package.resolved` from the repository's
lockfile and checks the resulting dependency pins. It builds the package, locates
the binaries through SwiftPM, and executes each under the existing command
watchdog. Build failures, timeouts, process failures, missing logs, and missing or
duplicate `PASS: <ProductName>` lines fail the check. Each invocation retains
fresh logs and process metadata under `.build/validation/logs/`.

To run one example while editing:

```sh
swift run --package-path Examples --configuration debug MiddlewareStackExample
```

Each executable throws if an expected outcome is missing. These checks remain
active in Release builds; the success marker follows verification and, for
`StatsDExportExample`, exporter shutdown.

| Product | Checked outcome |
| --- | --- |
| `BasicExample` | Exact greeting returned through `StandardPipeline`. |
| `MiddlewareStackExample` | Exact order confirmation after two transient failures and three handler calls; invalid quantity is rejected without another handler call. |
| `BatchIngestExample` | 10,240 vectors in 40 batches, one command per batch: the sink received 10,240 vectors whose ids sum to the expected total, each with a norm within 1e-5 of 1; handler concurrency stayed within the limit of 4; one counter and one timer observation per batch. Then 12 batches submitted at once against an outstanding limit of 8: 8 admitted, 4 rejected with `queueFull`. |
| `StatsDExportExample` | Sampling: captured ordinary names are selected as whole names, with three increments and `@0.25` per selected name; the critical counter bypasses sampling. Aggregation off and on: counter total 100, expected gauge observations including the final value 4, and both timer values 100 and 150 milliseconds. |
| `TypeSafeEncryptionExample` | Complete `Codable` command reconstruction through a second encryptor sharing the ephemeral key store, plus AES-GCM authentication failure after ciphertext-tag corruption. |

`BatchIngestExample` is the one to read for a high-volume pipeline. It dispatches one command
per batch because every `execute` does work that does not depend on the payload, and it shows
both sides of `BackPressureMiddleware`: a driver that keeps its in-flight work within
`maxOutstanding` has nothing rejected, and a burst that exceeds it has the excess rejected.
Its handler L2-normalizes each vector; its sink stands in for a real store and keeps counts
and a norm check, not the vectors. It prints:

```text
ingested 10240 vectors in 40 batches of 256 (dimension 64)
handler concurrency stayed within the limit of 4
metrics: 40 counter and 40 timer observations, one of each per batch
overload: 12 batches submitted at once, 8 admitted, 4 rejected with queueFull
PASS: BatchIngestExample
```

It prints no timings. Measured costs of a dispatch and of a metric record are in
[docs/benchmarks.md](../docs/benchmarks.md), with the harness to repeat them.

`StatsDExportExample` uses an in-process `MockTransport`, so no collector or network
service is needed. It checks captured wire data, not UDP delivery. The encryption
example uses synthetic data and process-local keys without printing the password;
it checks the current envelope format, not persisted ciphertext from an older
release. Sampling checks this fixed set of names, not per-event randomness or
statistical accuracy for one name.

The shared PR and version-tag workflow runs the same Debug and Release commands.
The [v0.5.4 migration rehearsal](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/examples-rehearsal.md) records
what the original examples established before these assertions were added.
For APIs outside this inventory, consult the
[upgrade guide](../docs/migrations/0.5-to-0.6.md).
