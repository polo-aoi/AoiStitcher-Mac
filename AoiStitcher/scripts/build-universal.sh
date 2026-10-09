#!/bin/zsh
set -euo pipefail
canvas_project_root="$(cd "$(dirname "$0")/.." && pwd)"
canvas_build_root="$(mktemp -d /tmp/aoistitcher-universal.XXXXXX)"
canvas_output_root="${1:-$canvas_project_root/../导出/AoiStitcher-3.0}"
trap 'rm -rf "$canvas_build_root"' EXIT
xcodebuild -project "$canvas_project_root/AoiStitcher.xcodeproj" \
    -scheme AoiStitcher -configuration Release -derivedDataPath "$canvas_build_root" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=NO build
mkdir -p "$canvas_output_root"
ditto "$canvas_build_root/Build/Products/Release/AoiStitcher.app" "$canvas_output_root/AoiStitcher.app"
lipo -archs "$canvas_output_root/AoiStitcher.app/Contents/MacOS/AoiStitcher"
print -r -- "本地通用 App：$canvas_output_root/AoiStitcher.app"
