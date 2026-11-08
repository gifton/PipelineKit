# Monitoring and metrics connection lifecycle

0.6.0 repairs ownership and shutdown in health monitoring, memory-pressure
monitoring, and `EventHub.connectMetrics`. See the
[release-readiness guide](release-readiness.md) for qualification limits.

## Health monitoring

Copies of `HealthCheckMiddleware` share one background monitoring lifetime.
An empty `healthChecks` dictionary creates no periodic task. Releasing the last
middleware copy cancels periodic work; explicit shutdown also waits for it:

```swift
import PipelineKitResilience

func shutDownHealthMonitoring(_ middleware: HealthCheckMiddleware) async {
    await middleware.stopMonitoring()
}
```

`stopMonitoring()` is terminal for that shared background lifetime. It cancels
and joins the periodic task, including its in-flight checks and state-change
callbacks. Concurrent and repeated external stops join the same task. A check
or callback that ignores cancellation can delay shutdown indefinitely.

When a periodic check or its state-change callback calls `stopMonitoring()` on
its own middleware, stop cancels future work and returns without waiting for
itself. A later external stop still waits for that work to settle. Stop does
not disable command outcome tracking or explicit `checkHealth(for:)` calls.
Notifications originating from commands or manual checks keep their existing
asynchronous behavior and are outside the periodic shutdown guarantee.

`HealthMonitorLifecycleTests` covers shared-copy release, cancellation during a
check, concurrent stop, callback stop, and stop before the initial task runs.

## Memory-pressure monitoring

`MemoryPressureResponder.startMonitoring()` and `stopMonitoring()` are now
explicitly async. Calls from outside the actor already use `await`:

```swift
import PipelineKit

let memoryResponder = MemoryPressureResponder()
await memoryResponder.startMonitoring()
await memoryResponder.stopMonitoring()
await memoryResponder.startMonitoring()
await memoryResponder.stopMonitoring()
```

An external start waits for observer registration; an external stop invalidates
the run, cancels it, removes its exact notification token, and waits for its
owned work to settle. Repeated stops also join a retiring run. A new generation
waits for its predecessor to settle before registering or sampling. Releasing
an idle responder cancels its work without a background task retaining it.
The singleton `MemoryPressureDetector` forwards the same shutdown behavior.

A handler may stop its own run without waiting for itself. If that handler
then starts monitoring again, start queues the successor and returns before
registration; registration waits for the old callback to finish. External
callers retain the normal awaited-registration and settlement guarantees.
Handlers that ignore cancellation can delay external stop or restart.

`MemoryPressureLifecycleTests` covers sleep cancellation, handler settlement,
reentrant stop/restart, repeated detector stop, registration races, and exact
observer removal. Its iOS/tvOS cases also exercise UIKit memory warnings.
Memory thresholds and the existing available-memory estimate are unchanged.

## Metrics connections

The hub now retains connections created by `connectMetrics`, including the
bridge and recorder. Capture its discardable UUID to disconnect explicitly:

```swift
import PipelineKitObservability

let metricsHub = EventHub()
let metricsStorage = MetricsStorage()
let metricsConnection = await metricsHub.connectMetrics(metricsStorage)
// Use the hub while the connection is needed.
await metricsHub.disconnectMetrics(metricsConnection)
```

Existing calls that ignore the result still compile and now keep the connection
until hub destruction. Each call creates an independent connection. Disconnect
is idempotent, including for unknown identifiers. Ordinary `subscribe` calls
remain weak and still require caller ownership of their subscribers.

Disconnect excludes the connection from delivery snapshots admitted afterward.
Delivery already admitted may finish and retain the bridge and recorder until
settlement. Disconnect does not join delivery, so a recorder may disconnect
itself from its callback. A synchronous fire-and-forget emit is admitted when
its delivery task reaches the hub, which may be later than the emit call.
Neither disconnect nor hub destruction flushes or closes a recorder/exporter;
its owner remains responsible for those operations.

`MetricsConnectionLifecycleTests` covers these ownership and delivery boundaries.
The ordinary-import Consumer `lifecycle` mode checks owner release across all
three components and the existing pool collector, public shutdown settlement, restart, and independent
connections in Debug and Release. See the
[validation commands](../../Scripts/validation/README.md).
