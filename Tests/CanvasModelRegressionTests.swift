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
        withExtendedLifetime(observation) {}
        print("PASS: \(checks) canvas model checks (transform commit, history, import conflicts, rendering)")
    }
}
