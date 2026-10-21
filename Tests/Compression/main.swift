import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let pipeline = ImagePipeline()
var checks: [[String: Any]] = []

func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
    guard condition() else { throw NSError(domain: "AoiFitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "FAILED: " + name]) }
    checks.append(["name": name, "passed": true])
}

func rgba(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes { data in
        let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}

func properties(_ data: Data) -> [CFString: Any] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
}

func decoded(_ data: Data) -> CGImage {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

func fixture(_ name: String) -> URL { root.appendingPathComponent("Tests/Compression/Fixtures/Inputs/" + name) }

func jpegSignature(_ data: Data) throws -> (tables: [Int: [Int]], sampling: [Int]) {
    let bytes = [UInt8](data)
    func invalidJPEG() -> NSError {
        NSError(domain: "AoiFitTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid JPEG marker structure"])
    }
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw invalidJPEG() }
    var tables: [Int: [Int]] = [:], sampling: [Int] = []
    var position = 2
    while position < bytes.count {
        guard bytes[position] == 0xFF else { throw invalidJPEG() }
        while position < bytes.count && bytes[position] == 0xFF { position += 1 }
        guard position < bytes.count else { throw invalidJPEG() }
        let marker = bytes[position]; position += 1
        if marker == 0xDA || marker == 0xD9 { break }
        if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
        guard position + 2 <= bytes.count else { throw invalidJPEG() }
        let length = Int(bytes[position]) * 256 + Int(bytes[position + 1])
        guard length >= 2, position + length <= bytes.count else { throw invalidJPEG() }
        let payload = position + 2, end = position + length
        if marker == 0xDB {
            var cursor = payload
            while cursor < end {
                let header = bytes[cursor]; cursor += 1
                let step = header >> 4 == 0 ? 1 : 2
                guard cursor + 64 * step <= end else { throw invalidJPEG() }
                var table: [Int] = []
                for _ in 0..<64 {
                    table.append(step == 1 ? Int(bytes[cursor]) : Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1]))
                    cursor += step
                }
                tables[Int(header & 0x0F)] = table
            }
        } else if [UInt8(0xC0), 0xC1, 0xC2].contains(marker) {
            guard payload + 6 <= end else { throw invalidJPEG() }
            let count = Int(bytes[payload + 5])
            guard payload + 6 + count * 3 <= end else { throw invalidJPEG() }
            sampling = (0..<count).map { Int(bytes[payload + 6 + $0 * 3 + 1]) }
        }
        position = end
    }
    return (tables, sampling)
}

// Derived reference signature: no raw user photos or local photo paths are required.
let signatureData = try Data(contentsOf: root.appendingPathComponent("Tests/Compression/Fixtures/platform-jpeg-signature.json"))
let referenceJPEG = try JSONSerialization.jsonObject(with: signatureData) as! [String: Any]
let referenceTables = referenceJPEG["dqt"] as! [String: [Int]]
let expectedTables = Dictionary(uniqueKeysWithValues: referenceTables.map { (Int($0.key)!, $0.value) })
let expectedSampling = referenceJPEG["sampling"] as! [Int]

