# Cooperative Cancellation in PipelineKit

## Overview

PipelineKit follows Swift's cooperative cancellation model. When a timeout occurs or a task is cancelled, commands are *requested* to stop execution, but they must actively check for and respond to cancellation.

## Command Author Responsibilities

When implementing a `Command`, you should:

### 1. Check Cancellation at Logical Points

```swift
struct DataProcessingCommand: Command {
    func execute() async throws -> Result {
        var processedItems = 0
        
        for item in largeDataset {
            // Check cancellation periodically
            try Task.checkCancellation()
            
            // Process item
            let result = await processItem(item)
            processedItems += 1
            
            // For long operations, check more frequently
            if processedItems % 100 == 0 {
                try Task.checkCancellation()
            }
        }
        
        return Result(itemsProcessed: processedItems)
    }
}
```

### 2. Use Defer for Cleanup

```swift
struct NetworkCommand: Command {
    func execute() async throws -> Data {
        let connection = try await openConnection()
        
        // Ensure cleanup even if cancelled
        defer {
            Task {
                await connection.close()
            }
        }
        
        // Periodically check during transfer
        while !connection.isComplete {
            try Task.checkCancellation()
            await connection.readNextChunk()
        }
        
        return connection.data
    }
}
```

### 3. Make Operations Cancellable

```swift
struct FileUploadCommand: Command {
    func execute() async throws -> UploadResult {
        let session = URLSession.shared
        
        // URLSession tasks are cancellation-aware
        let (data, response) = try await session.upload(
            for: request,
            from: fileData
        )
        
        // The upload will be cancelled if the task is cancelled
        return UploadResult(response: response)
    }
}
```

## Best Practices

### DO:
- ✅ Call `Task.checkCancellation()` at the start of expensive operations
- ✅ Check cancellation in loops, especially with many iterations
- ✅ Use `defer` blocks for critical cleanup
- ✅ Make network requests and I/O operations cancellable
- ✅ Document any operations that cannot be safely cancelled

### DON'T:
- ❌ Ignore cancellation in long-running operations
- ❌ Perform non-idempotent operations without considering cancellation
- ❌ Leave resources (files, connections, locks) open without cleanup
- ❌ Catch and suppress `CancellationError` without good reason

## Testing Cancellation

```swift
func testCommandRespectsTimeout() async throws {
    let command = SlowCommand()
    let pipeline = Pipeline()
    pipeline.use(TimeoutMiddleware(defaultTimeout: 0.1))
    
    do {
        _ = try await pipeline.execute(command)
        XCTFail("Should have timed out")
    } catch is CancellationError {
        // Success - command was cancelled
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}
```

## Integration with TimeoutMiddleware

The `TimeoutMiddleware` will:
1. Start your command execution
2. Start a timeout timer in parallel
3. If timeout occurs first, request cancellation via `Task.cancel()`
4. Your command should detect this and throw `CancellationError`
5. If configured, a grace period allows additional time for cleanup

## Timeout-Aware Commands

Commands can implement `TimeoutConfigurable` to specify their own timeout:

```swift
struct CriticalCommand: Command, TimeoutConfigurable {
    // This command needs more time than the default
    var timeout: TimeInterval { 300.0 } // 5 minutes
    
    func execute() async throws -> Result {
        // Long-running but critical operation
        try Task.checkCancellation()
        // ...
    }
}
```