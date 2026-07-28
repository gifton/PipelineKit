#!/bin/bash
# Builds the complete DocC site for GitHub Pages: all seven public modules
# in one combined archive (swift-docc-plugin >= 1.4 combined documentation).
# Usage: Scripts/build-docs-site.sh <output-dir>
set -euo pipefail

OUTPUT="${1:?usage: build-docs-site.sh <output-dir>}"

swift package --allow-writing-to-directory "$OUTPUT" \
  generate-documentation \
  --target PipelineKit \
  --target PipelineKitCore \
  --target PipelineKitSecurity \
  --target PipelineKitResilience \
  --target PipelineKitCache \
  --target PipelineKitPooling \
  --target PipelineKitObservability \
  --enable-experimental-combined-documentation \
  --output-path "$OUTPUT" \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path PipelineKit
