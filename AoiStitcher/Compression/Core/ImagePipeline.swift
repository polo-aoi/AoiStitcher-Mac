// Image processing adapted from AoiFit 0.1.1. See Compression/README.md.
import Foundation
import CoreGraphics
import Darwin
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Metal

nonisolated enum FitDimension: String, CaseIterable, Codable, Sendable {
    case longest, shortest, width, height, original
    var title: String {
        switch self {
        case .longest: return "长边"
        case .shortest: return "短边"
        case .width: return "宽度"
        case .height: return "高度"
        case .original: return "原尺寸"
        }
    }
}

nonisolated enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case jpeg, png, heic
    var title: String { rawValue == "jpeg" ? "JPG" : rawValue.uppercased() }
    var suffix: String { rawValue == "jpeg" ? "jpg" : rawValue }
    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        }
    }
}

nonisolated struct ExportSettings: Equatable, Codable, Sendable {
    var preset = "custom"
    var dimension: FitDimension = .longest
    var pixels = 1920
    var sharpening = "standard"
    var format: ExportFormat = .jpeg
    var quality = 95.0
    var allowUpscale = false
    var keepMetadata = true
    var removeLocation = true
    var revealAfterExport = true

    /// 这些预设的压缩配方由用途决定，不能被旧设置中的质量或格式覆盖。
    var isPlatformPreset: Bool { preset == "moments" || preset == "redbook" || preset == "douyin" }
    var effectiveFormat: ExportFormat { isPlatformPreset ? .jpeg : format }
    var effectiveQuality: Double { min(100, max(0, quality)) }
    var effectiveAllowUpscale: Bool { isPlatformPreset ? false : allowUpscale }

    mutating func applyPlatformRecipe() {
        guard isPlatformPreset else { return }
        if preset == "moments" { dimension = .shortest; pixels = 1920 }
        else if preset == "douyin" { dimension = .shortest; pixels = 2160 }
        else { dimension = .shortest; pixels = 2560 }
        format = .jpeg
        allowUpscale = false
    }

    var level: OutputSharpeningLevel { OutputSharpeningLevel(rawValue: sharpening) ?? .standard }

    func outputSize(width: Int, height: Int) -> CGSize {
        guard dimension != .original else { return CGSize(width: width, height: height) }
        let w = CGFloat(width), h = CGFloat(height)
        let chosen: CGFloat
        switch dimension {
        case .longest: chosen = max(w, h)
        case .shortest: chosen = min(w, h)
        case .width: chosen = w
        case .height: chosen = h
        case .original: chosen = max(w, h)
        }
        let requested = CGFloat(min(4320, max(320, pixels)))
        if !effectiveAllowUpscale && requested >= chosen { return CGSize(width: width, height: height) }
        let widthIsTarget: Bool
        switch dimension {
        case .longest: widthIsTarget = w >= h
        case .shortest: widthIsTarget = w <= h
        case .width: widthIsTarget = true
        case .height: widthIsTarget = false
        case .original: return CGSize(width: width, height: height)
        }
        // Keep the chosen edge exact; ceil is only applied to the proportional edge.
        if widthIsTarget { return CGSize(width: requested, height: ceil(h * requested / w)) }
        return CGSize(width: ceil(w * requested / h), height: requested)
    }

    var recipeLabel: String {
        dimension == .original ? "原尺寸" : "\(dimension.title) \(pixels) px"
    }
}

nonisolated struct PhotoItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    var width: Int
    var height: Int
    var fileBytes: Int64
    var status: PhotoStatus = .waiting
    var exportedURL: URL?
    var failure: String?
    var outputBytes: Int?
    var name: String { url.deletingPathExtension().lastPathComponent }
}

nonisolated enum PhotoStatus: Sendable { case waiting, processing, done, failed }

nonisolated struct RenderedPhoto: Sendable {
    let width: Int
    let height: Int
    let data: Data
}

nonisolated enum PhotoError: LocalizedError {
    case cannotRead(String), cannotRender, cannotEncode, invalidSize, fileExists, noDemo
    var errorDescription: String? {
        switch self {
        case .cannotRead(let name): return "无法读取“\(name)”。请确认它是受支持的图片。"
        case .cannotRender: return "照片处理失败，请尝试较小的导出尺寸。"
        case .cannotEncode: return "无法保存这个格式，请尝试 JPG 或 PNG。"
        case .invalidSize: return "照片的像素尺寸无效。"
        case .fileExists: return "这个文件已经存在，请使用另一个文件名。"
        case .noDemo: return "示例照片未找到，请添加自己的照片。"
        }
    }
}

