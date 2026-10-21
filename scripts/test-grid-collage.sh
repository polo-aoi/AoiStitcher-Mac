#!/bin/zsh
set -euo pipefail
grid_project_root="$(cd "$(dirname "$0")/.." && pwd)"
grid_test_dir="$(mktemp -d /tmp/aoipic-grid-model-tests.XXXXXX)"
trap 'rmdir "$grid_test_dir" 2>/dev/null || true' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -target "$(uname -m)-apple-macos14.6" \
    "$grid_project_root/AoiStitcher/StitchModels.swift" \
    "$grid_project_root/AoiStitcher/GridCollageModel.swift" \
    "$grid_project_root/AoiStitcher/GridCollageTemplates.swift" \
    "$grid_project_root/AoiStitcher/GridCollageStore.swift" \
    "$grid_project_root/Tests/GridCollageModelTests.swift" \
    -o "$grid_test_dir/grid-model-tests"
"$grid_test_dir/grid-model-tests"
unlink "$grid_test_dir/grid-model-tests"