do {
    var moments = ExportSettings()
    moments.preset = "moments"
    moments.format = .png
    moments.quality = 100
    moments.applyPlatformRecipe()
    try check("Moments preset locks its export recipe", moments.dimension == .shortest && moments.pixels == 1920 && moments.effectiveFormat == .jpeg)
    var redbook = ExportSettings()
    redbook.preset = "redbook"
    redbook.format = .heic
    redbook.quality = 100
    redbook.applyPlatformRecipe()
    try check("Rednote preset locks its export recipe", redbook.dimension == .shortest && redbook.pixels == 2560 && redbook.effectiveFormat == .jpeg)
    var douyin = ExportSettings()
    douyin.preset = "douyin"
    douyin.format = .heic
    douyin.quality = 62
    douyin.dimension = .height
    douyin.pixels = 640
    douyin.allowUpscale = true
    douyin.applyPlatformRecipe()
    try check("Douyin preset locks the recovered short-edge 2160 recipe", douyin.dimension == .shortest && douyin.pixels == 2160 && douyin.effectiveFormat == .jpeg && !douyin.allowUpscale)

    for preset in ["moments", "redbook", "douyin"] {
        var inherited = ExportSettings()
        inherited.preset = preset; inherited.allowUpscale = true
        inherited.applyPlatformRecipe()
        try check("\(preset) normalizes old upscaling preference", !inherited.allowUpscale)
        inherited.allowUpscale = true
        try check("\(preset) ignores direct old upscaling value", inherited.outputSize(width: 640, height: 480) == CGSize(width: 640, height: 480))
        inherited.preset = "custom"
        let customSize = inherited.outputSize(width: 640, height: 480)
        try check("custom re-enables optional upscaling after \(preset)", customSize.width > 640 && customSize.height > 480)
    }

    // Exercise the actual encoder with conflicting old settings, rather than just checking UI state.
    let lockedSource = CGImageSourceCreateWithURL(fixture("small_640x480.jpg") as CFURL, nil)!
    let lockedImage = CGImageSourceCreateImageAtIndex(lockedSource, 0, nil)!
    var platformBytes = 0
    for preset in ["moments", "redbook", "douyin"] {
        var conflicting = ExportSettings()
        conflicting.preset = preset; conflicting.format = .png; conflicting.quality = 100
        let locked = try pipeline.encode(lockedImage, settings: conflicting)
        let source = CGImageSourceCreateWithData(locked as CFData, nil)!
        try check("\(preset) stale PNG setting still produces JPEG", CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let signature = try jpegSignature(locked)
        try check("\(preset) final quantization matches observed scene export", signature.tables == expectedTables)
        try check("\(preset) final sampling remains 4:4:4", signature.sampling == expectedSampling)
        conflicting.quality = 10
        let changedManualQuality = try pipeline.encode(lockedImage, settings: conflicting)
        try check("\(preset) ignores independently stored manual quality", locked == changedManualQuality)
        platformBytes = locked.count
    }
    var baselineSettings = ExportSettings()
    baselineSettings.quality = 100
    let fullQuality = try pipeline.encode(lockedImage, settings: baselineSettings)
    baselineSettings.quality = 50
    let lowQuality = try pipeline.encode(lockedImage, settings: baselineSettings)
    try check("custom quality remains independently adjustable", fullQuality.count > lowQuality.count && fullQuality.count > platformBytes)

    let portrait = try ImagePipeline.inspect(fixture("portrait_2560x3840.jpg"))
    let douyinPortrait = try pipeline.render(portrait, settings: douyin)
    let decodedDouyinPortrait = decoded(douyinPortrait.data)
    try check("Douyin portrait JPEG has actual dimensions 2160 x 3240", douyinPortrait.width == 2160 && douyinPortrait.height == 3240 && decodedDouyinPortrait.width == 2160 && decodedDouyinPortrait.height == 3240)
    try ImagePipeline.write(douyinPortrait.data, to: output.appendingPathComponent("douyin-portrait.jpg"))
    var settings = ExportSettings()
    settings.dimension = .shortest; settings.pixels = 1440; settings.format = .png
    var baseline: CFData?
    for level in OutputSharpeningLevel.allCases {
        settings.sharpening = level.rawValue
        let image = try pipeline.render(portrait, settings: settings)
        try check("portrait \(level.rawValue) output dimensions", image.width == 1440 && image.height == 2160)
        let pixels = decoded(image.data).dataProvider!.data!
        if level == .off { baseline = pixels }
        else { try check("\(level.rawValue) changes RGB detail", pixels != baseline!) }
        try ImagePipeline.write(image.data, to: output.appendingPathComponent("portrait_\(level.rawValue).png"))
    }

    settings.sharpening = "standard"
    let transparent = try ImagePipeline.inspect(fixture("landscape_4000x2400.png"))
    let douyinLandscape = try pipeline.render(transparent, settings: douyin)
    let decodedDouyinLandscape = decoded(douyinLandscape.data)
    try check("Douyin landscape JPEG has actual dimensions 3600 x 2160", douyinLandscape.width == 3600 && douyinLandscape.height == 2160 && decodedDouyinLandscape.width == 3600 && decodedDouyinLandscape.height == 2160)
    try ImagePipeline.write(douyinLandscape.data, to: output.appendingPathComponent("douyin-landscape.jpg"))
    settings.dimension = .longest; settings.pixels = 1920
    let png = try pipeline.render(transparent, settings: settings)
    let pixels = rgba(decoded(png.data))
    let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    try check("PNG dimensions", png.width == 1920 && png.height == 1152)
    try check("PNG preserves fully transparent and opaque regions", alpha.min() == 0 && alpha.max() == 255)
    try ImagePipeline.write(png.data, to: output.appendingPathComponent("transparent.png"))

    let opaque = try pipeline.render(portrait, settings: settings)
    let opaquePixels = rgba(decoded(opaque.data))
    try check("opaque photos have no translucent sampling border", stride(from: 3, to: opaquePixels.count, by: 4).allSatisfy { opaquePixels[$0] == 255 })

    for format in [ExportFormat.jpeg, .heic] {
        settings.format = format
        let encoded = try pipeline.render(transparent, settings: settings)
        try check("\(format.title) encodes and decodes", encoded.data.count > 0 && encoded.width == 1920 && encoded.height == 1152)
        let encodedPixels = rgba(decoded(encoded.data))
        let transparentIndex = alpha.firstIndex(of: 0)! * 4
        let background = Array(encodedPixels[transparentIndex..<(transparentIndex + 4)])
        try check("\(format.title) transparent input has explicit white background", background[0] > 245 && background[1] > 245 && background[2] > 245 && background[3] == 255)
        try ImagePipeline.write(encoded.data, to: output.appendingPathComponent("transparent." + format.suffix))
    }

    let small = try ImagePipeline.inspect(fixture("small_640x480.jpg"))
    settings.format = .png; settings.dimension = .longest; settings.pixels = 1080
    settings.allowUpscale = false
    let unchanged = try pipeline.render(small, settings: settings)
    try check("small input is not upscaled by default", unchanged.width == 640 && unchanged.height == 480)
    settings.allowUpscale = true
    let enlarged = try pipeline.render(small, settings: settings)
    try check("opt-in upscaling", enlarged.width == 1080 && enlarged.height == 810)
    settings.dimension = .width; settings.pixels = 720
    let widthResult = try pipeline.render(small, settings: settings)
    try check("width resize", widthResult.width == 720 && widthResult.height == 540)
    settings.dimension = .height; settings.pixels = 720
    let heightResult = try pipeline.render(small, settings: settings)
    try check("height resize", heightResult.width == 960 && heightResult.height == 720)
    settings.dimension = .original
    let originalResult = try pipeline.render(small, settings: settings)
    try check("original dimensions", originalResult.width == 640 && originalResult.height == 480)
    settings.dimension = .width; settings.pixels = 1440; settings.allowUpscale = true
    try check("chosen width remains exact for uneven aspect ratios", settings.outputSize(width: 4033, height: 2689).width == 1440)
    settings.dimension = .height
    try check("chosen height remains exact for uneven aspect ratios", settings.outputSize(width: 2689, height: 4033).height == 1440)
    settings.dimension = .original

    // Build a known rotated file with camera and GPS information, rather than using private photos.
    let source = CGImageSourceCreateWithURL(small.url as CFURL, nil)!
    let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let orientationFile = output.appendingPathComponent("rotated-fixture.jpg")
    let destination = CGImageDestinationCreateWithURL(orientationFile as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let metadata: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "AoiFit Test", kCGImagePropertyTIFFOrientation: 6],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:13 16:00:00"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.5, kCGImagePropertyGPSLatitudeRef: "N"],
    ]
    CGImageDestinationAddImage(destination, sourceImage, metadata as CFDictionary)
    try check("rotated fixture encodes", CGImageDestinationFinalize(destination))
    let rotated = try ImagePipeline.inspect(orientationFile)
    try check("import respects EXIF orientation", rotated.width == 480 && rotated.height == 640)
    settings.format = .jpeg; settings.keepMetadata = true; settings.removeLocation = true
    let corrected = try pipeline.render(rotated, settings: settings)
    let correctedProperties = properties(corrected.data)
    try check("render respects EXIF orientation", corrected.width == 480 && corrected.height == 640)
    let correctedOrientation = (correctedProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    try check("export does not rotate twice", correctedOrientation == 1)
    let exif = correctedProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    try check("preserves capture date", exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:13 16:00:00")
    try check("GPS is removed by default", correctedProperties[kCGImagePropertyGPSDictionary] == nil)
    try check("EXIF output dimensions are updated", (exif?[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue == 480 && (exif?[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue == 640)
    settings.removeLocation = false
    let locationKept = try pipeline.render(rotated, settings: settings)
    try check("GPS can be retained explicitly", properties(locationKept.data)[kCGImagePropertyGPSDictionary] != nil)
    settings.keepMetadata = false
    let metadataRemoved = try pipeline.render(rotated, settings: settings)
    let withoutExif = properties(metadataRemoved.data)[kCGImagePropertyExifDictionary] as? [CFString: Any]
    try check("capture metadata can be removed", withoutExif?[kCGImagePropertyExifDateTimeOriginal] == nil)

    var platformMetadataSettings = settings
    platformMetadataSettings.preset = "moments"
    platformMetadataSettings.format = .png
    platformMetadataSettings.quality = 100
    platformMetadataSettings.removeLocation = true
    for keepMetadata in [true, false] {
        platformMetadataSettings.keepMetadata = keepMetadata
        let result = try pipeline.render(rotated, settings: platformMetadataSettings)
        let signature = try jpegSignature(result.data)
        try check("platform second encoding is stable with metadata \(keepMetadata)", signature.tables == expectedTables && signature.sampling == expectedSampling)
        let metadata = properties(result.data)
        let exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]
        try check("platform capture date follows metadata option \(keepMetadata)", (exif?[kCGImagePropertyExifDateTimeOriginal] as? String != nil) == keepMetadata)
        try check("platform rewrap removes GPS and normalizes orientation \(keepMetadata)", metadata[kCGImagePropertyGPSDictionary] == nil && (metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1)
    }

    let protected = output.appendingPathComponent("keep-existing.jpg")
    let marker = Data("do not overwrite".utf8)
    try marker.write(to: protected)
    var rejected = false
    do { try ImagePipeline.write(corrected.data, to: protected) } catch { rejected = true }
    let remaining = try Data(contentsOf: protected)
    try check("existing output is never overwritten", rejected && remaining == marker)
    let collision = output.appendingPathComponent(rotated.name + "_aoipic.jpg")
    try marker.write(to: collision)
    let numbered = ImagePipeline.batchDestination(photo: rotated, directory: output, format: .jpeg)
    try check("batch filename collisions get a new number", numbered.lastPathComponent == rotated.name + "_aoipic_2.jpg")
    try ImagePipeline.write(corrected.data, to: numbered)

    let corrupt = output.appendingPathComponent("corrupt.png")
    try Data("invalid image".utf8).write(to: corrupt)
    var corruptRejected = false
    do { _ = try ImagePipeline.inspect(corrupt) } catch { corruptRejected = true }
    try check("invalid file produces a readable import error", corruptRejected)

    let report: [String: Any] = ["application": "aoipic 3.1.1", "scope": "Native pipeline integration including the recovered Douyin preset; generated fixtures and observed JPEG encoding tables", "original_app_equivalence": false, "checks": checks, "passed": checks.count, "failed": 0]
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: output.appendingPathComponent("test-results.json"))
    print("PASS: \(checks.count) checks. " + output.path)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
