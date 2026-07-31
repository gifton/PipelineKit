# Execution Context and Progress Reporting

Observe a command's trace identity and stream progress from anywhere below
the handler.

## Overview

`ExecutionContext` is a task-local view of the current command execution.
``StandardPipeline`` binds it around the middleware chain and handler;
`DynamicPipeline` binds it around its entire retry loop. Outside pipeline
execution — and inside `Task.detached`, which does not inherit task-locals
— `ExecutionContext.current` is `nil`, and readers must tolerate that.

It carries two things:

- `trace`: an immutable `TraceMetadata` (command ID, optional correlation
  and user IDs), safe to persist and read from any task.
- `progress`: an optional `ProgressReporter` capability handle.

### Reporting progress

Create the stream/reporter pair, attach the reporter to the
`CommandContext`, and consume the stream from the calling side:

```swift
import PipelineKit

let (stream, reporter) = ProgressReporter.makeStream()
let context = CommandContext()
context[ContextKeys.progressReporter] = reporter

let consumer = Task {
    for await update in stream {
        print("progress:", update.fraction ?? 0, update.message ?? "")
    }
}

let result = try await pipeline.execute(command, context: context)
await consumer.value
```

Anywhere below the handler — any nesting depth, no parameter threading —
report through the task-local:

```swift
ExecutionContext.current?.progress?.report(fraction: 0.5, message: "halfway")
```

Delivery is lossy by design: the backing `AsyncStream` buffer is bounded
(`makeStream(bufferSize:)`, default 16) and drops the oldest updates under
pressure — treat updates as hints, not a complete event log. Reporting
never blocks, and reporting after the stream finishes is a no-op.

The pipeline finishes the stream when execution completes or throws —
including failures before the middleware chain starts. Only the execution
whose `CommandContext` attached the reporter finishes the stream; nested
executions inherit it for reporting but never finish it.

### Deferred execution

Task-locals do not survive an enqueue → dequeue boundary. For work that is
persisted and replayed later, snapshot the context at enqueue and rebind
at replay:

```swift
// At enqueue: persist (Snapshot is Codable)
let snapshot = ExecutionContext.current?.snapshot()

// At replay: rebind, optionally attaching a fresh reporter
try await ExecutionContext.withRestored(snapshot!, progress: nil) {
    // runs with ExecutionContext.current restored
}
```

Capability handles are deliberately excluded from `Snapshot` — a replay
attaches a fresh `ProgressReporter` if it wants progress.
