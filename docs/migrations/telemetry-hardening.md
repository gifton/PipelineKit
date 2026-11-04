# Telemetry hardening

These changes belong to the next minor release. They correct metric identity,
delivery, scrape accounting, and retention contracts; no release version is
selected here.

## Series identity and bounded storage

A series consists of its name, kind, unit, and exact tag dictionary. Different
label values, kinds, and units no longer merge. Raw history is retained per
series, rather than per name. Dictionaries containing punctuation remain distinct
internally; each wire format applies its own label rules at export.

`MetricsStorage` and `PoolObservability` admit at most 1,000 series by default.
Configure a larger cap for a known workload. At capacity, existing series can
still update; observations for new series are rejected and counted. These counts
measure rejected observations, not distinct rejected identities. A zero cap
disables admission. Negative capacities are invalid.

```swift
import PipelineKitObservability

let telemetryStorage = MetricsStorage(maxSnapshotsPerMetric: 100, maxSeries: 2_000)
await telemetryStorage.record(.counter("requests", tags: ["route": "/users"]))
let telemetryDiagnostics = await telemetryStorage.diagnostics
print(telemetryDiagnostics.droppedSeries)
```

## Prometheus scrape state

`export()` and `exportAggregated()` now return the same cumulative scrape view:
counter totals, latest gauges, and histogram totals with a `+Inf` bucket. Timers
remain latest-value gauges in milliseconds. No finite histogram bucket boundaries
are inferred. Use a monitoring backend with raw observations when detailed bucket
distributions are needed.

Raw history eviction, `drain()`, and `pruneOlderThan(_:)` leave scrape state intact.
`clear()` resets raw history, scrape totals, admitted identities, and diagnostics.
Thus `Metrics.flush()` no longer implicitly resets Prometheus counters by draining
its raw storage. History percentile gauges remain available from `aggregate()`.

Nonfinite observations are rejected. Finite negative counter deltas remain in raw
history but are omitted from cumulative Prometheus counters and counted in
`rejectedPrometheusUpdates`; overflowing cumulative updates follow the same rule.

Names use the legacy Prometheus text identifier grammar, preserving dot/dash to
underscore normalization. Invalid labels and collisions after normalization,
suffixing, or generated distribution naming are omitted with diagnostics. Every
series participating in a collision is rejected, so arrival order does not decide
which meaning wins. Empty-valued labels are treated as absent for collision checks.
Explicit timer units other than `ms` are rejected rather than relabeled.

```swift
let scrapeStorage = MetricsStorage(maxSnapshotsPerMetric: 1)
let prometheus = PrometheusExporter(metricsStorage: scrapeStorage)
await scrapeStorage.record(.counter("requests", value: 2))
await scrapeStorage.record(.counter("requests", value: 3))
_ = await scrapeStorage.drain()
let scrape = await prometheus.exportWithDiagnostics()
print(scrape.text) // requests_total remains 5 after draining history.
print(scrape.rejectedSeries.count)
await scrapeStorage.clear()
```

## StatsD aggregation and sampling

The exporter owns both batching and aggregation deadlines. Scheduled aggregation
now transmits its output; canceled deadlines cannot drain a later interval.
Counter and gauge updates can replace existing entries when the aggregation
buffer is full, because those updates do not add stored observations.

Sampling still selects complete metric names deterministically. It does not select
independent events, and compensation is not an accuracy guarantee for a particular
name. Direct counters carry their original amount and `@rate`; aggregated counters
are compensated locally and sent without a second receiver adjustment. Timer and
histogram observations retain their sampling rate. Gauges carry no rate marker.
Negative absolute gauges use the StatsD reset-to-zero plus signed-update encoding
in one datagram.

Malformed DogStatsD tags are reported through the exporter error handler. Metric
names and prefixes cannot inject newline-delimited extra records. Nonfinite
observations and arithmetic overflow are rejected without changing an existing
aggregate. Configuration rejects nonfinite sampling/jitter and invalid capacities
or time intervals; finite sampling/jitter values retain their existing clamping.
Zero flush intervals request an immediate deadline.

Only counters accept an absent value as an increment of one. Timers accept `ms`
or a legacy absent unit; an explicitly different unit is rejected. An aggregation
window rejects new definitions that alias an existing StatsD wire name/kind/tags
after normalization, retaining the existing definition. Units are not encoded by
StatsD: choose distinct protocol names for distinct units, including across windows
and when aggregation is disabled.

