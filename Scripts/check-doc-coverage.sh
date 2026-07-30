#!/bin/bash
# Per-target DocC documentation-coverage gate.
# Floors are a RATCHET measured from reality (docs Tier 2, 2026-07): the gate
# fails when coverage drops below a recorded floor. Raise a floor when
# coverage improves; never set one above measured reality.
set -euo pipefail

SCRATCH="${1:-.build/doc-coverage}"
TARGETS="PipelineKit PipelineKitCore PipelineKitSecurity PipelineKitResilience PipelineKitCache PipelineKitPooling PipelineKitObservability"

# swift-docc-plugin moves each .doccarchive into place; it will not create a
# missing parent directory (fails with "the folder containing latter doesn't
# exist" on a fresh scratch dir, e.g. this gate's first-ever CI run).
mkdir -p "$SCRATCH"

for TARGET in $TARGETS; do
  echo "Generating coverage data for $TARGET..."
  swift package --allow-writing-to-directory "$SCRATCH/$TARGET" \
    generate-documentation --target "$TARGET" \
    --experimental-documentation-coverage \
    --output-path "$SCRATCH/$TARGET" > /dev/null
done

python3 - "$SCRATCH" <<'EOF'
import json, sys, pathlib

# Floors measured on the docs-tier2 branch after the Tier 2 doc fill.
# A record counts as documented when it has an abstract.
# PipelineKitResilience defines no symbols of its own (its public API arrives
# via @_exported re-exports from internal targets; see
# Sources/PipelineKitResilience/PipelineKitResilience.swift), so its archive
# contains only the module record itself.
THRESHOLDS = {
    "PipelineKit": 68.4,
    "PipelineKitCore": 57.5,
    "PipelineKitSecurity": 63.5,
    "PipelineKitResilience": 0.0,
    "PipelineKitCache": 60.5,
    "PipelineKitPooling": 56.9,
    "PipelineKitObservability": 61.2,
}

scratch = pathlib.Path(sys.argv[1])
failed = False
for target, floor in THRESHOLDS.items():
    path = scratch / target / "documentation-coverage.json"
    records = json.loads(path.read_text())
    total = len(records)
    documented = sum(1 for r in records if isinstance(r, dict) and r.get("hasAbstract"))
    pct = 100.0 * documented / total if total else 0.0
    status = "OK  " if pct >= floor else "FAIL"
    if pct < floor:
        failed = True
    print(f"{status} {target}: {documented}/{total} = {pct:.1f}% (floor {floor}%)")
if failed:
    print("\nDocumentation coverage fell below a recorded floor.")
    print("Document the new or changed public API, or (with reviewer sign-off)")
    print("adjust the floor in Scripts/check-doc-coverage.sh.")
    sys.exit(1)
EOF
