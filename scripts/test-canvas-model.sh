#!/bin/zsh
set -euo pipefail
canvas_project_root="$(cd "$(dirname "$0")/.." && pwd)"
canvas_test_dir="$(mktemp -d /tmp/aoistitcher-canvas-model.XXXXXX)"
trap 'rm -rf "$canvas_test_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -target "$(uname -m)-apple-macos14.6" \
    "$canvas_project_root/AoiStitcher/CanvasModel.swift" \
    "$canvas_project_root/AoiStitcher/CanvasRenderer.swift" \
    "$canvas_project_root/AoiStitcher/StitchModels.swift" \
    "$canvas_project_root/AoiStitcher/ProjectImportMode.swift" \
    "$canvas_project_root/Tests/CanvasModelRegressionTests.swift" \
    -o "$canvas_test_dir/canvas-model-tests"
"$canvas_test_dir/canvas-model-tests"