nonisolated final class ImagePipeline {
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init() {
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    static func inspect(_ url: URL) throws -> PhotoItem {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw PhotoError.cannotRead(url.lastPathComponent)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = [5, 6, 7, 8].contains(orientation)
        let width = rotated ? rawHeight.intValue : rawWidth.intValue
        let height = rotated ? rawWidth.intValue : rawHeight.intValue
        guard width > 0, height > 0 else { throw PhotoError.invalidSize }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return PhotoItem(url: url, width: width, height: height, fileBytes: bytes)
    }

    func render(_ photo: PhotoItem, settings: ExportSettings) throws -> RenderedPhoto {
        guard let source = CIImage(contentsOf: photo.url, options: [.applyOrientationProperty: true]) else {
            throw PhotoError.cannotRead(photo.url.lastPathComponent)
        }
        let dimensions = settings.outputSize(width: photo.width, height: photo.height)
        let canvas = CGRect(origin: .zero, size: dimensions)
        let normalized = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let scaled: CIImage
        if dimensions == source.extent.size {
            scaled = normalized
        } else {
            let scaleY = dimensions.height / source.extent.height
            let scaleX = dimensions.width / source.extent.width
            // Clamp the sampling boundary to avoid translucent outer pixels on opaque inputs.
            // This boundary fix and the no-upscale option are AoiFit additions.
            scaled = normalized.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / scaleY,
            ]).cropped(to: canvas)
        }
        guard let resized = context.createCGImage(scaled, from: canvas, format: .RGBA8, colorSpace: colorSpace) else {
            throw PhotoError.cannotRender
        }
        let sharpened: CGImage
        if settings.level == .off {
            sharpened = resized
        } else {
            // Preserve the recovered intermediate render before CIUnsharpMask.
            let parameters = settings.level.parameters
            let result = CIImage(cgImage: resized).applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: parameters.radius,
                kCIInputIntensityKey: parameters.intensity,
            ])
            guard let rendered = context.createCGImage(result, from: canvas, format: .RGBA8, colorSpace: colorSpace) else {
                throw PhotoError.cannotRender
            }
            sharpened = rendered
        }
        let metadata = metadataForExport(photo.url, settings: settings, width: sharpened.width, height: sharpened.height)
        let finalData = try encode(sharpened, settings: settings, metadata: metadata)
        return RenderedPhoto(width: sharpened.width, height: sharpened.height, data: finalData)
    }

    private func metadataForExport(_ url: URL, settings: ExportSettings, width: Int, height: Int) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        if settings.keepMetadata, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
                result[key] = original[key]
            }
            if !settings.removeLocation { result[kCGImagePropertyGPSDictionary] = original[kCGImagePropertyGPSDictionary] }
            var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            result[kCGImagePropertyExifDictionary] = exif
            var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        result[kCGImagePropertyPixelWidth] = width
        result[kCGImagePropertyPixelHeight] = height
        result[kCGImagePropertyOrientation] = 1
        return result
    }

    func encode(_ image: CGImage, settings: ExportSettings, metadata: [CFString: Any] = [:]) throws -> Data {
        let imageToEncode: CGImage
        if settings.effectiveFormat == .png {
            imageToEncode = image
        } else {
            // JPG/HEIC get an explicit white background where the input is transparent.
            let input = CIImage(cgImage: image)
            let background = CIImage(color: CIColor.white).cropped(to: input.extent)
            guard let opaque = context.createCGImage(input.composited(over: background), from: input.extent,
                                                      format: .RGBA8, colorSpace: colorSpace) else { throw PhotoError.cannotRender }
            imageToEncode = opaque
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, settings.effectiveFormat.type.identifier as CFString, 1, nil) else {
            throw PhotoError.cannotEncode
        }
        // The recovered scene path first produces a full-quality JPEG, then ImageIO
        // rewrites it from its source while applying metadata. The second stage omits
        // a quality argument; it is not a manually selected 75% export.
        var properties = settings.isPlatformPreset ? [:] : metadata
        if settings.isPlatformPreset {
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        } else if settings.effectiveFormat != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.effectiveQuality / 100
        }
        CGImageDestinationAddImage(destination, imageToEncode, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoError.cannotEncode }
        if settings.isPlatformPreset {
            return try rewrapPlatformJPEG(buffer as Data, metadata: metadata,
                                          width: imageToEncode.width, height: imageToEncode.height)
        }
        return buffer as Data
    }

    private func rewrapPlatformJPEG(_ data: Data, metadata: [CFString: Any], width: Int, height: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw PhotoError.cannotEncode }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoError.cannotEncode
        }
        var properties = metadata
        properties.removeValue(forKey: kCGImageDestinationLossyCompressionQuality)
        properties[kCGImagePropertyPixelWidth] = width
        properties[kCGImagePropertyPixelHeight] = height
        properties[kCGImagePropertyOrientation] = 1
        // Always perform this stage, even when capture metadata is not retained.
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoError.cannotEncode }
        return buffer as Data
    }

    static func write(_ data: Data, to destination: URL) throws {
        // Write beside the destination, then publish the complete file atomically.
        // RENAME_EXCL protects an existing file even if it appears after name selection.
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".aoipic-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                renamex_np(source!, target!, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            let code = errno
            if code == EEXIST { throw PhotoError.fileExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    static func batchDestination(photo: PhotoItem, directory: URL, format: ExportFormat) -> URL {
        let base = photo.name + "_aoipic"
        var url = directory.appendingPathComponent(base).appendingPathExtension(format.suffix)
        var count = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)_\(count)").appendingPathExtension(format.suffix)
            count += 1
        }
        return url
    }
}

extension OutputSharpeningLevel {
    var title: String {
        switch self {
        case .off: return "关闭"
        case .light: return "轻度"
        case .standard: return "标准"
        case .medium: return "中度"
        case .strong: return "强力"
        }
    }
    var detail: String {
        switch self {
        case .off: return "保留缩放后的原始细节"
        case .light: return "轻微增强，适合柔和的人像"
        case .standard: return "适度增强，兼顾细节与自然观感"
        case .medium: return "增强纹理，适合建筑与风景"
        case .strong: return "增强细小边缘，适合需要更多质感的照片"
        }
    }
}

nonisolated func readableBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}
