import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct GridCollageRenderTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError("FAIL: " + description) }
            checks += 1
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aoipic-grid-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let red = fixture(width: 80, height: 80) { _, _ in [255, 0, 0, 255] }
        let blue = fixture(width: 80, height: 80) { _, _ in [0, 0, 255, 255] }
        let green = fixture(width: 8, height: 8) { _, _ in [0, 255, 0, 255] }
        let stripes = fixture(width: 80, height: 80) { _, y in
            y < 40 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        }
        var state = oneSlot(image: stripes)
        let output = try GridCollageRenderer.makeImage(state: state, width: 200)
        check(isRed(pixel(output, x: 100, y: 20)), "Top of source stays at the top of the exported collage")
        check(isBlue(pixel(output, x: 100, y: 180)), "Bottom of source stays at the bottom of the exported collage")
        check(output.width == 200 && output.height == 200, "Selected width produces matching square output")

        state.aspectRatio = .portrait3x4
        let portraitSize = try GridCollageRenderer.outputSize(for: state, width: 300)
        check(portraitSize == CGSize(width: 300, height: 400), "Export dimensions follow the chosen aspect ratio")
        do {
            _ = try GridCollageRenderer.outputSize(for: state, width: 199)
            fatalError("Invalid export width was accepted")
        } catch GridCollageExportError.invalidSize { checks += 1 }
        do {
            _ = try GridCollageRenderer.outputSize(for: state, width: 16384)
            fatalError("Excessive bitmap size was accepted")
        } catch GridCollageExportError.tooLarge { checks += 1 }

        state = CollageState(aspectRatio: .square, activeTemplateId: "test-split",
                             rootNode: .split(id: "split", direction: .horizontal, ratios: [0.5, 0.5],
                                              children: [.slot(slotId: "left"), .slot(slotId: "right")]),
                             slots: ["left": CollageSlot(id: "left", image: red),
                                     "right": CollageSlot(id: "right", image: blue)], selectedSlotId: nil)
        state.style.gap = 100; state.style.padding = 100
        state.style.backgroundColor = CollageColor(red: 0, green: 1, blue: 0)
        state.slots["left"]?.transform = CollageImageTransform(scale: 5, translateX: 10, translateY: 10)
        let clipped = try GridCollageRenderer.makeImage(state: state, width: 200)
        check(isGreen(pixel(clipped, x: 5, y: 100)), "Canvas padding retains background color")
        check(isGreen(pixel(clipped, x: 100, y: 100)), "Oversized and panned images cannot paint across the central gap")
        check(isRed(pixel(clipped, x: 60, y: 100)), "The first image fills its independently cropped slot")
        check(isBlue(pixel(clipped, x: 145, y: 100)), "An adjacent slot retains its own image content")
        state.style.borderRadius = 100
        let rounded = try GridCollageRenderer.makeImage(state: state, width: 200)
        check(isGreen(pixel(rounded, x: 21, y: 21)), "Rounded slot corners reveal the background")

        // The UI clamps a rounded corner to half the slot's shortest side.
        // CoreGraphics clamps each axis separately, so passing radius 48 to a
        // 60-point-wide slot would otherwise produce an elliptical corner.
        var narrowState = CollageState(aspectRatio: .square, activeTemplateId: "test-narrow",
                                       rootNode: .split(id: "narrow", direction: .horizontal,
                                                        ratios: [0.06, 0.94],
                                                        children: [.slot(slotId: "thin"), .slot(slotId: "wide")]),
                                       slots: ["thin": CollageSlot(id: "thin", image: red),
                                               "wide": CollageSlot(id: "wide", image: blue)], selectedSlotId: nil)
        narrowState.style.gap = 0; narrowState.style.padding = 0
        narrowState.style.borderRadius = 48
        narrowState.style.backgroundColor = CollageColor(red: 0, green: 1, blue: 0)
        let narrowRounded = try GridCollageRenderer.makeImage(state: narrowState, width: 1000)
        check(isRed(pixel(narrowRounded, x: 2, y: 22)),
              "A narrow slot uses circular corners clamped to its shortest side, matching preview")
        check(isGreen(pixel(narrowRounded, x: 2, y: 2)), "Clamped narrow-slot corners still reveal background")
        narrowState.rootNode = .split(id: "short", direction: .vertical, ratios: [0.06, 0.94],
                                      children: [.slot(slotId: "thin"), .slot(slotId: "wide")])
        let shortRounded = try GridCollageRenderer.makeImage(state: narrowState, width: 1000)
        check(isRed(pixel(shortRounded, x: 22, y: 2)),
              "A short slot uses the same shortest-side circular-corner limit")
        check(isGreen(pixel(shortRounded, x: 2, y: 2)), "Clamped short-slot corners still reveal background")

        let sourceURL = directory.appendingPathComponent("full-source.png")
        try writeFixture(stripes, to: sourceURL, type: .png)
        let originalSourceBytes = try Data(contentsOf: sourceURL)
        state = oneSlot(image: green)
        state.slots["photo"]?.previewImage = green
        state.slots["photo"]?.imageURL = sourceURL
        let fullSource = try GridCollageRenderer.makeImage(state: state, width: 400)
        let preview = try GridCollageRenderer.makeImage(state: state, width: 400, usePreviewImages: true)
        check(isRed(pixel(fullSource, x: 200, y: 40)), "Final render reloads original URL even when a low-quality cached image exists")
        check(isBlue(pixel(fullSource, x: 200, y: 360)), "Original source contributes its full image content")
        check(isGreen(pixel(preview, x: 200, y: 40)), "Interactive render uses the supplied lightweight preview")
        state.slots["photo"]?.image = nil
        let previewOnly = try GridCollageRenderer.makeImage(state: state, width: 400)
        check(isRed(pixel(previewOnly, x: 200, y: 40)), "Preview-only store state still exports from its original source URL")
        let interactiveOnly = try GridCollageRenderer.makeImage(state: state, width: 400, usePreviewImages: true)
        check(isGreen(pixel(interactiveOnly, x: 200, y: 40)),
              "A preview-only slot remains visible to the interactive renderer")

        // The secondary editor retains the original URL for reopening, while a
        // lossless full-resolution result (not its small preview) is rendered.
        // A narrow detail in the result catches accidental preview-size export.
        let editedURL = directory.appendingPathComponent("full-source-edited.png")
        let edited = fixture(width: 800, height: 400) { x, _ in
            if (398..<402).contains(x) { return [0, 0, 0, 255] }
            return x < 400 ? [0, 0, 255, 255] : [255, 0, 0, 255]
        }
        try writeFixture(edited, to: editedURL, type: .png)
        let editedBytes = try Data(contentsOf: editedURL)
        state = oneSlot(image: green)
        state.slots["photo"]?.imageURL = sourceURL
        state.slots["photo"]?.editedImageURL = editedURL
        state.slots["photo"]?.previewImage = green
        state.slots["photo"]?.fill = .contain
        let editedOutput = try GridCollageRenderer.makeImage(state: state, width: 800)
        check(isBlue(pixel(editedOutput, x: 100, y: 400)) && isRed(pixel(editedOutput, x: 700, y: 400)),
              "An edited full-resolution source takes priority over its retained original")
        check(isWhite(pixel(editedOutput, x: 400, y: 100)),
              "Edited image dimensions determine the slot cover/contain geometry")
        let editedDetail = pixel(editedOutput, x: 400, y: 400)
        check(editedDetail.r < 25 && editedDetail.g < 25 && editedDetail.b < 25,
              "Final render preserves fine detail from the full-resolution edited result")
        let editedPreview = try GridCollageRenderer.makeImage(state: state, width: 800, usePreviewImages: true)
        check(isGreen(pixel(editedPreview, x: 400, y: 400)),
              "Interactive rendering still uses the lightweight edited preview")
        state.slots["photo"]?.imageURL = directory.appendingPathComponent("original-no-longer-present.png")
        let editedWithMissingOriginal = try GridCollageRenderer.makeImage(state: state, width: 800)
        check(isBlue(pixel(editedWithMissingOriginal, x: 100, y: 400)),
              "An available full edited result exports independently of its original source")
        let editedExportURL = directory.appendingPathComponent("edited-collage.png")
        try GridCollageRenderer.export(state: state, width: 800, format: .png, to: editedExportURL)
        let editedExportSource = CGImageSourceCreateWithURL(editedExportURL as CFURL, nil)!
        let editedExport = CGImageSourceCreateImageAtIndex(editedExportSource, 0, nil)!
        check(isBlue(pixelRGBA(editedExport, x: 100, y: 400)) && isRed(pixelRGBA(editedExport, x: 700, y: 400)),
              "Encoded exports include the secondary edit, not the original or preview")

        // Having an edited URL is a commitment to that image. A stale or broken
        // cache must fail visibly, even if the original and preview are valid.
        state.slots["photo"]?.imageURL = sourceURL
        let missingEdited = directory.appendingPathComponent("missing-edited-result.png")
        state.slots["photo"]?.editedImageURL = missingEdited
        let failedEditedExport = directory.appendingPathComponent("missing-edit-must-not-publish.png")
        do {
            try GridCollageRenderer.export(state: state, width: 800, format: .png, to: failedEditedExport)
            fatalError("Missing edited source silently reverted to original or preview")
        } catch GridCollageExportError.cannotReadSource(let name) {
            check(name == missingEdited.lastPathComponent, "Missing edited result identifies its exact failing file")
        }
        check(!FileManager.default.fileExists(atPath: failedEditedExport.path),
              "A missing edited result cannot publish an unchanged or partial collage")
        let invalidEdited = directory.appendingPathComponent("damaged-edited-result.png")
        try Data("broken edited image".utf8).write(to: invalidEdited)
        state.slots["photo"]?.editedImageURL = invalidEdited
        do {
            _ = try GridCollageRenderer.makeImage(state: state, width: 800)
            fatalError("Damaged edited source silently reverted to original or preview")
        } catch GridCollageExportError.cannotReadSource(let name) {
            check(name == invalidEdited.lastPathComponent, "Damaged edited result identifies its exact failing file")
        }
        let survivingEdit = try Data(contentsOf: editedURL)
        check(survivingEdit == editedBytes, "Export and failed source reads preserve the full edited result")

        // An EXIF-6 landscape is upright portrait after decoding. With contain
        // it must have white side margins and red above blue, not horizontal.
        let rawRotated = fixture(width: 80, height: 40) { x, _ in
            x < 40 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        }
        let rotatedURL = directory.appendingPathComponent("rotated-exif.jpg")
        try writeFixture(rawRotated, to: rotatedURL, type: .jpeg, orientation: 6)
        state = oneSlot(image: green)
        state.slots["photo"]?.imageURL = rotatedURL
        state.slots["photo"]?.fill = .contain
        let oriented = try GridCollageRenderer.makeImage(state: state, width: 200)
        check(isWhite(pixel(oriented, x: 20, y: 100)), "EXIF-rotated portrait has side margins when fully displayed")
        check(isRed(pixel(oriented, x: 100, y: 20)), "EXIF orientation is applied exactly once at full-source load")
        check(isBlue(pixel(oriented, x: 100, y: 180)), "EXIF source bottom remains upright in export")

        state = oneSlot(image: red)
        state.slots.removeAll()
        state.style.backgroundImage = green
        state.style.backgroundImageURL = sourceURL
        let background = try GridCollageRenderer.makeImage(state: state, width: 200)
        check(isRed(pixel(background, x: 100, y: 20)), "Background export reloads full URL instead of cached preview")

        state = oneSlot(image: red)
        state.style.backgroundColor = CollageColor(red: 0, green: 0, blue: 0, alpha: 0)
        state.style.padding = 100
        let pngURL = directory.appendingPathComponent("collage.png")
        let jpgURL = directory.appendingPathComponent("collage.jpg")
        try GridCollageRenderer.export(state: state, width: 200, format: .png, to: pngURL)
        try GridCollageRenderer.export(state: state, width: 200, format: .jpeg, to: jpgURL)
        let pngSource = CGImageSourceCreateWithURL(pngURL as CFURL, nil)!
        let jpgSource = CGImageSourceCreateWithURL(jpgURL as CFURL, nil)!
        check(CGImageSourceGetType(pngSource) as String? == UTType.png.identifier, "PNG export produces a decodable PNG")
        check(CGImageSourceGetType(jpgSource) as String? == UTType.jpeg.identifier, "JPEG export produces a decodable JPEG")
        let decodedPNG = CGImageSourceCreateImageAtIndex(pngSource, 0, nil)!
        let decodedJPEG = CGImageSourceCreateImageAtIndex(jpgSource, 0, nil)!
        check(pixelRGBA(decodedPNG, x: 5, y: 100).a == 0, "PNG preserves transparent background")
        check(isWhite(pixelRGBA(decodedJPEG, x: 5, y: 100)), "JPEG flattens transparent background onto white")
        let existingData = try Data(contentsOf: pngURL)
        do {
            try GridCollageRenderer.export(state: state, width: 200, format: .png, to: pngURL)
            fatalError("Existing output file was replaced")
        } catch GridCollageExportError.fileExists { checks += 1 }
        let afterRejection = try Data(contentsOf: pngURL)
        check(afterRejection == existingData, "An overwrite rejection leaves the existing file byte-for-byte intact")
        let directoryNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(!directoryNames.contains { $0.hasSuffix(".tmp") },
              "Successful and rejected exports remove temporary staging files")

        let missingSource = directory.appendingPathComponent("missing-original.jpg")
        state.slots["photo"]?.imageURL = missingSource
        let failedURL = directory.appendingPathComponent("must-not-be-written.png")
        do {
            try GridCollageRenderer.export(state: state, width: 200, format: .png, to: failedURL)
            fatalError("Missing original source silently used the cached preview")
        } catch GridCollageExportError.cannotReadSource(let name) {
            check(name == missingSource.lastPathComponent, "Source failures identify the exact original file")
        }
        check(!FileManager.default.fileExists(atPath: failedURL.path), "Failed source decode cannot publish a partial image")
        let invalidSource = directory.appendingPathComponent("invalid-source.jpg")
        try Data("not an image".utf8).write(to: invalidSource)
        state.slots["photo"]?.imageURL = invalidSource
        do {
            _ = try GridCollageRenderer.makeImage(state: state, width: 200)
            fatalError("Invalid source silently used the cached preview")
        } catch GridCollageExportError.cannotReadSource(let name) {
            check(name == invalidSource.lastPathComponent, "Invalid source errors include the specific filename")
        }
        state = oneSlot(image: red)
        state.style.backgroundImage = green
        state.style.backgroundImageURL = missingSource
        do {
            _ = try GridCollageRenderer.makeImage(state: state, width: 200)
            fatalError("Missing background silently used the cached background")
        } catch GridCollageExportError.cannotReadSource(let name) {
            check(name == missingSource.lastPathComponent, "Missing original background fails explicitly")
        }
        let survivingSource = try Data(contentsOf: sourceURL)
        check(survivingSource == originalSourceBytes, "Rendering and failures preserve original input files byte-for-byte")
        print("Grid collage render regression tests passed (\(checks) checks)")
    }

    private static func oneSlot(image: CGImage) -> CollageState {
        var state = CollageState(aspectRatio: .square, activeTemplateId: "test-single",
                                 rootNode: .slot(slotId: "photo"),
                                 slots: ["photo": CollageSlot(id: "photo", image: image)], selectedSlotId: nil)
        state.style.gap = 0; state.style.padding = 0
        return state
    }

    private static func fixture(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) -> CGImage {
        var data: [UInt8] = []
        for y in 0..<height { for x in 0..<width { data += pixel(x, y) } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func writeFixture(_ image: CGImage, to url: URL, type: UTType, orientation: Int = 1) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            fatalError("Cannot create fixture")
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImagePropertyOrientation: orientation,
                                    kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot encode fixture") }
    }

    private struct Pixel { var r: Int; var g: Int; var b: Int; var a: Int }
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel {
        let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
        let index = y * image.bytesPerRow + x * 4
        return Pixel(r: Int(bytes[index]), g: Int(bytes[index + 1]), b: Int(bytes[index + 2]), a: Int(bytes[index + 3]))
    }
    private static func pixelRGBA(_ image: CGImage, x: Int, y: Int) -> Pixel {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixel(context.makeImage()!, x: x, y: y)
    }
    private static func isRed(_ pixel: Pixel) -> Bool { pixel.r > 230 && pixel.g < 25 && pixel.b < 25 }
    private static func isBlue(_ pixel: Pixel) -> Bool { pixel.b > 230 && pixel.g < 25 && pixel.r < 25 }
    private static func isGreen(_ pixel: Pixel) -> Bool { pixel.g > 230 && pixel.r < 25 && pixel.b < 25 }
    private static func isWhite(_ pixel: Pixel) -> Bool { pixel.r > 230 && pixel.g > 230 && pixel.b > 230 }
}
