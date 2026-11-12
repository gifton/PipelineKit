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

# DocC leaves the site root without a page. Send it to the module list.
cat > "$OUTPUT/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>PipelineKit documentation</title>
<meta http-equiv="refresh" content="0; url=documentation/">
<link rel="canonical" href="documentation/">
<a href="documentation/">PipelineKit documentation</a>
HTML
