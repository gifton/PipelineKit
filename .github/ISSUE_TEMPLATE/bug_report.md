---
name: Bug report
about: Create a report to help us improve
title: '[BUG] '
labels: 'bug'
assignees: ''
---

## Description
A clear and concise description of what the bug is.

## To Reproduce
Steps to reproduce the behavior:

1. Create a pipeline with '...'
2. Add middleware '...'
3. Execute command '...'
4. See error

## Expected behavior
A clear and concise description of what you expected to happen.

## Actual behavior
What actually happened instead.

## Code example
```swift
// Minimal code example that reproduces the issue
import PipelineKit

let pipeline = PipelineBuilder(handler: MyHandler())
    .with(MyMiddleware())
    .build()

// ... code that triggers the bug
```

## Stack trace
```
// If applicable, add the full stack trace here
```

## Environment
- **PipelineKit version**: [e.g., 0.1.0]
- **Swift version**: [e.g., 5.10]
- **Platform**: [e.g., iOS 17.0, macOS 14.0]
- **Xcode version**: [e.g., 15.0]
- **Package manager**: [SPM/CocoaPods/Carthage]

## Additional context
Add any other context about the problem here.

## Possible solution
If you have ideas about what might be causing this or how to fix it, please share.