# Security Policy

## Supported versions

PipelineKit is pre-1.0. Only the latest released version receives security
fixes; there are no maintenance branches for older releases.

| Version | Supported |
|---------|-----------|
| Latest 0.x release | Yes |
| Anything older | No |

## Reporting a vulnerability

Report vulnerabilities privately through GitHub:

1. Open the repository's **Security** tab → **Report a vulnerability**
   ([direct link](https://github.com/gifton/PipelineKit/security/advisories/new)).
2. Describe the issue, the affected module(s), and reproduction steps if
   you have them.

Please do not open a public issue for a suspected vulnerability.

### What to expect

PipelineKit is maintained by an individual. Reports are typically
acknowledged within a week. There is no formal SLA and no bug bounty
program. Confirmed vulnerabilities are fixed in the next release, and the
advisory is published once the fix ships.

## Scope

In scope: the seven published library modules under `Sources/`
(`PipelineKit`, `PipelineKitCore`, `PipelineKitSecurity`,
`PipelineKitResilience`, `PipelineKitCache`, `PipelineKitPooling`,
`PipelineKitObservability`).

Out of scope: example code (`Examples/`), test targets, documentation, and
CI configuration.

## Hardening guidance

Security best practices for building *on* PipelineKit — validation,
authorization, rate limiting, encryption, audit logging — live in
[docs/guides/security-best-practices.md](docs/guides/security-best-practices.md).
