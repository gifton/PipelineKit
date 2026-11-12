# Runnable examples

This standalone Swift package consumes PipelineKit through ordinary public imports
and a local package dependency. Use macOS 15 or later and Swift 6.2 or later.

From the repository root, run all five examples in both configurations:

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
swift run --package-path Examples --configuration debug AdvancedExample
```

Each executable throws if an expected outcome is missing. These checks remain
active in Release builds; the success marker follows verification and, for the
metrics examples, exporter shutdown.

| Product | Checked outcome |
| --- | --- |
| `BasicExample` | Exact greeting returned through `StandardPipeline`. |
| `AdvancedExample` | Exact order confirmation after two transient failures and three handler calls; invalid quantity is rejected without another handler call. |
| `MetricsSamplingExample` | Captured ordinary names are selected as whole names, with three increments and `@0.25` per selected name; the critical counter bypasses sampling. |
| `MetricsAggregationExample` | With aggregation off and on: counter total 100, expected gauge observations including the final value 4, and both timer values 100 and 150 milliseconds. |
| `TypeSafeEncryptionExample` | Complete `Codable` command reconstruction through a second encryptor sharing the ephemeral key store, plus AES-GCM authentication failure after ciphertext-tag corruption. |

The metrics examples use an in-process `MockTransport`, so no collector or network
service is needed. They check captured wire data, not UDP delivery. The encryption
example uses synthetic data and process-local keys without printing the password;
it checks the current envelope format, not persisted ciphertext from an older
release. Sampling checks this fixed set of names, not per-event randomness or
statistical accuracy for one name.

The shared PR and version-tag workflow runs the same Debug and Release commands.
The [v0.5.4 migration rehearsal](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/examples-rehearsal.md) records
what the original examples established before these assertions were added.
For APIs outside this inventory, consult the
[upgrade guide](../docs/migrations/0.5-to-0.6.md).
