#!/bin/zsh
set -euo pipefail
library_project_root="$(cd "$(dirname "$0")/.." && pwd)"
library_test_dir="$(mktemp -d /tmp/aoistitcher-library-tests.XXXXXX)"
trap 'rm -rf "$library_test_dir"' EXIT

# Compile the source graph for integration checks, then run only data regressions.
# This runner never starts NSApplication, creates windows or touches the real library.
cat > "$library_test_dir/ProjectLibraryTestMain.swift" <<'SWIFT'
import Foundation

@main struct ProjectLibraryTestMain {
    @MainActor static func main() async throws {
        let checks = try await ProjectLibraryRegressionTests.run()
        print("Project library: \(checks) checks passed")
        let gridChecks = try ProjectMaterialGridRegressionTests.run()
        print("Material grid: \(gridChecks) checks passed")
    }
}
SWIFT

library_sources=("$library_project_root"/AoiStitcher/**/*.swift)
library_sources=("${(@)library_sources:#*/AoiStitcherApp.swift}")
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -target "$(uname -m)-apple-macos14.6" \
    "${library_sources[@]}" \
    "$library_project_root/Tests/ProjectLibraryRegressionTests.swift" \
    "$library_project_root/Tests/ProjectMaterialGridRegressionTests.swift" \
    "$library_test_dir/ProjectLibraryTestMain.swift" \
    -o "$library_test_dir/project-library-tests"
"$library_test_dir/project-library-tests"
