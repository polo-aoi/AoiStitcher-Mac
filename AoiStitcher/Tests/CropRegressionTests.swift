import AppKit

enum CropRegressionTests {
    @MainActor static func run() throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ description: String) {
            if !value { fatalError("FAIL: " + description) }
            checks += 1
        }
        let image = fixture()
        let item = StitchItem(url: URL(fileURLWithPath: "/tmp/crop-source.png"),
                              image: NSImage(cgImage: image, size: CGSize(width: 600, height: 400)))
        let store = CropStore(item: item)
        check(store.state.rect == CGRect(x: 0, y: 0, width: 600, height: 400), "Crop starts with the complete source image")
        let full = try CropRenderer.makeImage(CropRenderSnapshot(store)!)
        check(full.width == 240 && full.height == 160, "Crop output uses source pixels, not AppKit points or screen DPI")
        check(pixel(full, x: 30, y: 30) == [255,0,0] && pixel(full, x: 210, y: 130) == [0,0,255], "Crop output keeps source orientation")

        store.applyPreset(.free)
        let initial = store.state
        store.beginChange()
        store.resizeCrop(from: initial, handle: .bottomRight, delta: CGPoint(x: -100, y: -50), minimum: 24, keepAspect: false)
        store.resizeCrop(from: initial, handle: .bottomRight, delta: CGPoint(x: -200, y: -150), minimum: 24, keepAspect: false)
        store.endChange()
        check(store.state.rect == CGRect(x: 0, y: 0, width: 400, height: 250) && store.state.imageScale == 1,
              "Shrinking the crop changes only the crop rectangle, without zooming the photo")
        store.undo()
        check(store.state == initial, "A crop-handle drag is one undo step")
        store.redo()
        let cropped = store.state
        store.moveImage(to: CGPoint(x: 10000, y: -10000))
        check(CropGeometry.contains(store.state.rect, imageSize: store.imageSize, center: store.state.imageCenter,
                                    scale: store.state.imageScale, rotation: store.state.rotation), "Image movement clamps smoothly to the photo boundary")
        store.undo()
        check(store.state == cropped, "Undo restores image movement")
        store.beginChange(); store.setStraighten(30); store.setStraighten(-20); store.setStraighten(0); store.endChange()
        check(store.state.imageScale == cropped.imageScale, "Returning to zero within a straightening drag does not retain accumulated zoom")
        store.setStraighten(28)
        check(CropGeometry.contains(store.state.rect, imageSize: store.imageSize, center: store.state.imageCenter,
                                    scale: store.state.imageScale, rotation: store.state.rotation), "Straightening covers all four crop corners")
        store.setImageScale(0.001)
        check(CropGeometry.contains(store.state.rect, imageSize: store.imageSize, center: store.state.imageCenter,
                                    scale: store.state.imageScale, rotation: store.state.rotation), "Zooming out cannot expose blank crop corners")
        store.applyPreset(.r3_2)
        check(abs(store.state.rect.width / store.state.rect.height - 1.5) < 0.000001, "A 3:2 ratio produces a locked crop")
        store.swapAspect()
        check(abs(store.state.rect.width / store.state.rect.height - 2.0 / 3) < 0.000001 && store.state.preset == .r2_3,
              "Aspect swap updates both the crop and the ratio control")
        let rotatedStart = store.state
        for _ in 0..<4 { store.rotateQuarter() }
        check(abs(store.state.rect.width - rotatedStart.rect.width) < 0.000001 &&
              abs(store.state.rect.minX - rotatedStart.rect.minX) < 0.000001 &&
              store.state.imageScale == rotatedStart.imageScale && store.state.rotation == rotatedStart.rotation,
              "Four quarter-turns restore crop geometry without accumulating zoom")
        let result = try CropRenderer.makeImage(CropRenderSnapshot(store)!)
        let reopened = CropStore(item: store.makeItem(image: result))
        let resultAgain = try CropRenderer.makeImage(CropRenderSnapshot(reopened)!)
        check(resultAgain.width == result.width && resultAgain.height == result.height,
              "Reopening a saved crop preserves its source-pixel dimensions")
        check(pixel(resultAgain, x: result.width / 2, y: result.height / 2) == pixel(result, x: result.width / 2, y: result.height / 2),
              "Reopening a saved crop preserves its composition")

        var legacy = item
        legacy.cropInfo = CropInfo(uiCropRect: CGRect(x: 100, y: 80, width: 200, height: 100), rotation: 0,
                                   imageCenter: CGPoint(x: 200, y: 150), scale: 0.5)
        let migrated = CropStore(item: legacy)
        check(migrated.state.rect == CGRect(x: 200, y: 160, width: 400, height: 200) &&
              migrated.state.imageCenter == CGPoint(x: 400, y: 300), "Existing crops are converted from viewport coordinates to source coordinates")

        let rectangle = CGRect(x: 200, y: 150, width: 300, height: 200)
        for handle in CropHandle.allCases {
            let changed = CropGeometry.resized(rectangle, handle: handle, delta: CGPoint(x: 40, y: 20), ratio: 1.5, minimum: 24)
            check(abs(changed.width / changed.height - 1.5) < 0.000001, "Each of the eight handles honors a locked aspect ratio")
            let sign = handle.direction
            if sign.x != 0 && sign.y != 0 {
                check(abs((sign.x > 0 ? changed.minX : changed.maxX) - (sign.x > 0 ? rectangle.minX : rectangle.maxX)) < 0.000001 &&
                      abs((sign.y > 0 ? changed.minY : changed.maxY) - (sign.y > 0 ? rectangle.minY : rectangle.maxY)) < 0.000001,
                      "Corner resizing keeps the opposite corner fixed")
            }
        }
        for angle: CGFloat in [0,17,-32,90,118] {
            let scale = CropGeometry.requiredScale(rect: rectangle, imageSize: store.imageSize, rotation: angle)
            let center = CropGeometry.clampedCenter(CGPoint(x: 9999, y: 9999), rect: rectangle, imageSize: store.imageSize, scale: scale, rotation: angle)
            check(CropGeometry.contains(rectangle, imageSize: store.imageSize, center: center, scale: scale, rotation: angle),
                  "Rotated image constraints cover every crop corner")
        }
        let constrained = CropGeometry.constrainedRect(from: CGRect(x: 0, y: 0, width: 600, height: 400),
                                                       to: CGRect(x: 0, y: 0, width: 900, height: 800), imageSize: store.imageSize,
                                                       center: CGPoint(x: 300, y: 200), scale: 1, rotation: 0)
        check(abs(constrained.width - 600) < 0.01 && abs(constrained.height - 400) < 0.01,
              "An outward handle drag stops at the photo edge without changing the image scale")

        let watermark = NSImage(cgImage: solidGreen(), size: CGSize(width: 40, height: 40))
        store.reset(); store.addWatermark(watermark)
        let watermarkID = store.selectedWatermarkID!
        check(store.tool == .watermark && store.selectedWatermark?.id == watermarkID, "Adding a watermark selects it for editing")
        store.editWatermark(watermarkID) { $0.offset = CGSize(width: -150, height: -100); $0.scale = 0.5 }
        let watermarked = try CropRenderer.makeImage(CropRenderSnapshot(store)!)
        let watermarkPixel = pixel(watermarked, x: 60, y: 40)
        check(watermarkPixel[1] > 240 && watermarkPixel[0] < 10 && watermarkPixel[2] < 10,
              "Watermark positions agree with top-left photo coordinates after color-space conversion")
        store.deleteWatermark(); store.undo()
        check(store.state.watermarks.contains { $0.id == watermarkID }, "Deleting a watermark can be undone")
        checks += try testCanvas(item)
        return checks
    }

    @MainActor private static func testCanvas(_ item: StitchItem) throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ description: String) {
            if !value { fatalError("FAIL: " + description) }
            checks += 1
        }
        let store = CropStore(item: item)
        store.applyPreset(.free)
        store.resizeCrop(from: store.state, handle: .bottomRight, delta: CGPoint(x: -200, y: -150), minimum: 24, keepAspect: false)
        let view = CropCanvasView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; view.store = store; view.resetViewport()
        let scale = min(920.0 / 600, 700.0 / 400)
        let origin = CGPoint(x: 500 - 200 * scale, y: 400 - 125 * scale)
        func event(_ type: NSEvent.EventType, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            let position = CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
            return NSEvent.mouseEvent(with: type, location: view.convert(position, to: nil), modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func drag(_ from: CGPoint, _ to: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: event(.leftMouseDown, from, modifiers: modifiers))
            view.mouseDragged(with: event(.leftMouseDragged, to, modifiers: modifiers))
            view.mouseUp(with: event(.leftMouseUp, to, modifiers: modifiers))
        }
        let history = store.undoCount
        drag(CGPoint(x: 200, y: 125), CGPoint(x: 160, y: 95))
        check(abs(store.state.imageCenter.x - 260) < 0.001 && abs(store.state.imageCenter.y - 170) < 0.001,
              "Dragging inside the crop moves the photo by the actual pointer displacement")
        check(store.undoCount == history + 1, "A native photo drag creates one undo step")
        check(store.state.rect == CGRect(x: 0, y: 0, width: 400, height: 250), "Dragging the photo leaves the crop box fixed")
        store.undo()
        drag(CGPoint(x: 400, y: 250), CGPoint(x: 340, y: 220))
        check(abs(store.state.rect.width - 340) < 0.001 && abs(store.state.rect.height - 220) < 0.001,
              "Native corner dragging resizes the crop without coordinate jumps")
        store.undo()
        drag(CGPoint(x: 200, y: 125), CGPoint(x: 250, y: 145), modifiers: .command)
        check(abs(store.state.rect.minX - 50) < 0.001 && abs(store.state.rect.minY - 20) < 0.001,
              "Command-drag moves the crop box within the photo")
        store.undo()
        store.tool = .straighten
        drag(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 120))
        check(abs(store.state.straighten + atan2(20.0,200.0) * 180 / .pi) < 0.001,
              "Straightening a drawn horizon line compensates its angle")
        store.undo(); store.tool = .crop
        let rotationStart = store.state
        let rotationHistory = store.undoCount
        let center = CGPoint(x: rotationStart.rect.midX, y: rotationStart.rect.midY)
        let radius = rotationStart.rect.height / 2 + 30 / scale
        let rotationStartPoint = CGPoint(x: center.x, y: center.y - radius)
        let rotationEndPoint = CGPoint(x: center.x + radius * sin(12 * .pi / 180),
                                       y: center.y - radius * cos(12 * .pi / 180))
        drag(rotationStartPoint, rotationEndPoint)
        check(abs(store.state.straighten - 12) < 0.001, "The crop-edge rotation handle follows the pointer angle")
        check(store.state.rect == rotationStart.rect && store.undoCount == rotationHistory + 1,
              "Edge rotation leaves the crop fixed and is one undo step")
        store.undo()
        check(store.state == rotationStart, "Undo restores crop-edge rotation and photo placement")
        drag(rotationStartPoint, rotationEndPoint, modifiers: .shift)
        check(abs(store.state.straighten - 15) < 0.001, "Shift snaps crop-edge rotation to 15 degrees")
        store.undo()
        drag(CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 25))
        check(abs(store.state.rect.minY - 25) < 0.001 && abs(store.state.rect.height - 225) < 0.001,
              "Dragging any part of an edge resizes the crop, beyond its midpoint handle")
        store.undo()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No crop preview bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: "/tmp/aoistitcher-canvas-regression/crop-workspace.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "The native crop workspace produces a nonempty preview")
        window.close()
        return checks
    }

    nonisolated private static func fixture() -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<160 { for x in 0..<240 {
            if y < 80 { bytes += x < 120 ? [255,0,0,255] : [255,255,0,255] }
            else { bytes += x < 120 ? [255,0,255,255] : [0,0,255,255] }
        } }
        return CGImage(width: 240, height: 160, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 240 * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    nonisolated private static func solidGreen() -> CGImage {
        let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        return context.makeImage()!
    }
    nonisolated private static func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!, offset = y * image.bytesPerRow + x * 4
        return [Int(bytes[offset]), Int(bytes[offset+1]), Int(bytes[offset+2])]
    }
}
