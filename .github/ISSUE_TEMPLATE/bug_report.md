---
name: Bug report
about: PipelineKit crashes, hangs, or behaves differently from its documentation
labels: 'bug'
---

## What happened
What you observed, including the full error text or stack trace if there is one.

## What you expected
What you expected instead, and where that expectation comes from (a doc page, a doc comment, earlier behaviour).

## Minimal reproduction
The smallest program that shows the problem. Starting point:

```swift
import PipelineKit

struct MyCommand: Command {
    typealias Result = String
}

struct MyHandler: CommandHandler {
    func handle(_ command: MyCommand, context: CommandContext) async throws -> String {
        "done"
    }
}

let pipeline = StandardPipeline(handler: MyHandler())
// try await pipeline.addMiddleware(...)
let result = try await pipeline.execute(MyCommand())
```

Does it happen every time? If not, roughly how often?

## Environment
- **PipelineKit version** (tag or commit):
- **Modules imported** (for example `PipelineKit`, `PipelineKitResilience`):
- **Swift version** (`swift --version`):
- **Platform and OS version** (for example macOS 26.1, iOS 26.1 simulator, Ubuntu 24.04):
- **Xcode version**, if you build with Xcode:
- **Build configuration** (Debug or Release):

## Anything else
Workarounds you found, or where you think the cause is.
