#!/bin/zsh
set -euo pipefail
canvas_project_root="$(cd "$(dirname "$0")/.." && pwd)"
canvas_test_dir="$(mktemp -d /tmp/aoistitcher-canvas-tests.XXXXXX)"
trap 'rm -rf "$canvas_test_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -target "$(uname -m)-apple-macos14.6" \
    "$canvas_project_root/AoiStitcher/StitchModels.swift" \
    "$canvas_project_root/AoiStitcher/CanvasModel.swift" \
    "$canvas_project_root/AoiStitcher/CanvasRenderer.swift" \
    "$canvas_project_root/AoiStitcher/CanvasWorkspace.swift" \
    "$canvas_project_root/AoiStitcher/CanvasLayersList.swift" \
    "$canvas_project_root/AoiStitcher/CropModel.swift" \
    "$canvas_project_root/AoiStitcher/CropEditorView.swift" \
    "$canvas_project_root/AoiStitcher/EditorComponents.swift" \
    "$canvas_project_root/AoiStitcher/AppPreferences.swift" \
    "$canvas_project_root/AoiStitcher/AppSettingsView.swift" \
    "$canvas_project_root/Tests/CanvasRegressionTests.swift" \
    "$canvas_project_root/Tests/CropRegressionTests.swift" \
    "$canvas_project_root/Tests/PreferencesRegressionTests.swift" \
    -o "$canvas_test_dir/canvas-tests"
"$canvas_test_dir/canvas-tests"
