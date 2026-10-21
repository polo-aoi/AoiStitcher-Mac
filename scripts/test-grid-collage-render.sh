#!/bin/zsh
set -euo pipefail
grid_project_root="$(cd "$(dirname "$0")/.." && pwd)"
grid_test_dir="$(mktemp -d /tmp/aoipic-grid-render-tests.XXXXXX)"
trap 'rm -rf "$grid_test_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -target "$(uname -m)-apple-macos14.6" \
    "$grid_project_root/AoiStitcher/GridCollageModel.swift" \
    "$grid_project_root/AoiStitcher/GridCollageRenderer.swift" \
    "$grid_project_root/Tests/GridCollageRenderTests.swift" \
    -o "$grid_test_dir/grid-render-tests"
"$grid_test_dir/grid-render-tests"
