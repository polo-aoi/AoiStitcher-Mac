import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Raster formats supported by the standard grid collage exporter.
nonisolated enum GridCollageExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg

    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    var type: UTType { self == .jpeg ? .jpeg : .png }
}

nonisolated enum GridCollageExportError: LocalizedError {
    case invalidSize
    case tooLarge
    case renderFailed
    case encodeFailed
    case fileExists
    case cannotReadSource(String)
    case sourceTooLarge(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSize:
            return "导出宽度需为 200 至 16384 像素。"
        case .tooLarge:
            return "拼图超过 6400 万像素或单边 16384 像素，请减小导出宽度。"
        case .renderFailed:
            return "无法分配拼图导出所需的内存，请减小导出宽度。"
        case .encodeFailed:
            return "无法生成图片文件，请重试。"
        case .fileExists:
            return "目标文件已经存在，请选择其他文件名。"
        case .cannotReadSource(let name):
            return "无法读取图片文件“\(name)”，请确认文件仍然可用。"
        case .sourceTooLarge(let name):
            return "图片文件“\(name)”超过 1.6 亿像素，无法安全导出，请先缩小图片。"
        case .writeFailed(let reason):
            return "无法保存拼图：\(reason)"
        }
    }
}

/// Split-tree based raster renderer. Geometry and crop behavior are shared with
/// the interactive view through GridCollageLayoutEngine, so preview and export
/// use the same slot rectangles and image transforms.
nonisolated enum GridCollageRenderer {
    static let logicalCanvasWidth: CGFloat = 1000
    static let maximumDimension = 16_384
    static let maximumPixelCount: Int64 = 64_000_000

    /// Draws a collage in logical canvas coordinates (width 1,000), with the
    /// origin at the upper-left. As with CanvasRenderer, callers drawing into a
    /// raw CGContext should flip its y-axis once; `makeImage` handles that.
    static func draw(_ state: CollageState, in context: CGContext,
                     usePreviewImages: Bool = true) {
        // Interactive drawing intentionally tolerates a missing preview. Final
        // image/export paths below propagate source-file failures to the user.
        try? draw(state, in: context, usePreviewImages: usePreviewImages, opaqueBase: false)
    }

    /// Creates a full-size bitmap at the requested output width. Previews can
    /// request per-slot preview images to keep interactive redraws lightweight.
    static func makeImage(state: CollageState, width: Int,
                          usePreviewImages: Bool = false) throws -> CGImage {
        let size = try outputSize(for: state, width: width)
        guard let context = makeContext(width: Int(size.width), height: Int(size.height)) else {
            throw GridCollageExportError.renderFailed
        }
        // CGContext bitmap space is bottom-up; the renderer's layout remains
        // top-down, matching the crop UI and template geometry.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: size.width / logicalCanvasWidth, y: -size.height / state.logicalSize.height)
        try draw(state, in: context, usePreviewImages: usePreviewImages, opaqueBase: false)
        guard let image = context.makeImage() else { throw GridCollageExportError.renderFailed }
        return image
    }

    /// Encodes and atomically publishes a PNG or JPEG. A destination that
    /// already exists (including one created during export) is never replaced.
    static func export(state: CollageState, width: Int,
                       format: GridCollageExportFormat = .jpeg, to url: URL) throws {
        let size = try outputSize(for: state, width: width)
        guard let context = makeContext(width: Int(size.width), height: Int(size.height)) else {
            throw GridCollageExportError.renderFailed
        }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: size.width / logicalCanvasWidth, y: -size.height / state.logicalSize.height)
        try draw(state, in: context, usePreviewImages: false, opaqueBase: format == .jpeg)
        guard let image = context.makeImage() else { throw GridCollageExportError.renderFailed }

        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, format.type.identifier as CFString, 1, nil) else {
            throw GridCollageExportError.encodeFailed
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw GridCollageExportError.encodeFailed }
        try writeWithoutReplacing(buffer as Data, to: url)
    }

    static func outputSize(for state: CollageState, width: Int) throws -> CGSize {
        let logicalSize = state.logicalSize
        guard (200...maximumDimension).contains(width),
              logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else {
            throw GridCollageExportError.invalidSize
        }
        let height = (CGFloat(width) * logicalSize.height / logicalSize.width).rounded()
        guard height >= 1, height <= CGFloat(maximumDimension),
              Int64(width) * Int64(height) <= maximumPixelCount else {
            throw GridCollageExportError.tooLarge
        }
        return CGSize(width: CGFloat(width), height: height)
    }

    private static func draw(_ state: CollageState, in context: CGContext,
                             usePreviewImages: Bool, opaqueBase: Bool) throws {
        let canvas = CGRect(origin: .zero, size: state.logicalSize)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: canvas)
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        if opaqueBase {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(canvas)
        }
        context.setFillColor(state.style.backgroundColor.cgColor)
        context.fill(canvas)

        try autoreleasepool {
            let background: CGImage?
            if !usePreviewImages, let url = state.style.backgroundImageURL {
                background = try loadOriginal(at: url)
            } else {
                background = state.style.backgroundImage
            }
            if let background {
                let rect = GridCollageLayoutEngine.imageRect(
                    imageSize: CGSize(width: background.width, height: background.height),
                    viewport: canvas, transform: CollageImageTransform(), fill: .cover
                )
                drawImage(background, in: rect, context: context)
            }
        }

        let layout = GridCollageLayoutEngine.layout(state: state, in: canvas)
        let radius = max(0, min(state.style.borderRadius, min(canvas.width, canvas.height) / 2))
        for slotID in state.rootNode.slotIDs {
            guard let slot = state.slots[slotID],
                  let viewport = layout.slotRects[slotID], viewport.width > 0, viewport.height > 0 else { continue }

            // Each full source is loaded, drawn, and released before proceeding
            // to the next slot. A saved edit is the authoritative render source;
            // its immutable original remains available for reopening the editor.
            // A failed edit decode must not silently discard edits or substitute
            // a retained preview for the full-resolution result.
            try autoreleasepool {
                let image: CGImage?
                if usePreviewImages {
                    image = slot.previewImage ?? slot.image
                } else if let url = slot.editedImageURL ?? slot.imageURL {
                    image = try loadOriginal(at: url)
                } else {
                    image = slot.image
                }
                guard let image else { return }
                let slotRadius = min(radius, min(viewport.width, viewport.height) / 2)
                let clipPath = CGPath(roundedRect: viewport,
                                      cornerWidth: slotRadius, cornerHeight: slotRadius,
                                      transform: nil)
                context.saveGState()
                defer { context.restoreGState() }
                context.addPath(clipPath)
                context.clip()
                let imageRect = GridCollageLayoutEngine.imageRect(
                    imageSize: CGSize(width: image.width, height: image.height),
                    viewport: viewport, transform: slot.transform, fill: slot.fill
                )
                drawImage(image, in: imageRect, context: context)
            }
        }
    }

    /// Draws upright CGImages into a top-left-coordinate rectangle.
    private static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(data: nil, width: width, height: height,
                         bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// ImageIO applies EXIF orientation exactly once, matching the loader used
    /// by the rest of aoipic. Decode at source resolution, never at UI resolution.
    private static func loadOriginal(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                     [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else {
            throw GridCollageExportError.cannotReadSource(url.lastPathComponent)
        }
        guard width.doubleValue * height.doubleValue <= 160_000_000 else {
            throw GridCollageExportError.sourceTooLarge(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw GridCollageExportError.cannotReadSource(url.lastPathComponent)
        }
        return image
    }

    private static func writeWithoutReplacing(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".aoipic-grid-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
        } catch {
            throw GridCollageExportError.writeFailed(error.localizedDescription)
        }

        let result = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return -1 }
                return Int(renamex_np(source, target, UInt32(RENAME_EXCL)))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST { throw GridCollageExportError.fileExists }
            throw GridCollageExportError.writeFailed(String(cString: strerror(code)))
        }
    }
}
