#!/bin/zsh
set -euo pipefail
paper_project_root="$(cd "$(dirname "$0")/.." && pwd)"
paper_test_dir="$(mktemp -d /tmp/aoistitcher-paper-tests.XXXXXX)"
trap 'rm -rf "$paper_test_dir"' EXIT

# Only isolated library data and undisplayed native views are used. The source
# recorder never starts the interactive system drag loop or posts mouse events.
cat > "$paper_test_dir/PaperLibraryTestMain.swift" <<'SWIFT'
import AppKit

@main struct PaperLibraryTestMain {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let libraryChecks = try await PaperLibraryRegressionTests.run()
        print("Paper library: \(libraryChecks) checks passed")
        let dragChecks = try await PaperLibraryDragInteractionTests.run()
        print("Paper native drag interaction: \(dragChecks) checks passed")
    }
}
SWIFT

xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -target "$(uname -m)-apple-macos14.6" \
    "$paper_project_root/AoiStitcher/PaperLibrary.swift" \
    "$paper_project_root/AoiStitcher/PaperLibraryDragInteraction.swift" \
    "$paper_project_root/Tests/PaperLibraryRegressionTests.swift" \
    "$paper_project_root/Tests/PaperLibraryDragInteractionTests.swift" \
    "$paper_test_dir/PaperLibraryTestMain.swift" \
    -o "$paper_test_dir/paper-library-tests"
"$paper_test_dir/paper-library-tests"
