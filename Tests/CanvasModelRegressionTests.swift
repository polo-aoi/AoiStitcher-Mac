import AppKit
import Combine

/// Data-only coverage for the native viewport's one-shot transform commit.
/// Does not create an application, window or view.
@main struct CanvasModelRegressionTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), name)
            checks += 1
        }
        let store = CanvasStore()
        var layer = CanvasLayer(name: "fixture", kind: .photo,
                                center: CGPoint(x: 200, y: 100),
                                size: CGSize(width: 100, height: 80))
        store.mutate { $0.layers = [layer] }
        store.selectedID = layer.id
        var publications = 0
        let observation = store.$document.dropFirst().sink { _ in publications += 1 }
        let revision = store.documentRevision
        let history = store.undoCount
        layer.center = CGPoint(x: 250, y: 150)
        layer.size = CGSize(width: 200, height: 160)
        layer.rotation = 45
        check(store.commitTransform(layer, expectedRevision: revision), "Transform is committed")
        check(publications == 1, "Transform publishes the document once")
        check(store.documentRevision == revision + 1, "Transform has one revision")
        check(store.undoCount == history + 1, "Transform has one undo step")
        check(store.selectedLayer?.center == layer.center && store.selectedLayer?.size == layer.size && store.selectedLayer?.rotation == 45,
              "Final geometry is preserved")
        let committedRevision = store.documentRevision
        store.undo()
        check(store.selectedLayer?.center == CGPoint(x: 200, y: 100), "Undo restores drag origin")
        check(!store.commitTransform(layer, expectedRevision: committedRevision), "An unfinished drag cannot overwrite undo")
        check(store.redoCount == 1, "Rejected stale drag preserves redo")
        store.redo()
        check(store.selectedLayer?.center == layer.center, "Redo restores drag result")
        let noOpRevision = store.documentRevision
        let noOpHistory = store.undoCount
        check(!store.commitTransform(layer, expectedRevision: noOpRevision), "No-op produces no edit")
        check(store.documentRevision == noOpRevision && store.undoCount == noOpHistory, "No-op keeps revision and history")
        layer.center.x += 10
        check(!store.commitTransform(layer, expectedRevision: revision), "Stale drag cannot overwrite later edits")
        store.toggleLock(layer.id)
        check(!store.commitTransform(layer, expectedRevision: store.documentRevision), "Locked layer cannot be transformed")
        store.toggleLock(layer.id)
        var invalid = layer
        invalid.size.width = .nan
        check(!store.commitTransform(invalid, expectedRevision: store.documentRevision), "Nonfinite size is rejected")
        invalid = layer; invalid.size.height = 0
        check(!store.commitTransform(invalid, expectedRevision: store.documentRevision), "Zero size is rejected")
        invalid = layer; invalid.center.x = .infinity
        check(!store.commitTransform(invalid, expectedRevision: store.documentRevision), "Nonfinite position is rejected")

        let renderLayer = CanvasLayer(name: "edge", kind: .paper, center: CGPoint(x: 0, y: 100),
                                      size: CGSize(width: 150, height: 80), rotation: 45, color: CanvasColor(.red))
        let snapshot = CanvasRenderSnapshot(CanvasDocument(size: CGSize(width: 200, height: 200), layers: [renderLayer]))
        let image = try CanvasRenderer.makeImage(snapshot, width: 200)
        check(image.width == 200 && image.height == 200, "Culling retains export dimensions")
        let bytes = image.dataProvider!.data! as Data
        let index = 100 * image.bytesPerRow + 20 * 4
        check(bytes[index] > 200 && bytes[index + 1] < 50, "Partially visible rotated layer remains rendered")

        let beforeImport = store.documentRevision
        store.addLoadedImages([CanvasLoadedImage(url: URL(fileURLWithPath: "/tmp/canvas-transform-fixture.png"),
                                                image: image, preview: image)], as: .photo)
        let importedID = store.selectedID
        let afterImportHistory = store.undoCount
        check(!store.commitTransform(layer, expectedRevision: beforeImport), "Import invalidates an unfinished drag")
        check(store.photoCount == 2 && store.selectedID == importedID && store.undoCount == afterImportHistory,
              "Rejected drag preserves imported photo, selection and undo history")
        store.undo()
        check(store.photoCount == 1, "Import remains a single undo step")
        store.clear()
        check(!store.commitTransform(layer, expectedRevision: store.documentRevision), "Deleted layer cannot be resurrected")

        let layoutStore = CanvasStore()
        func fixtureImage(width: Int, height: Int) -> CGImage {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let smallPhoto = fixtureImage(width: 60, height: 40)
        let largePhoto = fixtureImage(width: 600, height: 400)
        let portraitPhoto = fixtureImage(width: 40, height: 60)
        let photos = [smallPhoto, largePhoto, portraitPhoto].enumerated().map { index, image in
            CanvasLayer(name: "Photo \(index)", kind: .photo, image: image,
                        center: CGPoint(x: 90 + index * 40, y: 100),
                        size: CGSize(width: image.width, height: image.height), rotation: 12)
        }
        layoutStore.mutate { $0.layers = photos }
        layoutStore.arrange(horizontal: true, margin: 40, gap: 24, split: 0.2)
        var arranged = layoutStore.document.layers
        func near(_ first: CGFloat, _ second: CGFloat) -> Bool { abs(first - second) < 0.00001 }
        check(arranged[0].size == arranged[1].size,
              "Matching aspect ratios produce the same display size regardless of pixel resolution or legacy split")
        check(arranged.allSatisfy { near($0.size.height, arranged[0].size.height) && $0.rotation == 0 },
              "Horizontal arrangement makes every photo equally tall and straight")
        check(near(arranged[2].size.width / arranged[2].size.height, 2 / 3),
              "Mixed portrait photos preserve their aspect ratio")
        for index in 1..<arranged.count {
            let previousRight = arranged[index - 1].center.x + arranged[index - 1].size.width / 2
            let currentLeft = arranged[index].center.x - arranged[index].size.width / 2
            check(near(currentLeft - previousRight, 24), "Horizontal spacing measures visible photo edges")
        }
        check(layoutStore.document.size == CGSize(width: 800, height: 600)
              && arranged.allSatisfy { $0.center.x - $0.size.width / 2 >= 39.999
                  && $0.center.x + $0.size.width / 2 <= 760.001
                  && $0.center.y - $0.size.height / 2 >= 39.999
                  && $0.center.y + $0.size.height / 2 <= 560.001 },
              "A multi-photo layout fits inside the existing canvas and minimum margins")
        let arrangedState = layoutStore.document.arrangement
        let gapHistory = layoutStore.undoCount
        layoutStore.beginContinuousChange()
        layoutStore.updateArrangement(gap: 30)
        layoutStore.updateArrangement(gap: 60)
        layoutStore.endContinuousChange()
        check(layoutStore.undoCount == gapHistory + 1 && layoutStore.document.arrangement?.gap == 60,
              "A live spacing gesture creates one undo entry")
        layoutStore.undo()
        check(layoutStore.document.arrangement == arrangedState && layoutStore.document.layers[0].size == arranged[0].size,
              "Undo restores both spacing controls and photo geometry")
        layoutStore.redo()
        check(layoutStore.document.arrangement?.gap == 60, "Redo restores the adjusted layout spacing")

        layoutStore.arrange(horizontal: false, margin: 40, gap: 18)
        arranged = layoutStore.document.layers
        check(arranged.allSatisfy { near($0.size.width, arranged[0].size.width) },
              "Vertical arrangement makes every photo equally wide")
        for index in 1..<arranged.count {
            let previousBottom = arranged[index - 1].center.y + arranged[index - 1].size.height / 2
            let currentTop = arranged[index].center.y - arranged[index].size.height / 2
            check(near(currentTop - previousBottom, 18), "Vertical spacing measures visible photo edges")
        }
        layoutStore.updateArrangement(gap: .greatestFiniteMagnitude)
        check(layoutStore.document.arrangement?.gap == layoutStore.maximumArrangementGap
              && layoutStore.document.layers.allSatisfy { $0.size.width > 0 && $0.size.height > 0 },
              "Spacing clamps safely while leaving every photo a positive size")
        layoutStore.editLayer(photos[0].id) { $0.center.x += 10 }
        check(layoutStore.document.arrangement == nil, "Manual photo movement suspends automatic arrangement")
        let manualRevision = layoutStore.documentRevision
        layoutStore.updateArrangement(gap: 10)
        check(layoutStore.documentRevision == manualRevision,
              "Spacing controls cannot overwrite a manually arranged composition")
        layoutStore.undo()
        check(layoutStore.document.arrangement != nil, "Undoing a manual move restores automatic arrangement")

        let beforePaperArrangement = layoutStore.document.arrangement
        check(layoutStore.usePaperColor(CanvasColor(.red), name: "Red"), "A library color creates a paper layer")
        let firstPaper = layoutStore.selectedLayer!
        let paperHistory = layoutStore.undoCount
        check(firstPaper.kind == .paper && firstPaper.size == layoutStore.document.size,
              "A new color paper covers the complete canvas")
        check(layoutStore.document.arrangement == beforePaperArrangement,
              "Choosing a paper leaves the photo layout active")
        layoutStore.selectedID = photos[0].id
        check(layoutStore.usePaperColor(CanvasColor(.blue), name: "Blue") && layoutStore.paperCount == 1
              && layoutStore.selectedID == firstPaper.id, "Single-click paper use replaces the background without accumulating layers")
        check(layoutStore.document.layers.first?.color == CanvasColor(.blue)
              && layoutStore.document.layers.dropFirst().map(\.id) == photos.map(\.id),
              "Replacing paper preserves all photos and keeps papers below them")
        layoutStore.undo()
        check(layoutStore.paperCount == 1 && layoutStore.document.layers.first?.color == CanvasColor(.red)
              && layoutStore.undoCount == paperHistory, "Undo restores the previous paper in one step")
        layoutStore.toggleLock(firstPaper.id)
        let lockedPaperRevision = layoutStore.documentRevision
        check(!layoutStore.usePaperColor(CanvasColor(.green), name: "Green")
              && layoutStore.documentRevision == lockedPaperRevision, "A locked background cannot be silently replaced")
        check(layoutStore.usePaperColor(.white, name: "Overlay", addingLayer: true) && layoutStore.paperCount == 2,
              "An explicit additional paper action creates a separate layer")
        layoutStore.toggleLock(photos[0].id)
        check(layoutStore.document.arrangement == nil, "Changing photo lock membership suspends automatic arrangement")
        let lockedPhotoBefore = layoutStore.document.layers.first { $0.id == photos[0].id }!
        layoutStore.arrange(horizontal: true, margin: 40, gap: 24)
        let lockedPhoto = layoutStore.document.layers.first { $0.id == photos[0].id }!
        check(lockedPhoto.center == lockedPhotoBefore.center && lockedPhoto.size == lockedPhotoBefore.size
              && lockedPhoto.rotation == lockedPhotoBefore.rotation,
              "Locked photographs remain excluded from automatic arrangement")
        let unlockedBefore = layoutStore.document.layers.first { $0.id == photos[1].id }!.center
        layoutStore.resizeCanvas(CGSize(width: 1000, height: 600))
        check(layoutStore.document.arrangement == nil
              && layoutStore.document.layers.first(where: { $0.id == photos[1].id })?.center != unlockedBefore,
              "Changing the canvas dimensions suspends layout until a direction is selected again")

        let libraryID = UUID()
        let associationStore = CanvasStore()
        check(associationStore.usePaperColor(.white, name: "Linked color", libraryID: libraryID)
              && associationStore.selectedLayer?.paperLibraryID == libraryID,
              "Applying a library paper records its stable source identity")
        check(associationStore.usePaperColor(.white, name: "Local color")
              && associationStore.selectedLayer?.paperLibraryID == nil,
              "Replacing a linked paper with a local paper clears the old association")

        let syncStore = CanvasStore()
        let background = CanvasLayer(name: "Library paper", kind: .paper, image: smallPhoto, previewImage: smallPhoto,
                                     center: CGPoint(x: 400, y: 300), size: CGSize(width: 900, height: 600),
                                     opacity: 0.8, locked: true, paperLibraryID: libraryID)
        let placedPaper = CanvasLayer(name: "Library paper", kind: .paper, image: smallPhoto, previewImage: smallPhoto,
                                      center: CGPoint(x: 120, y: 230), size: CGSize(width: 240, height: 160),
                                      rotation: 25, opacity: 0.45, paperLibraryID: libraryID)
        let unlinkedPaper = CanvasLayer(name: "Library paper", kind: .paper, image: smallPhoto, previewImage: smallPhoto,
                                        center: CGPoint(x: 240, y: 220), size: CGSize(width: 120, height: 80))
        let differentPaper = CanvasLayer(name: "Library paper", kind: .paper, image: smallPhoto, previewImage: smallPhoto,
                                         center: CGPoint(x: 340, y: 220), size: CGSize(width: 120, height: 80),
                                         paperLibraryID: UUID())
        let linkedPhoto = CanvasLayer(name: "Photo", kind: .photo, image: smallPhoto, previewImage: smallPhoto,
                                      center: CGPoint(x: 400, y: 300), size: CGSize(width: 120, height: 80),
                                      paperLibraryID: libraryID)
        syncStore.mutate { $0.layers = [background, placedPaper, unlinkedPaper, differentPaper, linkedPhoto] }
        syncStore.arrange(horizontal: true, margin: 40, gap: 24)
        syncStore.selectedID = linkedPhoto.id
        syncStore.editLayer(placedPaper.id) { $0.center.x += 50 }
        syncStore.editLayer(placedPaper.id) { $0.center.y += 30 }
        syncStore.undo()
        let beforeRefresh = syncStore.document
        let inactiveStore = CanvasStore()
        inactiveStore.mutate { $0 = beforeRefresh }
        let refreshHistory = syncStore.undoCount
        let refreshRedo = syncStore.redoCount
        let refreshRevision = syncStore.documentRevision
        syncStore.refreshPaperLibraryImage(id: libraryID, name: "Cropped paper", image: portraitPhoto, preview: portraitPhoto)
        let refreshed = syncStore.document.layers
        check(syncStore.undoCount == refreshHistory && syncStore.redoCount == refreshRedo
              && syncStore.documentRevision == refreshRevision + 1,
              "Refreshing linked resources publishes once without adding or clearing canvas history")
        check(refreshed.map(\.id) == beforeRefresh.layers.map(\.id)
              && syncStore.selectedID == linkedPhoto.id && syncStore.document.arrangement == beforeRefresh.arrangement,
              "Library refresh preserves layer count, order, selection and the active photo arrangement")
        check(refreshed[0].image === portraitPhoto && refreshed[1].image === portraitPhoto
              && refreshed[0].previewImage === portraitPhoto && refreshed[1].previewImage === portraitPhoto
              && refreshed[0].name == "Cropped paper" && refreshed[1].name == "Cropped paper",
              "All instances of the same library paper receive the saved image, preview and name")
        check(refreshed[0].size == CGSize(width: 800, height: 1200)
              && refreshed[0].center == background.center && refreshed[0].locked
              && refreshed[0].opacity == background.opacity && refreshed[0].rotation == background.rotation,
              "A locked centered background keeps covering the canvas after its source aspect changes")
        check(refreshed[1].size == CGSize(width: 240, height: 360)
              && refreshed[1].center == beforeRefresh.layers[1].center && refreshed[1].rotation == placedPaper.rotation
              && refreshed[1].opacity == placedPaper.opacity && refreshed[1].locked == placedPaper.locked,
              "A manually positioned paper keeps its width and placement while adopting the new aspect ratio")
        check(refreshed[2].image === smallPhoto && refreshed[2].size == unlinkedPaper.size
              && refreshed[3].image === smallPhoto && refreshed[3].size == differentPaper.size,
              "Matching filenames or old image contents do not refresh unlinked or differently linked papers")
        check(refreshed[4].image === smallPhoto && refreshed[4].previewImage === smallPhoto
              && refreshed[4].center == beforeRefresh.layers[4].center
              && refreshed[4].size == beforeRefresh.layers[4].size && refreshed[4].name == linkedPhoto.name,
              "Library paper refresh never edits a photo layer")
        check(inactiveStore.document.layers[0].image === smallPhoto
              && inactiveStore.document.layers[0].size == background.size,
              "Refreshing the active canvas does not mutate another canvas using the same library source")
        let unmatchedRevision = syncStore.documentRevision
        let unmatchedHistory = syncStore.undoCount
        syncStore.refreshPaperLibraryImage(id: UUID(), name: "Unused paper", image: largePhoto, preview: largePhoto)
        check(syncStore.documentRevision == unmatchedRevision && syncStore.undoCount == unmatchedHistory,
              "An unused library source causes no canvas update or undo entry")
        syncStore.undo()
        check(syncStore.document.layers[0].image === portraitPhoto && syncStore.document.layers[1].image === portraitPhoto
              && syncStore.document.layers[0].previewImage === portraitPhoto
              && syncStore.document.layers[0].name == "Cropped paper"
              && syncStore.document.layers[0].size == CGSize(width: 800, height: 1200)
              && syncStore.document.layers[1].size == CGSize(width: 240, height: 360)
              && syncStore.document.layers[1].center == placedPaper.center
              && syncStore.document.layers[0].paperLibraryID == libraryID,
              "Canvas undo restores placement while retaining the permanently cropped resource and its new aspect")
        syncStore.redo()
        check(syncStore.document.layers[0].image === portraitPhoto
              && syncStore.document.layers[0].size == CGSize(width: 800, height: 1200)
              && syncStore.document.layers[1].size == CGSize(width: 240, height: 360)
              && syncStore.document.layers[1].center == beforeRefresh.layers[1].center,
              "Canvas redo restores placement without reviving the original paper pixels")
        syncStore.redo()
        check(syncStore.document.layers[1].image === portraitPhoto
              && syncStore.document.layers[1].size == CGSize(width: 240, height: 360)
              && syncStore.document.layers[1].center == CGPoint(x: 170, y: 260),
              "A redo entry that existed before the library save also uses the cropped resource")

        let deletedPaperStore = CanvasStore()
        var smallerBackground = background
        smallerBackground.center = CGPoint(x: 300, y: 200)
        smallerBackground.size = CGSize(width: 600, height: 400)
        smallerBackground.locked = false
        deletedPaperStore.mutate { $0 = CanvasDocument(size: CGSize(width: 600, height: 400), layers: [smallerBackground]) }
        deletedPaperStore.selectedID = smallerBackground.id
        deletedPaperStore.deleteSelected()
        let deletedRevision = deletedPaperStore.documentRevision
        let deletedHistory = deletedPaperStore.undoCount
        deletedPaperStore.refreshPaperLibraryImage(id: libraryID, name: "Cropped paper",
                                                   image: portraitPhoto, preview: portraitPhoto)
        check(deletedPaperStore.document.layers.isEmpty && deletedPaperStore.documentRevision == deletedRevision
              && deletedPaperStore.undoCount == deletedHistory,
              "Refreshing a source present only in history neither adds layers nor publishes an unchanged canvas")
        deletedPaperStore.undo()
        check(deletedPaperStore.document.layers[0].image === portraitPhoto
              && deletedPaperStore.document.layers[0].size == CGSize(width: 600, height: 900)
              && deletedPaperStore.document.layers[0].center == smallerBackground.center,
              "Undoing a deletion uses the new image and fits the historical canvas dimensions")
        withExtendedLifetime(observation) {}
        print("PASS: \(checks) canvas model checks (transforms, arrangement, paper application, library refresh, history, rendering)")
    }
}
