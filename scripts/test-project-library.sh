#!/bin/zsh
set -euo pipefail
library_project_root="$(cd "$(dirname "$0")/.." && pwd)"
library_test_dir="$(mktemp -d /tmp/aoistitcher-library-tests.XXXXXX)"
trap 'rm -rf "$library_test_dir"' EXIT

# Compile the source graph, then run data, rendering, SwiftUI layout and native toolbar regressions.
# Toolbar checks create an undisplayed window; nothing captures the screen or touches the real library.
cat > "$library_test_dir/ProjectLibraryTestMain.swift" <<'SWIFT'
import Foundation

@main struct ProjectLibraryTestMain {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let checks = try await ProjectLibraryRegressionTests.run()
        print("Project library: \(checks) checks passed")
        let sourceChecks = try await ProjectSourceLocationRegressionTests.run()
        print("Project source locations: \(sourceChecks) checks passed")
        let orderingChecks = try ProjectHomeOrderingRegressionTests.run()
        print("Project home ordering: \(orderingChecks) checks passed")
        let gridChecks = try ProjectMaterialGridRegressionTests.run()
        print("Material grid: \(gridChecks) checks passed")
        let groupChecks = try ProjectPhotoGroupInteractionTests.run()
        print("Photo group interaction: \(groupChecks) checks passed")
        let blankChecks = try await ProjectGroupBlankSelectionTests.run()
        print("Group blank selection: \(blankChecks) checks passed")
        let blankDropChecks = try await ProjectGroupBlankDropTests.run()
        print("Group blank drop: \(blankDropChecks) checks passed")
        let transferChecks = try ProjectPhotoTransferRegressionTests.run()
        print("Photo transfers: \(transferChecks) checks passed")
        let selectionChecks = try ProjectMaterialSelectionRegressionTests.run()
        print("Material selection: \(selectionChecks) checks passed")
        let layoutChecks = try ProjectPhotoGroupLayoutRegressionTests.run()
        print("Photo group layout: \(layoutChecks) checks passed")
        let thumbnailChecks = try await ProjectThumbnailCacheRegressionTests.run()
        print("Thumbnail cache: \(thumbnailChecks) checks passed")
        let renderingChecks = try ProjectThumbnailRenderingRegressionTests.run()
        print("Thumbnail rendering: \(renderingChecks) checks passed")
        let scopeChecks = try await ProjectThumbnailScopeRegressionTests.run()
        print("Thumbnail scoped updates: \(scopeChecks) checks passed")
        let preferenceChecks = try PreferencesRegressionTests.run()
        print("Preferences: \(preferenceChecks) checks passed")
        let navigationChecks = try ProjectWindowNavigationRegressionTests.run()
        print("Window navigation: \(navigationChecks) checks passed")
    }
}
SWIFT

library_sources=("$library_project_root"/AoiStitcher/**/*.swift)
library_sources=("${(@)library_sources:#*/AoiStitcherApp.swift}")
# The unused Xcode SwiftData template requires a macro plug-in in standalone swiftc.
library_sources=("${(@)library_sources:#*/Item.swift}")
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
    "$library_project_root/Tests/ProjectSourceLocationRegressionTests.swift" \
    "$library_project_root/Tests/ProjectHomeOrderingRegressionTests.swift" \
    "$library_project_root/Tests/ProjectMaterialGridRegressionTests.swift" \
    "$library_project_root/Tests/ProjectPhotoGroupInteractionTests.swift" \
    "$library_project_root/Tests/ProjectGroupBlankSelectionTests.swift" \
    "$library_project_root/Tests/ProjectGroupBlankDropTests.swift" \
    "$library_project_root/Tests/ProjectPhotoTransferRegressionTests.swift" \
    "$library_project_root/Tests/ProjectMaterialSelectionRegressionTests.swift" \
    "$library_project_root/Tests/ProjectPhotoGroupLayoutRegressionTests.swift" \
    "$library_project_root/Tests/ProjectThumbnailCacheRegressionTests.swift" \
    "$library_project_root/Tests/ProjectThumbnailRenderingRegressionTests.swift" \
    "$library_project_root/Tests/ProjectThumbnailScopeRegressionTests.swift" \
    "$library_project_root/Tests/PreferencesRegressionTests.swift" \
    "$library_project_root/Tests/ProjectWindowNavigationRegressionTests.swift" \
    "$library_test_dir/ProjectLibraryTestMain.swift" \
    -o "$library_test_dir/project-library-tests"
"$library_test_dir/project-library-tests"
