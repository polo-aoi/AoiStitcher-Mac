#!/bin/zsh
set -euo pipefail
canvas_project_root="$(cd "$(dirname "$0")/.." && pwd)"
canvas_build_root="$(mktemp -d /tmp/aoipic-universal.XXXXXX)"
canvas_output_root="${1:-$canvas_project_root/../导出/aoipic-3.2.2}"
trap 'rm -rf "$canvas_build_root"' EXIT
xcodebuild -project "$canvas_project_root/AoiStitcher.xcodeproj" \
    -scheme AoiStitcher -configuration Release -derivedDataPath "$canvas_build_root" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=NO build
mkdir -p "$canvas_output_root"
if [[ -e "$canvas_output_root/aoipic.app" ]]; then
    canvas_previous_root="$(mktemp -d "$canvas_output_root/previous-build.XXXXXX")"
    mv "$canvas_output_root/aoipic.app" "$canvas_previous_root/aoipic.app"
    print -r -- "保留上一份构建：$canvas_previous_root/aoipic.app"
fi
ditto "$canvas_build_root/Build/Products/Release/aoipic.app" "$canvas_output_root/aoipic.app"
codesign --force --sign - "$canvas_output_root/aoipic.app"
codesign --verify --strict "$canvas_output_root/aoipic.app"
lipo -archs "$canvas_output_root/aoipic.app/Contents/MacOS/aoipic"
print -r -- "本地通用 App：$canvas_output_root/aoipic.app"
