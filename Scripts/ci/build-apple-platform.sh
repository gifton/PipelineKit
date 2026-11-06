#!/bin/bash
set -euo pipefail
destination="${1:?usage: build-apple-platform.sh destination configuration}"
configuration="${2:?usage: build-apple-platform.sh destination configuration}"
xcodebuild \
  -scheme PipelineKit-Package \
  -destination "$destination" \
  -configuration "$configuration" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build | xcpretty
