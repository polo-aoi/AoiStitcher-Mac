#!/bin/zsh
set -euo pipefail
compression_root="$(cd "$(dirname "$0")/.." && pwd)"
compression_output="${1:-$(mktemp -d /tmp/aoipic-compression-tests.XXXXXX)}"
mkdir -p "$compression_output"
compression_core="$compression_root/AoiStitcher/Compression/Core"
xcrun swiftc -swift-version 5 -default-isolation MainActor -O \
    -target "$(uname -m)-apple-macos14.6" \
    "$compression_core/OutputSharpening.swift" "$compression_core/ImagePipeline.swift" \
    "$compression_root/Tests/Compression/main.swift" -o "$compression_output/pipeline-tests"
"$compression_output/pipeline-tests" "$compression_root" "$compression_output/pipeline"
compression_sources=("$compression_root"/AoiStitcher/**/*.swift)
compression_sources=("${(@)compression_sources:#*/AoiStitcherApp.swift}")
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -O \
    -target "$(uname -m)-apple-macos14.6" \
    "${compression_sources[@]}" \
    "$compression_root/Tests/CompressionWorkspaceTests.swift" -o "$compression_output/workspace-tests"
"$compression_output/workspace-tests" "$compression_root" "$compression_output/workspace"
