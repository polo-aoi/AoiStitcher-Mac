import AppKit
import ImageIO

@main struct CanvasRegressionTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError("FAIL: " + description) }
            checks += 1
        }
        let image = fixture()
        let assets = (0..<3).map { index in
            CanvasLoadedImage(url: URL(fileURLWithPath: "/tmp/photo-\(index).png"), image: image, preview: image)
        }
        let store = CanvasStore()
        store.addLoadedImages(Array(assets.prefix(2)), as: .photo)
        check(store.photoCount == 2, "Multiple photos are imported in input order")
        check(store.document.layers[0].center.x < store.document.layers[1].center.x, "Initial two-photo layout is horizontal")
        let initial = store.document.layers
        store.arrange(horizontal: false, margin: 40, gap: 20, split: 0.35)
        check(store.document.layers[0].center.y < store.document.layers[1].center.y, "Vertical layout orders photos top to bottom")
        check(store.document.layers.allSatisfy { abs($0.size.width / $0.size.height - 1) < 0.001 }, "Quick layouts preserve photo aspect")
        store.undo()
        check(store.document.layers[0].center == initial[0].center, "Undo restores the previous layout")
        store.redo()
        check(store.document.layers[0].center.y < store.document.layers[1].center.y, "Redo restores the vertical layout")
        store.addLoadedImages([assets[2]], as: .photo)
        check(store.photoCount == 3, "A third photo can be added")
        store.arrange(horizontal: true, margin: 40, gap: 24, split: 0.5)
        check(store.document.layers[0].center.x < store.document.layers[1].center.x &&
              store.document.layers[1].center.x < store.document.layers[2].center.x, "Three-photo quick layout stays in order")
        store.selectedID = store.document.layers[1].id
        let layerID = store.selectedID!
        let before = store.selectedLayer!.center
        store.beginContinuousChange()
        store.editSelected { $0.center.x += 20 }
        store.editSelected { $0.center.y += 30 }
        store.endContinuousChange()
        store.undo()
        check(store.selectedLayer!.center == before, "An entire drag is one undo step")
        store.toggleLock(layerID)
        store.editSelected { $0.center.x = 900 }
        store.deleteSelected()
        check(store.selectedLayer!.center == before && store.photoCount == 3, "Locked photos cannot move or be deleted")
        store.arrange(horizontal: false, margin: 40, gap: 24, split: 0.5)
        check(store.selectedLayer!.center == before, "Quick layout leaves locked photos in place")
        store.toggleLock(layerID)
        store.centerSelected()
        check(store.selectedLayer!.center == CGPoint(x: 400, y: 300), "Center uses the canvas center")
        store.fitSelected(fill: true)
        check(store.selectedLayer!.size.width >= 800 && store.selectedLayer!.size.height >= 600, "Fill covers the entire canvas")
        store.duplicateSelected()
        check(store.photoCount == 4 && store.selectedID != layerID, "Duplicate has a new identity")
        store.addPaper(.fiber)
        check(store.document.layers.first!.kind == .paper && store.selectedLayer!.texture != nil, "Paper is inserted behind photos")
        store.editSelected { $0.rotation = 27; $0.center.x -= 100 }
        let paper = store.selectedLayer!
        store.arrange(horizontal: true, margin: 40, gap: 24, split: 0.5)
        check(store.selectedLayer!.center == paper.center && store.selectedLayer!.rotation == 27, "Photo layouts do not rearrange paper")
        store.clear()
        store.undo()
        check(store.photoCount == 4 && store.document.layers.count == 5, "Clearing the canvas can be undone")
        store.resizeCanvas(CGSize(width: 1200, height: 800))
        check(store.document.size == CGSize(width: 1200, height: 800), "Custom canvas dimensions are applied")
        let point = CGPoint(x: 12, y: 35), center = CGPoint(x: 150, y: 200)
        let rotated = CanvasGeometry.worldPoint(point, center: center, rotation: 31)
        let inverse = CanvasGeometry.localPoint(rotated, center: center, rotation: 31)
        check(hypot(point.x - inverse.x, point.y - inverse.y) < 0.001, "Rotated hit testing returns the original local point")

        // A four-row source with red at the top and blue at the bottom detects flipped exports.
        var doc = CanvasDocument()
        doc.size = CGSize(width: 200, height: 200)
        doc.layers = [CanvasLayer(name: "Orientation", kind: .photo, image: image, previewImage: image,
                                  center: CGPoint(x: 100, y: 100), size: doc.size)]
        let snapshot = CanvasRenderSnapshot(doc)
        let output = try CanvasRenderer.makeImage(snapshot, width: 200)
        check(pixel(output, x: 100, y: 20).r > 240 && pixel(output, x: 100, y: 20).b < 20, "Photo top remains at the top in export")
        check(pixel(output, x: 100, y: 180).b > 240 && pixel(output, x: 100, y: 180).r < 20, "Photo bottom remains at the bottom in export")
        var previewDoc = doc
        previewDoc.layers[0].center = CGPoint(x: 160, y: 100)
        previewDoc.layers[0].rotation = 90
        let shifted = try CanvasRenderer.makeImage(CanvasRenderSnapshot(previewDoc, preview: true), width: 200)
        check(pixel(shifted, x: 20, y: 100).r > 240 && pixel(shifted, x: 20, y: 100).g > 240, "A moved photo exposes the canvas background")
        let exported = try CanvasRenderer.makeImage(CanvasRenderSnapshot(previewDoc), width: 200)
        check(pixel(shifted, x: 140, y: 80) == pixel(exported, x: 140, y: 80), "Preview and export agree on rotated geometry")
        doc.layers.append(CanvasLayer(name: "Red paper", kind: .paper, center: CGPoint(x: 100, y: 100),
                                      size: CGSize(width: 80, height: 80), color: CanvasColor(.red)))
        let overlay = try CanvasRenderer.makeImage(CanvasRenderSnapshot(doc), width: 200)
        check(pixel(overlay, x: 100, y: 120).r > 240 && pixel(overlay, x: 100, y: 120).b < 20, "Top layer covers lower layers")
        doc.layers[1].opacity = 0.5
        let blended = try CanvasRenderer.makeImage(CanvasRenderSnapshot(doc), width: 200)
        check((115...140).contains(pixel(blended, x: 100, y: 120).r) &&
              (115...140).contains(pixel(blended, x: 100, y: 120).b), "Layer opacity blends the two images")
        let size = try CanvasRenderer.outputSize(for: CanvasRenderSnapshot(store.document), width: 2400)
        check(size == CGSize(width: 2400, height: 1600), "Export size follows canvas aspect ratio")
        do {
            _ = try CanvasRenderer.makeImage(snapshot, width: 0)
            fatalError("Invalid export width was accepted")
        } catch CanvasExportError.invalidSize { checks += 1 }
        do {
            _ = try CanvasRenderer.outputSize(for: snapshot, width: 16384)
            fatalError("Excessive bitmap size was accepted")
        } catch CanvasExportError.tooLarge { checks += 1 }
        for style in CanvasPaperStyle.allCases where style != .plain {
            check(CanvasImageLoader.paperTexture(style) != nil, "Built-in paper texture exists")
        }
        let directory = URL(fileURLWithPath: "/tmp/aoistitcher-canvas-regression", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = directory.appendingPathComponent("canvas.png")
        let jpeg = directory.appendingPathComponent("canvas.jpg")
        try CanvasRenderer.export(snapshot, width: 200, png: true, to: png)
        try CanvasRenderer.export(snapshot, width: 200, png: false, to: jpeg)
        let pngBytes = try Data(contentsOf: png), jpegBytes = try Data(contentsOf: jpeg)
        check(Array(pngBytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10], "PNG choice writes PNG bytes")
        check(Array(jpegBytes.prefix(2)) == [255, 216], "JPEG choice writes JPEG bytes")
        check(CanvasImageLoader.load(png)?.image.width == 200, "Exported PNG can be imported again")
        checks += testWorkspace(image)
        checks += testLayerOrdering(image)
        checks += testLayersList(image)
        checks += testCanvasOrientation(image)
        checks += try CropRegressionTests.run()
        checks += PreferencesRegressionTests.run()
        print("PASS: \(checks) canvas and crop checks (layouts, history, layers, keyboard, rotation, crop geometry, native gestures, source quality, PNG/JPEG)")
    }

    @MainActor private static func testWorkspace(_ image: CGImage) -> Int {
        // Call our own view's event handlers in a hidden test window. No system input is posted.
        _ = NSApplication.shared
        let store = CanvasStore()
        let layer = CanvasLayer(name: "Drag fixture", kind: .photo, image: image,
                                center: CGPoint(x: 400, y: 300), size: CGSize(width: 300, height: 200))
        store.mutate { $0.layers = [layer] }
        let view = CanvasWorkspaceView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; view.store = store
        view.snapshot = CanvasRenderSnapshot(store.document, preview: true)
        let scale: CGFloat = 1.125
        let origin = CGPoint(x: 50, y: 62.5)
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            let local = CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
            return NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil),
                                      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func drag(from start: CGPoint, to end: CGPoint) {
            view.mouseDown(with: event(.leftMouseDown, at: start))
            view.mouseDragged(with: event(.leftMouseDragged, at: end))
            view.mouseUp(with: event(.leftMouseUp, at: end))
            view.snapshot = CanvasRenderSnapshot(store.document, preview: true)
        }
        func require(_ condition: Bool, _ description: String) {
            if !condition { fatalError("FAIL: " + description) }
        }
        let history = store.undoCount
        var inspected: UUID?
        view.onInspect = { inspected = $0.id }
        drag(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 450, y: 320))
        require(store.selectedLayer!.center == CGPoint(x: 450, y: 320), "Mouse drag moves in canvas coordinates")
        require(inspected == nil, "Left-clicking and dragging do not open parameters")
        require(store.undoCount == history + 1, "Mouse drag records exactly one undo step")
        store.editSelected { $0.rotation = 30 }
        let initial = store.selectedLayer!
        let anchor = CanvasGeometry.worldPoint(CGPoint(x: -150, y: -100), center: initial.center, rotation: 30)
        let corner = CanvasGeometry.worldPoint(CGPoint(x: 150, y: 100), center: initial.center, rotation: 30)
        let target = CanvasGeometry.worldPoint(CGPoint(x: 400, y: 400 / 1.5), center: anchor, rotation: 30)
        drag(from: corner, to: target)
        let resized = store.selectedLayer!
        require(abs(resized.size.width - 400) < 0.01 && abs(resized.size.height - 400 / 1.5) < 0.01,
                "Rotated corner resize preserves aspect ratio")
        let newAnchor = CanvasGeometry.worldPoint(CGPoint(x: -resized.size.width / 2, y: -resized.size.height / 2),
                                                 center: resized.center, rotation: resized.rotation)
        require(hypot(newAnchor.x - anchor.x, newAnchor.y - anchor.y) < 0.01, "Opposite corner stays fixed while resizing")
        let handleLocal = CGPoint(x: 0, y: -resized.size.height / 2 - 26 / scale)
        let rotationStart = CanvasGeometry.worldPoint(handleLocal, center: resized.center, rotation: resized.rotation)
        let rotationEnd = CanvasGeometry.worldPoint(handleLocal, center: resized.center, rotation: resized.rotation + 90)
        drag(from: rotationStart, to: rotationEnd)
        require(abs(store.selectedLayer!.rotation - 120) < 0.01, "Rotation handle adds the dragged angle")
        store.toggleLock(layer.id)
        let lockedCenter = store.selectedLayer!.center
        drag(from: lockedCenter, to: CGPoint(x: lockedCenter.x + 20, y: lockedCenter.y + 20))
        require(store.selectedLayer!.center == lockedCenter, "Locked material ignores mouse dragging")
        view.rightMouseDown(with: event(.rightMouseDown, at: lockedCenter))
        require(inspected == layer.id, "Right-click opens the hit material's parameters, including locked materials")
        inspected = nil
        view.rightMouseDown(with: event(.rightMouseDown, at: CGPoint(x: 10, y: 10)))
        require(inspected == nil, "Right-clicking empty canvas does not open parameters")
        window.close()
        return 9
    }

    @MainActor private static func testLayerOrdering(_ image: CGImage) -> Int {
        var checks = 0
        func check(_ condition: Bool, _ description: String) {
            if !condition { fatalError("FAIL: " + description) }
            checks += 1
        }
        let store = CanvasStore()
        let layers = (0..<4).map { index in
            CanvasLayer(name: "Layer \(index)", kind: index == 0 ? .paper : .photo, image: image,
                        center: CGPoint(x: 100 + index * 20, y: 150), size: CGSize(width: 120, height: 80), rotation: 13)
        }
        store.mutate { $0.layers = layers }
        func order() -> [UUID] { Array(store.document.layers.reversed()).map(\.id) }
        let original = order()
        let history = store.undoCount
        check(store.moveLayer(layers[0].id, toListInsertionIndex: 0), "Bottom material moves to the first list row")
        check(order() == [layers[0].id, layers[3].id, layers[2].id, layers[1].id], "Top-to-bottom rows match paint order after moving up")
        check(store.document.layers.last!.id == layers[0].id, "First list row paints in front, even for paper")
        check(store.undoCount == history + 1 && store.selectedID == layers[0].id, "One reorder is one undo step and keeps the dragged material selected")
        check(store.selectedLayer!.center == layers[0].center && store.selectedLayer!.rotation == 13,
              "Reordering does not change material geometry")
        store.undo()
        check(order() == original, "Undo restores the complete original stack")
        store.redo()
        check(order().first == layers[0].id, "Redo restores the moved layer")
        check(store.moveLayer(layers[0].id, toListInsertionIndex: 4) && order().last == layers[0].id,
              "Top material can move below the last row")
        check(store.moveLayer(layers[3].id, toListInsertionIndex: 3) &&
              order() == [layers[2].id, layers[1].id, layers[3].id, layers[0].id], "Moving down compensates for removal of the source row")
        check(store.moveLayer(layers[0].id, toListInsertionIndex: 1) &&
              order() == [layers[2].id, layers[0].id, layers[1].id, layers[3].id], "Moving up inserts in the requested middle gap")
        let noOpHistory = store.undoCount
        check(!store.moveLayer(layers[0].id, toListInsertionIndex: 1) &&
              !store.moveLayer(layers[0].id, toListInsertionIndex: 2) && store.undoCount == noOpHistory,
              "Dropping on either side of the same row does not add undo steps")
        check(!store.moveLayer(UUID(), toListInsertionIndex: 1) &&
              !store.moveLayer(layers[0].id, toListInsertionIndex: -1) &&
              !store.moveLayer(layers[0].id, toListInsertionIndex: 5), "Invalid drag IDs and gaps are rejected")
        store.toggleLock(layers[0].id)
        let lockedOrder = order(), lockedHistory = store.undoCount
        check(!store.moveLayer(layers[0].id, toListInsertionIndex: 0) &&
              order() == lockedOrder && store.undoCount == lockedHistory, "Locked materials cannot be reordered")
        return checks
    }

    @MainActor private static func testLayersList(_ image: CGImage) -> Int {
        var checks = 0
        func check(_ condition: Bool, _ description: String) {
            if !condition { fatalError("FAIL: " + description) }
            checks += 1
        }
        let store = CanvasStore()
        let layers = (0..<3).map { index in
            CanvasLayer(name: "List \(index)", kind: .photo, previewImage: image,
                        center: CGPoint(x: 400, y: 300), size: CGSize(width: 200, height: 100))
        }
        store.mutate { $0.layers = layers }
        let table = CanvasLayersTableView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        let window = NSWindow(contentRect: table.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = table
        table.store = store
        table.refresh()
        var inspected: UUID?
        table.onInspect = { inspected = $0.id }
        check(table.numberOfRows == 3, "All material rows are present")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        check(store.selectedID == layers[1].id && inspected == nil, "Selecting a material row only selects, without opening parameters")
        func click(_ type: NSEvent.EventType, row: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            let rect = table.rect(ofRow: row)
            return NSEvent.mouseEvent(with: type, location: table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil),
                                      modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        table.rightMouseDown(with: click(.rightMouseDown, row: 0))
        check(store.selectedID == layers[2].id && inspected == layers[2].id,
              "Right-clicking a different row selects it and opens only its parameters")
        inspected = nil
        table.mouseDown(with: click(.leftMouseDown, row: 2, modifiers: .control))
        check(inspected == layers[0].id, "Control-click is equivalent to right-click in the list")
        store.toggleLock(layers[0].id)
        table.refresh()
        check(table.tableView(table, pasteboardWriterForRow: 2) == nil, "Locked rows do not start a layer drag")
        let writer = table.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem
        check(writer?.string(forType: CanvasLayersTableView.layerPasteboardType) == layers[2].id.uuidString,
              "A layer drag carries its stable material identity")
        store.selectedID = layers[2].id
        table.refresh()
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                  isARepeat: false, keyCode: 125)!
        table.keyDown(with: key)
        check(store.document.layers[1].id == layers[2].id && table.selectedRow == 1,
              "Keyboard layer reorder keeps the moved row selected")
        func historyKey(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                             isARepeat: false, keyCode: 6)!
        }
        table.keyDown(with: historyKey(.command))
        check(store.document.layers.last!.id == layers[2].id && table.selectedRow == 0,
              "Command-Z in the layer list undoes stack changes")
        table.keyDown(with: historyKey([.command, .shift]))
        check(store.document.layers[1].id == layers[2].id && table.selectedRow == 1,
              "Shift-Command-Z in the layer list redoes stack changes")
        window.makeFirstResponder(table)
        check(window.firstResponder === table, "The material list accepts keyboard focus for Delete")
        func deleteKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                             isARepeat: false, keyCode: keyCode)!
        }
        let deletionHistory = store.undoCount
        table.keyDown(with: deleteKey(51, modifiers: .capsLock))
        check(store.document.layers.count == 2 && !store.document.layers.contains(where: { $0.id == layers[2].id }),
              "Delete removes exactly the selected list material, including with Caps Lock on")
        check(store.selectedID == nil && table.selectedRow == -1 && store.undoCount == deletionHistory + 1,
              "Delete clears selection and records one undo step")
        table.keyDown(with: historyKey(.command))
        check(store.document.layers.count == 3, "Command-Z restores the material deleted from the list")
        store.selectedID = layers[0].id
        table.refresh()
        table.keyDown(with: deleteKey(51))
        check(store.document.layers.count == 3 && store.selectedID == layers[0].id, "Delete leaves locked materials untouched")
        store.toggleLock(layers[0].id)
        table.refresh()
        table.keyDown(with: deleteKey(117, modifiers: [.function, .numericPad]))
        check(store.document.layers.count == 2 && !store.document.layers.contains(where: { $0.id == layers[0].id }),
              "Forward Delete works with Fn and numeric-pad flags")
        let emptySelectionHistory = store.undoCount
        table.keyDown(with: deleteKey(51))
        check(store.undoCount == emptySelectionHistory && store.document.layers.count == 2,
              "Delete with no selected material has no effect")
        window.close()
        return checks
    }

    @MainActor private static func testCanvasOrientation(_ image: CGImage) -> Int {
        var checks = 0
        func check(_ condition: Bool, _ description: String) {
            if !condition { fatalError("FAIL: " + description) }
            checks += 1
        }
        let store = CanvasStore()
        store.resizeCanvas(CGSize(width: 900, height: 600))
        let photo = CanvasLayer(name: "Orientation photo", kind: .photo, image: image,
                                center: CGPoint(x: 300, y: 350), size: CGSize(width: 250, height: 150), rotation: 25)
        let locked = CanvasLayer(name: "Locked paper", kind: .paper, center: CGPoint(x: 80, y: 90),
                                 size: CGSize(width: 150, height: 220), locked: true)
        store.mutate { $0.layers = [locked, photo] }
        store.selectedID = photo.id
        let history = store.undoCount, fitRequests = store.fitRequest
        check(CanvasAspectRatio.matching(store.document.size) == .landscapePhoto, "A 3:2 canvas reports its preset")
        store.swapCanvasOrientation()
        check(store.document.size == CGSize(width: 600, height: 900) && CanvasAspectRatio.matching(store.document.size) == .portraitPhoto,
              "Orientation swap changes 3:2 to 2:3 with the exact width and height exchanged")
        check(store.selectedLayer!.size == photo.size && store.selectedLayer!.rotation == photo.rotation,
              "Orientation swap preserves photo size and rotation")
        check(store.selectedLayer!.center == CGPoint(x: 150, y: 500), "Photo keeps its offset from the canvas center")
        check(store.document.layers[0].center == locked.center && store.document.layers[0].size == locked.size,
              "Orientation swap keeps locked material transforms unchanged")
        check(store.undoCount == history + 1 && store.fitRequest == fitRequests + 1 && store.selectedID == photo.id,
              "Orientation swap records one undo step, refits the viewport and preserves selection")
        let output = try! CanvasRenderer.outputSize(for: CanvasRenderSnapshot(store.document), width: 1200)
        check(output == CGSize(width: 1200, height: 1800), "Export dimensions follow the swapped canvas")
        store.swapCanvasOrientation()
        check(store.document.size == CGSize(width: 900, height: 600) && store.selectedLayer!.center == photo.center && store.selectedLayer!.size == photo.size,
              "Two swaps restore the original canvas and photo without shrinking the photo")
        store.undo()
        check(store.document.size == CGSize(width: 600, height: 900) && CanvasAspectRatio.matching(store.document.size) == .portraitPhoto,
              "Undo restores the portrait canvas and matching ratio")
        store.undo()
        check(store.document.size == CGSize(width: 900, height: 600) && store.selectedLayer!.center == photo.center,
              "Undo restores the original composition")
        store.resizeCanvas(CGSize(width: 777, height: 501))
        store.swapCanvasOrientation()
        check(store.document.size == CGSize(width: 501, height: 777) && CanvasAspectRatio.matching(store.document.size) == .custom,
              "Orientation swap also works with custom dimensions")
        store.resizeCanvas(CGSize(width: 800, height: 800))
        let squareHistory = store.undoCount
        store.swapCanvasOrientation()
        check(store.document.size == CGSize(width: 800, height: 800) && store.undoCount == squareHistory,
              "A square canvas does not create a redundant orientation change")
        for preset in CanvasAspectRatio.allCases where preset != .custom {
            let size = CGSize(width: 900, height: 900 / preset.value!)
            let inverse = CanvasAspectRatio.matching(CGSize(width: size.height, height: size.width))
            check(inverse != .custom && abs(inverse.value! * preset.value! - 1) < 0.000001,
                  "Every aspect-ratio preset has its swapped counterpart")
        }
        return checks
    }

    nonisolated private static func fixture() -> CGImage {
        var bytes: [UInt8] = []
        for row in 0..<4 {
            for _ in 0..<4 { bytes += row < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        }
        return CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    nonisolated private struct Pixel: Equatable { var r: Int; var g: Int; var b: Int }
    nonisolated private static func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel {
        let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
        let index = y * image.bytesPerRow + x * 4
        return Pixel(r: Int(bytes[index]), g: Int(bytes[index + 1]), b: Int(bytes[index + 2]))
    }
}
