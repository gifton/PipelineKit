#!/bin/bash
# A floor lane's evidence is the host OS it ran on. Fail when the runner is not the
# macOS major version the lane names, so a relabelled or migrated image cannot pass
# as the floor. Covered by test_platform_qualification.py (FloorHostTests).
set -euo pipefail
expected="${1:?usage: check-floor-host.sh macos-major-version}"
actual=$(sw_vers -productVersion)
printf 'Host macOS: %s\n' "$actual"
swift --version
xcodebuild -version
if [[ "${actual%%.*}" != "$expected" ]]; then
    echo "Floor lane requires a macOS ${expected}.x host; this host runs macOS ${actual}" >&2
    exit 1
fi
