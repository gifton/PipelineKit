#!/bin/bash
set -euo pipefail
compiler_version=$(swift --version)
printf '%s\n' "$compiler_version"
if ! [[ "$compiler_version" =~ Swift\ version\ 6\.2(\.|[[:space:]]|$) ]]; then
    echo "Compiler-floor qualification requires Swift 6.2.x" >&2
    exit 1
fi
for configuration in debug release; do
    swift build --configuration "$configuration" --build-tests -Xswiftc -enable-testing
    swift build --package-path Tests/Integration/Consumer --configuration "$configuration" --build-tests
done
