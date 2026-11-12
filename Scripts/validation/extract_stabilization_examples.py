#!/usr/bin/env python3
"""Extract changed documentation Swift fences into the public Consumer without rewriting bodies.

Every fence of the upgrade guide is compiled, each in its own function, whatever
the baseline; a fence that declares a type the executable Consumer uses stays at
file scope (FILE_SCOPE_DEFINITIONS). Fences of the other listed documents are
compiled only when they differ from the baseline. Each is wrapped in a separate
async-throwing function to scope placeholder names and allow await, except the
security metrics, masking, sanitizer and registration examples, which share one
function so registration can resolve the documented middleware types.
Each fence retains its own manifest entry; import lines move to the common header.
The basic-usage retry definitions stay at file scope so the public consumer can
execute the documented retry policy through a real middleware chain.
Walkthrough documents are checked whole: every fence, in document order, inside one
function, so a later fence can use what an earlier one declares. Their selection
does not depend on the baseline.
Nothing in the extracted examples is executed by importing the compiled file.
Package initializer fragments beginning with dependencies: or targets: are kept
in separate Package.swift fixtures and validated with swift package dump-package.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASELINE = 'a93a713d937e25f68855f22b0720f33c93329b09'
FENCE = re.compile(r'```swift\n(.*?)```', re.S)
GUIDE = 'docs/migrations/0.5-to-0.6.md'
FILES = [GUIDE, 'README.md',
         'docs/guides/security-best-practices.md', 'docs/guides/resilience-patterns.md',
         'docs/tutorials/basic-usage.md',
         'docs/guides/testing.md',
         'Sources/PipelineKit/PipelineKit.docc/GettingStarted.md',
         'docs/guides/enterprise-evaluation.md']
WALKTHROUGHS = {'Sources/PipelineKit/PipelineKit.docc/GettingStarted.md',
                'docs/guides/enterprise-evaluation.md'}
# Documents whose every fence is compiled, independent of the baseline
# (test_upgrade_guide_selection_ignores_the_baseline).
EVERY_FENCE = {GUIDE}
# Fences matching one of these patterns keep their definitions at file scope,
# because Tests/Integration/Consumer executes what they declare. A missing
# entry fails the Consumer build instead of passing silently.
FILE_SCOPE_DEFINITIONS = {
    GUIDE: [r'\bactor ExampleVersionedKeyStore\s*:'],
    'docs/tutorials/basic-usage.md': [r'\bfunc makeFetchDataRetryMiddleware\s*\('],
}
SECURITY_COMPOSITION_DEFINITIONS = [
    r'\bstruct SecurityMetricsMiddleware\s*:',
    r'\bstruct MaskingAuditLogger\s*:',
    r'\bstruct SecureErrorMiddleware\s*:',
    r'\bfunc addSecurityWrappers\s*<',
]
MANIFEST_FRAGMENT = re.compile(r'\A(?:\s|//[^\n]*\n|/\*.*?\*/)*(?:dependencies|targets)\s*:', re.S)


def validate_manifest_fragment(file, number, snippet):
    """Validate exact initializer arguments without resolving package dependencies."""
    name = re.sub('[^a-zA-Z0-9]', '_', file)
    directory = ROOT / '.build/validation/documentation-manifests' / f'{name}-{number}'
    directory.mkdir(parents=True, exist_ok=True)
    package = directory / 'Package.swift'
    package.write_text('// swift-tools-version: 6.2\nimport PackageDescription\n\n'
                       'let package = Package(\n    name: "DocumentationFixture",\n'
                       + snippet + '\n)\n')
    artifact = directory / 'dump-package.json'
    artifact.unlink(missing_ok=True)
    result = subprocess.run(['swift', 'package', '--package-path', str(directory), 'dump-package'],
                            cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{file}, Swift fence {number}: dump-package failed ({result.returncode})\n'
                           + result.stdout + result.stderr)
    json.loads(result.stdout)
    artifact.write_text(result.stdout)
    return dict(manifest_file=str(package.relative_to(ROOT)),
                dump_package_file=str(artifact.relative_to(ROOT)))


imports = {'import Foundation', 'import PipelineKit', 'import PipelineKitSecurity',
           'import PipelineKitCache', 'import PipelineKitResilience', 'import PipelineKitObservability'}
parts = []
manifest = []
manifest_path = ROOT / '.build/validation/example-manifest.json'
manifest_path.unlink(missing_ok=True)
for file in FILES:
    body = (ROOT / file).read_text()
    all_fences = FENCE.findall(body)
    if file in WALKTHROUGHS:
        bodies = []
        for number, snippet in enumerate(all_fences, 1):
            entry = dict(file=file, swift_fence=number,
                snippet_sha256=hashlib.sha256(snippet.encode()).hexdigest(), conditional_platform=None)
            if MANIFEST_FRAGMENT.match(snippet):
                entry.update(validate_manifest_fragment(file, number, snippet))
                entry['harness'] = 'exact body as Package initializer arguments; swift package dump-package'
            else:
                imports.update(re.findall(r'^import [^\n]+', snippet, flags=re.M))
                bodies.append(f'// {file}, Swift fence {number}\n'
                              + re.sub(r'^import [^\n]+\n', '', snippet, flags=re.M))
                entry['harness'] = ('imports hoisted; exact remaining body, in document order, '
                                    'inside one shared @MainActor async throws function')
            manifest.append(entry)
        name = re.sub('[^a-zA-Z0-9]', '_', file)
        parts.append(f'@MainActor func compiled_{name}() async throws {{\n' + '\n'.join(bodies) + '\n}\n\n')
        continue
    old = subprocess.run(['git', 'show', f'{BASELINE}:{file}'], cwd=ROOT,
                         text=True, capture_output=True)
    old_fences = FENCE.findall(old.stdout) if old.returncode == 0 else []
    selected = {number for number, snippet in enumerate(all_fences, 1)
                if file in EVERY_FENCE or snippet not in old_fences}
    security_group = {}
    if file == 'docs/guides/security-best-practices.md':
        related = {number: snippet for number, snippet in enumerate(all_fences, 1)
                   if any(re.search(pattern, snippet) for pattern in SECURITY_COMPOSITION_DEFINITIONS)}
        if selected.intersection(related):
            if not all(any(re.search(pattern, snippet) for snippet in related.values())
                       for pattern in SECURITY_COMPOSITION_DEFINITIONS):
                raise ValueError('security composition examples require all middleware definitions and registration')
            security_group = related
            selected.update(related)
    for number, snippet in enumerate(all_fences, 1):
        if number not in selected:
            continue
        entry = dict(file=file, swift_fence=number,
            snippet_sha256=hashlib.sha256(snippet.encode()).hexdigest(),
            conditional_platform='canImport(Compression)' if '#if canImport(Compression)' in snippet else None)
        if MANIFEST_FRAGMENT.match(snippet):
            entry.update(validate_manifest_fragment(file, number, snippet))
            entry['harness'] = 'exact body as Package initializer arguments; swift package dump-package'
            manifest.append(entry)
            continue
        imports.update(re.findall(r'^import [^\n]+', snippet, flags=re.M))
        prefix = f'// {file}, Swift fence {number}\n'
        if number in security_group:
            if number == min(security_group):
                grouped = ''.join(
                    f'// {file}, Swift fence {group_number}\n'
                    + re.sub(r'^import [^\n]+\n', '', group_snippet, flags=re.M) + '\n'
                    for group_number, group_snippet in security_group.items()
                )
                parts.append('@MainActor func compiled_security_composition() async throws {\n'
                             + grouped + '\n}\n\n')
            harness = 'imports hoisted; exact remaining body inside shared security composition @MainActor async throws function'
        elif any(re.search(pattern, snippet) for pattern in FILE_SCOPE_DEFINITIONS.get(file, ())):
            generated = re.sub(r'^import [^\n]+\n', '', snippet, flags=re.M)
            harness = 'imports hoisted; exact remaining definitions at file scope for the executable consumer'
        else:
            generated = re.sub(r'^import [^\n]+\n', '', snippet, flags=re.M)
            name = re.sub('[^a-zA-Z0-9]', '_', file)
            generated = f'@MainActor func compiled_{name}_{number}() async throws {{\n' + generated + '\n}\n'
            harness = 'imports hoisted; exact remaining body inside separate @MainActor async throws function'
        if number not in security_group:
            parts.append(prefix + generated + '\n')
        entry['harness'] = harness
        manifest.append(entry)
output = ROOT / 'Tests/Integration/Consumer/Sources/Consumer/CompiledExamples.swift'
header = '// Generated by Scripts/validation/extract_stabilization_examples.py; edit the source documentation.\n'
header += '\n'.join(sorted(imports)) + '\n\n'
output.write_text(header + ''.join(parts))
record = dict(baseline=BASELINE, source='exact current documentation Swift fences',
              generated_file=str(output.relative_to(ROOT)),
              generated_sha256=hashlib.sha256(output.read_bytes()).hexdigest(), snippets=manifest)
manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest_path.write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps(dict(snippets=len(manifest), output=str(output.relative_to(ROOT)))))
