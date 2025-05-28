# Dependency Management Policy

This document outlines PipelineKit's approach to managing third-party dependencies.

## 📋 Current Dependencies

| Package | Version | License | Purpose | Last Audited |
|---------|---------|---------|---------|--------------|
| [swift-syntax](https://github.com/apple/swift-syntax) | 510.0.3 (exact) | Apache-2.0 | Swift macro implementation | 2025-05-28 |

## 🔒 Security Policy

### Dependency Selection Criteria

Before adding any dependency:

1. **Necessity**: Is it absolutely required?
2. **Maintenance**: Is it actively maintained?
3. **Security**: Does it have a good security track record?
4. **License**: Is the license compatible?
5. **Size**: What's the impact on binary size?
6. **Alternatives**: Can we implement it ourselves?

### Version Pinning Strategy

We use **exact version pinning** for all dependencies:

```swift
.package(url: "...", exact: "X.Y.Z")
```

**Rationale:**
- Reproducible builds
- Predictable behavior
- Controlled updates
- Security audit consistency

### Update Process

1. **Regular Audits**: Run `Scripts/dependency-audit.sh` monthly
2. **Security Alerts**: Monitor GitHub security advisories
3. **Update Review**: All updates require:
   - Security review
   - Compatibility testing
   - Performance benchmarking
   - API stability check

## 🛡️ Security Auditing

### Automated Checks

- **Weekly**: GitHub Dependabot alerts
- **Monthly**: Full dependency audit
- **Per PR**: Dependency change detection

### Manual Review

Run the audit script:
```bash
./Scripts/dependency-audit.sh
```

Generate SBOM (Software Bill of Materials):
```bash
swift package dump-package > sbom.json
```

### Known Vulnerabilities

| CVE | Package | Status | Mitigation |
|-----|---------|--------|------------|
| None | - | - | - |

## 📊 Dependency Metrics

### Current State
- **Total Dependencies**: 1
- **Direct Dependencies**: 1
- **Transitive Dependencies**: 0
- **Security Vulnerabilities**: 0
- **Outdated Packages**: 0

### Size Impact
- **swift-syntax**: ~15MB (build time only, not in final binary)

## 🔄 Update Schedule

| Dependency | Update Frequency | Notes |
|------------|------------------|-------|
| swift-syntax | With Swift releases | Pin to Swift version |

## 📝 Audit Log

| Date | Version | Auditor | Notes |
|------|---------|---------|-------|
| 2025-05-28 | 510.0.3 | CI | Initial audit, no issues found |

## 🚨 Emergency Response

If a critical vulnerability is discovered:

1. **Immediate**: Assess impact
2. **Within 24h**: Patch or mitigate
3. **Within 48h**: Release update
4. **Within 72h**: Notify users

## 🤝 Contributing

When proposing new dependencies:

1. Open an issue with justification
2. Include security assessment
3. Provide size/performance impact
4. List alternatives considered
5. Run audit script with changes

## 📚 Resources

- [Swift Package Manager Documentation](https://swift.org/package-manager/)
- [GitHub Security Advisories](https://github.com/advisories)
- [CVE Database](https://cve.mitre.org/)
- [SPDX License List](https://spdx.org/licenses/)