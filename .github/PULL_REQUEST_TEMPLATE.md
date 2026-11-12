## What this changes
What the change does and why. Link the issue it closes, if there is one (`Closes #123`).

## Kind of change
- [ ] Bug fix
- [ ] New API or behaviour
- [ ] Source-breaking change
- [ ] Documentation only
- [ ] Tests, CI or tooling only

## How it was tested
The commands you ran and what they showed. For most changes that is:

```bash
swift test --parallel --skip PipelineKitPerformanceTests
```

Name the tests you added or changed.

## Checklist
- [ ] New behaviour and bug fixes have a test that fails without the change.
- [ ] `CHANGELOG.md` has an entry under `[Unreleased]` for anything a user of the package can observe. A source-breaking change goes under a **Breaking** heading with what callers must change.
- [ ] Documentation and doc comments that describe the changed behaviour are updated to match it.
- [ ] If the change touches a hot path (pipeline execution, `CommandContext`, semaphores, rate limiting), the description says whether you measured it and how.

CI reports coverage, lint and performance results on the pull request; you do not need to fill them in here.