Call `forceFlush()` before `close()` to attempt delivery of buffered records.
Closing discards unsent buffers. Concurrent producers are not covered by a global
delivery barrier, and UDP delivery has no acknowledgement guarantee.
An external close joins owned startup/timer work and transport shutdown. A close
called from a currently active exporter operation invalidates the exporter without
waiting for that same operation to finish; its caller can then settle. A task
descendant whose originating operation has already ended follows ordinary close
settlement.

Calling `ObservabilitySystem.enableStatsD(...)` again replaces its event bridge,
attempts to flush, and closes the retired exporter. `disableStatsD()` removes only
that route and likewise flushes then closes its exporter; local storage and logging
continue. The event route switches atomically before retired transport shutdown.
Calls overlapping a replacement
may finish against the exporter they already captured. Await configuration before
emitting events that must use the new endpoint.

## Pool distribution windows and collection lifetime

Pool histogram and summary percentiles now use the most recent 1,000 observations
by default. Their count and sum are cumulative; histogram minimum, maximum, and
mean also cover the lifetime since reset. Changing the window changes percentiles,
not cumulative totals. Pool distributions export as Prometheus summaries because
their API provides quantiles rather than finite histogram buckets.

```swift
import PipelineKitPooling

let poolTelemetry = PoolObservability(maximumSeries: 2_000, distributionWindowSize: 1_000)
await poolTelemetry.recordHistogram("pool_latency_ms", value: 2, labels: ["pool": "requests"])
let poolSnapshot = await poolTelemetry.captureSnapshot()
let poolScrape = poolSnapshot.prometheusFormatWithDiagnostics()
print(poolScrape.text)
print(poolScrape.rejectedSeriesCount)
```

Snapshot dictionary keys now quote and escape labels; use the snapshot's structured
labels and export methods instead of parsing the old ambiguous `name{key=value}`
encoding. `reset()` clears telemetry and admission diagnostics.

The constructor above configures an independent instance. Automatic `ObjectPool`
instrumentation still records into `PoolObservability.shared`, which uses the
default limits.

`statsdFormatWithDiagnostics()` returns `datagrams` and `rejectedSeriesCount`;
`statsdFormat()` returns the same datagrams. Cumulative counter snapshots are
gauges, so repeated snapshots do not count the same increments again. Histogram
snapshots export `_count`, `_sum`, `_mean`, `_min`, `_max`, `_p50`, `_p95`, and `_p99`
gauges. Summaries export `_count`, `_sum`, `_p50`, `_p90`, `_p95`, `_p99`, and `_p999`
gauges. These replace the previous timer observation containing a histogram mean.
Labels use DogStatsD tags; invalid names/labels and conflicting generated metric
names are rejected as whole source series. Preserve each returned string as one
datagram: a negative gauge contains its reset and update on consecutive lines.

Collection/export stop invalidates its current generation before suspension. Old
collection results cannot repopulate history or start another exporter after a
stop/restart. An exporter callback already running may finish; stop does not await
that callback, which permits a callback to stop its own collector. Dropping an idle
collector releases it and unregisters its owned memory-pressure callback. The
shared memory-pressure monitor has a separate lifetime.

`PoolMetricsCollector.stopCollecting()` clears its history, registered exporters,
and allocation-rate baseline. Register exporters again before restarting it.
`PoolObservability.stopExporting()` preserves registered exporters and metrics.
Invalid nonfinite observations and overflowing gauge/distribution sums are rejected
without changing the old values or consuming a new series slot; inspect
`invalidObservationCount`. Integer counter additions saturate and increment
`saturatedCounterCount`.

## Trace retention

`ExecutionTracer.maxTraces` is now an enforced identity cap. At capacity, existing
traces remain writable and new trace identities are rejected; inspect
`droppedTraceCount`. Zero disables trace admission. Expired traces are removed
before new spans are recorded, independently of whether capacity has been reached.
`clearAllTraces()` also resets rejection counts. Reusing a completed trace marks it
active until the newly added span finishes. The trace-count cap does not limit the
number of spans in an admitted trace.

## Validation

Regression suites exercise series collisions, cumulative scrapes, canceled timer
generations, sampling accounting, bounded windows, and stop/restart schedules.
The ordinary-import Consumer emits real exporter output for
`check_telemetry_formats.py`, which uses the independent `prometheus-client` parser
plus uniqueness and histogram checks, and independently applies StatsD counter
accounting. Both Debug and Release run these checks in CI. The protocol contracts
are based on the [Prometheus text specification](https://prometheus.io/docs/instrumenting/exposition_formats/)
and [StatsD metric types](https://github.com/statsd/statsd/blob/v0.9.0/docs/metric_types.md).
