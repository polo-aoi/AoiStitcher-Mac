import AppKit
import Combine
import SwiftUI

/// Real asynchronous previews in two SwiftUI subtrees. Synthetic originals and
/// all disk caches live in a disposable directory; no window is displayed.
@MainActor enum ProjectThumbnailScopeRegressionTests {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectThumbnailScopeRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aoi-thumbnail-scope-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ProjectAsset(id: UUID(), fileName: "red.png", name: "red.png", position: .zero)
        let groupID = UUID()
        let second = ProjectAsset(id: UUID(), fileName: "green.png", name: "green.png",
                                  position: .zero, groupID: groupID)
        let offscreen = ProjectAsset(id: UUID(), fileName: "yellow.png", name: "yellow.png", position: .zero)
        let document = ProjectDocument(id: UUID(), name: "Scoped thumbnails", createdAt: Date(), modifiedAt: Date(),
                                       assets: [first, second, offscreen], exports: [], thumbnailSize: 128,
                                       groups: [ProjectPhotoGroup(id: groupID, assetIDs: [second.id])])
        let project = root.appendingPathComponent(document.id.uuidString, isDirectory: true)
        let originals = project.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: project.appendingPathComponent("project.json"))
        try writePNG(.red, to: originals.appendingPathComponent(first.fileName))
        try writePNG(.green, to: originals.appendingPathComponent(second.fileName))
        try writePNG(.yellow, to: originals.appendingPathComponent(offscreen.fileName))
        let library = ProjectLibraryStore(projectsDirectory: root)
        library.openProject(id: document.id)
        let recorder = ThumbnailScopeRecorder()
        let host = NSHostingView(rootView: ThumbnailScopesFixture(library: library,
                              first: first, second: second, recorder: recorder))
        host.frame = CGRect(x: 0, y: 0, width: 720, height: 176)
        host.layoutSubtreeIfNeeded()
        let initialParentBuilds = recorder.parentBuilds
        var completedIDs: Set<UUID> = []
        let completion = library.thumbnailUpdates.completed.sink { completedIDs.formUnion($0) }
        defer { completion.cancel() }

        func settle() async throws {
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            host.layoutSubtreeIfNeeded()
        }
        func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            try check(condition(), message)
            try await settle()
        }

        try await waitUntil("Both visible scopes receive decoded thumbnails") {
            recorder.latestImages[0] != nil && recorder.latestImages[1] != nil &&
                completedIDs.isSuperset(of: [first.id, second.id])
        }
        try check(recorder.reportedIDs[0] == [first.id] && recorder.reportedIDs[1] == [second.id],
                  "Real grid and group boards asynchronously report their own visible assets")
        try check(recorder.parentBuilds == initialParentBuilds,
                  "Visible-ID reports and thumbnail completions do not rebuild the parent workspace")
        try check(recorder.latestImages[0].map { color(of: $0) == .red } == true &&
                  recorder.latestImages[1].map { color(of: $0) == .green } == true,
                  "Each scope receives the actual decoded image belonging to its visible asset")
        try await waitUntil("Visible photos automatically reach their display resolution after scrolling settles") {
            recorder.latestImages.allSatisfy { image in
                image.map { library.isThumbnail($0, sufficientForDisplayPixelSize: 128) } == true
            }
        }
        try check(recorder.latestImages.allSatisfy { $0.map { pixelSize(of: $0) == 192 } == true },
                  "Small offscreen thumbnails use the small tier instead of decoding unnecessary 1080-pixel images: pixels \(recorder.latestImages.map { $0.map { pixelSize(of: $0) } }), demands \(recorder.demands)")

        let boards = descendants(of: host).compactMap { $0 as? ProjectMaterialDocumentView }
        try check(boards.count == 2, "Both scopes contain a real native photo board")
        for board in boards {
            try check(coloredPixels(in: board, matching: board.isGroupRow ? .green : .red) > 1_000,
                      "The \(board.isGroupRow ? "group" : "material") board actually draws its thumbnail pixels")
        }

        let baselineBuilds = recorder.scopeBuilds
        let baselineParentBuilds = recorder.parentBuilds
        _ = library.thumbnail(for: offscreen)
        try await waitUntil("An offscreen asset finishes its real background decode") {
            completedIDs.contains(offscreen.id)
        }
        try check(recorder.scopeBuilds == baselineBuilds && recorder.parentBuilds == baselineParentBuilds,
                  "Unrelated asset completion does not rebuild either visible scope or the parent")
        library.thumbnailUpdates.invalidate([first.id])
        try await settle()
        try check(recorder.scopeBuilds[1] == baselineBuilds[1] && recorder.parentBuilds == baselineParentBuilds,
                  "A first-scope completion does not rebuild the second scope or the workspace")
        try check(recorder.scopeBuilds[0] == baselineBuilds[0],
                  "Repeated completion with the same image does not publish a redundant redraw")

        var replacement = first
        replacement.contentRevision = UUID()
        try writePNG(.blue, to: originals.appendingPathComponent(first.fileName))
        let recordStart = recorder.records.count
        host.rootView = ThumbnailScopesFixture(library: library, first: replacement,
                                                second: second, recorder: recorder)
        try await waitUntil("Replacing the original loads a new thumbnail for the same asset identity") {
            recorder.latestImages[0].map { color(of: $0) == .blue } == true
        }
        let replacementRecords = recorder.records.dropFirst(recordStart).filter {
            $0.scope == 0 && $0.revision == replacement.contentRevision
        }
        try check(!replacementRecords.isEmpty && replacementRecords.allSatisfy { $0.color != .red },
                  "A new content revision never receives the previous original's image, even before onChange runs")
        try check(recorder.latestImages[1].map { color(of: $0) == .green } == true,
                  "Replacing one original preserves the other scope's image")
        if let grid = descendants(of: host).compactMap({ $0 as? ProjectMaterialDocumentView }).first(where: { !$0.isGroupRow }) {
            try check(coloredPixels(in: grid, matching: .blue) > 1_000,
                      "The material board draws the replacement pixels after the revision changes")
        }
        var hiddenReplacement = replacement
        hiddenReplacement.contentRevision = UUID()
        try writePNG(.red, to: originals.appendingPathComponent(first.fileName))
        let hiddenRecordStart = recorder.records.count
        host.rootView = ThumbnailScopesFixture(library: library, first: hiddenReplacement,
                                                second: second, recorder: recorder, isActive: false)
        try await settle()
        try check(recorder.latestImages[0] == nil,
                  "An inactive workspace discards a replaced original without starting new loading")
        host.rootView = ThumbnailScopesFixture(library: library, first: hiddenReplacement,
                                                second: second, recorder: recorder)
        try await waitUntil("Returning to the workspace loads its current original") {
            recorder.latestImages[0].map { color(of: $0) == .red } == true
        }
        try check(recorder.records.dropFirst(hiddenRecordStart).filter {
            $0.scope == 0 && $0.revision == hiddenReplacement.contentRevision
        }.allSatisfy { $0.color != .blue },
                  "Reactivation never labels a previously cached image as the new original")

        let upgradeStart = recorder.records.count
        host.rootView = ThumbnailScopesFixture(library: library, first: hiddenReplacement,
                                                second: second, recorder: recorder, firstSize: 240)
        try await waitUntil("Enlarging the material viewport automatically requests a sharper tier") {
            recorder.latestImages[0].map { pixelSize(of: $0) >= 384 } == true
        }
        try check(recorder.records.dropFirst(upgradeStart).filter { $0.scope == 0 }.allSatisfy { $0.color == .red },
                  "An adaptive resolution upgrade keeps existing pixels present instead of flashing a placeholder")
        try check(recorder.demands[0]?.maximumPixelSize == 240 &&
                  recorder.demands[0]?.visibleIDs == [first.id],
                  "The native offscreen board reports its actual display size and visible photo")
        let sharp = recorder.latestImages[0]!
        host.rootView = ThumbnailScopesFixture(library: library, first: hiddenReplacement,
                                                second: second, recorder: recorder, firstSize: 48)
        try await settle()
        try check(recorder.latestImages[0] === sharp,
                  "Shrinking the grid reuses the sharper cached image without decoding or downgrading")
        try check(host.window == nil, "Thumbnail scope tests never create or display a window")
        return checks
    }

    fileprivate enum SampleColor { case red, green, blue, yellow, other }

    private static func writePNG(_ color: NSColor, to url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 640,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        CGRect(x: 0, y: 0, width: 640, height: 640).fill()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    fileprivate static func color(of image: NSImage) -> SampleColor {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .other }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return classify(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
    }

    private static func pixelSize(of image: NSImage) -> Int {
        // NSCGImageSnapshotRep reports screen-scaled representation dimensions
        // on Retina even when its underlying bitmap has fewer actual pixels.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        return max(cg.width, cg.height)
    }

    private static func classify(_ value: NSColor?) -> SampleColor {
        guard let color = value?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.8 else { return .other }
        let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
        if r > 0.7 && g < 0.2 && b < 0.2 { return .red }
        if g > 0.7 && r < 0.2 && b < 0.2 { return .green }
        if b > 0.7 && r < 0.2 && g < 0.2 { return .blue }
        if r > 0.7 && g > 0.7 && b < 0.2 { return .yellow }
        return .other
    }

    private static func coloredPixels(in board: ProjectMaterialDocumentView, matching color: SampleColor) -> Int {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(board.bounds.width),
                                     pixelsHigh: Int(board.bounds.height), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        board.draw(board.bounds)
        NSGraphicsContext.restoreGraphicsState()
        var result = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where classify(bitmap.colorAt(x: x, y: y)) == color { result += 1 }
        }
        return result
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor private final class ThumbnailScopeRecorder {
    struct Record {
        let scope: Int
        let revision: UUID?
        let color: ProjectThumbnailScopeRegressionTests.SampleColor?
    }
    var parentBuilds = 0
    var scopeBuilds = [0, 0]
    var reportedIDs: [Set<UUID>] = [[], []]
    var latestImages: [NSImage?] = [nil, nil]
    var records: [Record] = []
    var demands: [ProjectThumbnailDemand?] = [nil, nil]
}

@MainActor private struct ThumbnailScopesFixture: View {
    @ObservedObject var library: ProjectLibraryStore
    let first: ProjectAsset
    let second: ProjectAsset
    let recorder: ThumbnailScopeRecorder
    var isActive = true
    var firstSize: CGFloat = 128

    var body: some View {
        let _ = recorder.parentBuilds += 1
        HStack(spacing: 8) {
            scope(first, index: 0)
            scope(second, index: 1)
        }
    }

    private func scope(_ asset: ProjectAsset, index: Int) -> some View {
        ProjectThumbnailRefresh(library: library, assets: [asset], isActive: isActive) { images, reportVisible in
            let _ = record(images, asset: asset, index: index)
            ProjectMaterialBoard(assets: [asset], selection: .constant([]), thumbnailSize: index == 0 ? firstSize : 128,
                viewZoom: .constant(1), fitRequest: 0, thumbnails: images, badges: [:],
                onMove: { _ in }, onImport: { _, _ in }, onActivate: { _ in },
                onThumbnailDemand: { demand in
                    recorder.reportedIDs[index] = demand.assetIDs
                    recorder.demands[index] = demand
                    reportVisible(demand)
                },
                isGroupRow: index == 1, groupDragID: asset.groupID)
        }
    }

    private func record(_ images: [UUID: NSImage], asset: ProjectAsset, index: Int) {
        recorder.scopeBuilds[index] += 1
        recorder.latestImages[index] = images[asset.id]
        recorder.records.append(.init(scope: index, revision: asset.contentRevision,
            color: images[asset.id].map { ProjectThumbnailScopeRegressionTests.color(of: $0) }))
    }
}
