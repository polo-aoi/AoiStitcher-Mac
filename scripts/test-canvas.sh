#!/bin/zsh
set -euo pipefail
canvas_project_root="$(cd "$(dirname "$0")/.." && pwd)"
canvas_test_dir="$(mktemp -d /tmp/aoistitcher-canvas-tests.XXXXXX)"
trap 'rm -rf "$canvas_test_dir"' EXIT
# Workspace preferences share UI models with the project library. Include the
# production source graph, omitting only the app entry point used by this harness.
canvas_sources=("$canvas_project_root"/AoiStitcher/**/*.swift)
canvas_sources=("${(@)canvas_sources:#*/AoiStitcherApp.swift}")
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -target "$(uname -m)-apple-macos14.6" \
    "${canvas_sources[@]}" \
    "$canvas_project_root/Tests/CanvasRegressionTests.swift" \
    "$canvas_project_root/Tests/CropRegressionTests.swift" \
    "$canvas_project_root/Tests/PreferencesRegressionTests.swift" \
    "$canvas_project_root/Tests/ProjectLibraryRegressionTests.swift" \
    "$canvas_project_root/Tests/PaperLibraryRegressionTests.swift" \
    -o "$canvas_test_dir/canvas-tests"
"$canvas_test_dir/canvas-tests"
