#!/usr/bin/env python3
"""Recheck I01's enumerated source/audit hashes before controller acceptance.

Run from the stabilization worktree. Controller acceptance can later change
CLOSURE; this record deliberately describes the pre-acceptance I01 boundary.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[5]
execution = root / "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization"
base = "a6979832b0665aaf6b6769e9d16fa0cd044442c6"
original = Path("/Users/goftin/dev/gsuite/PipelineKit")

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def git(*args):
    return subprocess.check_output(["git", *args], cwd=root)

start = json.loads((execution / "reports/I01-original-preservation.json").read_text())
manifest_path = original / "audit/pipelinekit/2026-10-28-a93a713-local/baseline-manifest.json"
assert digest(manifest_path) == start["manifest_sha256"]
manifest = json.loads(manifest_path.read_text())
baseline_mismatches = [entry["path"] for entry in manifest["files"]
    if digest(original / entry["path"]) != entry["source_identity"].removeprefix("sha256:")]
assert not baseline_mismatches, baseline_mismatches
artifacts = start["audit_artifact_hashes"]
audit_mismatches = {str(tree): [name for name, expected in artifacts.items()
    if digest(tree / name) != expected] for tree in (original, root)}
assert not any(audit_mismatches.values()), audit_mismatches
guide_hashes = {str(tree): digest(tree / "docs/PIPELINEKIT_AUDIT_GUIDE.md") for tree in (original, root)}
assert all(value == start["guide_sha256"] for value in guide_hashes.values())
final_source = json.loads((execution / "reports/I01-final-source.json").read_text())
source_mismatches = [name for name, expected in final_source["files"].items() if digest(root / name) != expected]
assert not source_mismatches, source_mismatches
protected = {}
for relative in (
    "docs/superpowers/plans/2026-10-29-pipelinekit-stabilization-scope.json",
    "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/CLOSURE.md",
    "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/DECISIONS.md",
    "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer/Package.resolved",
):
    current = (root / relative).read_bytes()
    assert current == git("show", base + ":" + relative), relative
    protected[relative] = hashlib.sha256(current).hexdigest()
rulings = re.findall(r"^([0-9]+)\. ", (execution / "DECISIONS.md").read_text(), re.M)
assert rulings == [str(i) for i in range(1, 20)], rulings
unchanged_groups = ["Sources", "Tests", "Package.swift", "Package.resolved", ".github", "Scripts", "Examples"]
assert not git("diff", base, "--", *unchanged_groups), "Unexpected production/test/settings change in I01"
assert digest(execution / "repros/run_check.py") == final_source["runner_sha256"]
original_status = git("--no-optional-locks", "--git-dir", str(original / ".git"),
    "--work-tree", str(original), "status", "--porcelain", "--untracked-files=no").decode()
assert not original_status, original_status
record = {
    "checked_utc": datetime.now(timezone.utc).isoformat(),
    "implementation_head": git("rev-parse", "HEAD").decode().strip(),
    "i01_base": base,
    "original_baseline_files_checked": len(manifest["files"]),
    "baseline_mismatches": baseline_mismatches,
    "historical_artifacts_checked_per_tree": len(artifacts),
    "audit_mismatches": audit_mismatches,
    "guide_hashes": guide_hashes,
    "final_source_files_checked": len(final_source["files"]),
    "source_mismatches": source_mismatches,
    "protected_files_unchanged_from_i01_base": protected,
    "chronological_rulings_unchanged": len(rulings),
    "unchanged_production_test_setting_groups": unchanged_groups,
    "runner_sha256": final_source["runner_sha256"],
    "original_checkout_tracked_status": original_status,
    "limitations": "Enumerated hashes at the stated time, not an invented historical state for unrecorded files. SDD progress was not edited by I01; no initial hash was recorded for controller-owned scratch progress.",
}
(execution / "reports/I01-preservation-end.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps({key: value for key, value in record.items() if key not in ("protected_files_unchanged_from_i01_base", "guide_hashes")}, indent=2))
