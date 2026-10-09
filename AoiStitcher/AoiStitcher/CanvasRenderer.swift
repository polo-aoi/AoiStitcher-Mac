import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct CanvasRenderLayer {
    var image: CGImage?
    var texture: CGImage?
    var center: CGPoint
    var size: CGSize
    var rotation: CGFloat
    var opacity: CGFloat
    var color: CanvasColor

    @MainActor init(_ layer: CanvasLayer, preview: Bool) {
        image = preview ? (layer.previewImage ?? layer.image) : layer.image
        texture = layer.texture; center = layer.center; size = layer.size
        rotation = layer.rotation; opacity = layer.opacity; color = layer.color
    }
}

nonisolated struct CanvasRenderSnapshot {
    var size: CGSize
    var background: CanvasColor
    var layers: [CanvasRenderLayer]
    @MainActor init(_ document: CanvasDocument, preview: Bool = false) {
        size = document.size; background = document.background
        layers = document.layers.map { CanvasRenderLayer($0, preview: preview) }
    }
}

nonisolated enum CanvasExportError: LocalizedError {
    case invalidSize, tooLarge, renderFailed, encodeFailed
    var errorDescription: String? {
        switch self {
        case .invalidSize: return "导出宽度需为 200 至 16384 的整数。"
        case .tooLarge: return "导出尺寸超过 6400 万像素或单边 16384 像素，请减小导出宽度或调整画布比例。"
        case .renderFailed: return "无法分配导出图片所需的内存，请减小导出宽度。"
        case .encodeFailed: return "无法生成图片文件，请重试。"
        }
    }
}

nonisolated enum CanvasRenderer {
    // All callers use top-left coordinates, including the bitmap exporter.
    static func draw(_ snapshot: CanvasRenderSnapshot, in context: CGContext) {
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: snapshot.size))
        context.setFillColor(snapshot.background.cgColor)
        context.fill(CGRect(origin: .zero, size: snapshot.size))
        context.interpolationQuality = .high
        for layer in snapshot.layers {
            context.saveGState()
            context.translateBy(x: layer.center.x, y: layer.center.y)
            context.rotate(by: layer.rotation * .pi / 180)
            context.setAlpha(layer.opacity)
            let rectangle = CGRect(x: -layer.size.width / 2, y: -layer.size.height / 2,
                                   width: layer.size.width, height: layer.size.height)
            if let image = layer.image {
                drawImage(image, in: rectangle, context: context)
            } else {
                context.setFillColor(layer.color.cgColor); context.fill(rectangle)
                if let texture = layer.texture {
                    context.setBlendMode(.multiply)
                    drawImage(texture, in: rectangle, context: context)
                }
            }
            context.restoreGState()
        }
        context.restoreGState()
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        // Quartz image data is bottom-up; flip locally to keep photographs upright.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func outputSize(for snapshot: CanvasRenderSnapshot, width: Int) throws -> CGSize {
        guard (200...16384).contains(width), snapshot.size.width > 0, snapshot.size.height > 0 else {
            throw CanvasExportError.invalidSize
        }
        let height = (CGFloat(width) * snapshot.size.height / snapshot.size.width).rounded()
        guard height >= 1, height <= 16384, CGFloat(width) * height <= 64_000_000 else {
            throw CanvasExportError.tooLarge
        }
        return CGSize(width: CGFloat(width), height: height)
    }

    static func makeImage(_ snapshot: CanvasRenderSnapshot, width: Int) throws -> CGImage {
        let size = try outputSize(for: snapshot, width: width)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CanvasExportError.renderFailed
        }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: size.width / snapshot.size.width, y: -size.height / snapshot.size.height)
        draw(snapshot, in: context)
        guard let image = context.makeImage() else { throw CanvasExportError.renderFailed }
        return image
    }

    static func export(_ snapshot: CanvasRenderSnapshot, width: Int, png: Bool, to url: URL) throws {
        let image = try makeImage(snapshot, width: width)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else {
            throw CanvasExportError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CanvasExportError.encodeFailed }
        try (data as Data).write(to: url, options: .atomic)
    }
}
