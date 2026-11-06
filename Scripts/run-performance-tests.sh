#!/bin/bash
# Checked Release measurements with explicit JSON baseline support.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/benchmarks/run.py" "$@"
