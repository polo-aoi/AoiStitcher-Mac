import AppKit
import Combine
import Foundation

nonisolated enum LongStitchDirection: String, Codable, CaseIterable, Identifiable {
    case vertical, horizontal

    var id: String { rawValue }
    var title: String { isVertical ? "纵向" : "横向" }
    var isVertical: Bool { self == .vertical }
}

nonisolated enum LongStitchEdge: String, Codable, CaseIterable, Identifiable {
    case top, bottom, left, right

    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: return "顶部"
        case .bottom: return "底部"
        case .left: return "左侧"
        case .right: return "右侧"
        }
    }
}

nonisolated enum LongStitchPanKey: String, Codable, CaseIterable, Identifiable {
    case space, option, command, control

    var id: String { rawValue }
    var title: String {
        switch self {
        case .space: return "空格"
        case .option: return "Option ⌥"
        case .command: return "Command ⌘"
        case .control: return "Control ⌃"
        }
    }
    var keyCode: UInt16? { self == .space ? 49 : nil }
    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .space: return []
        case .option: return .option
        case .command: return .command
        case .control: return .control
        }
    }
}

nonisolated enum LongStitchZoomModifier: String, Codable, CaseIterable, Identifiable {
    case option, command, control

    var id: String { rawValue }
    var title: String {
        switch self {
        case .option: return "Option ⌥"
        case .command: return "Command ⌘"
        case .control: return "Control ⌃"
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .command: return .command
        case .control: return .control
        }
    }
}

nonisolated struct LongStitchMargin: Codable, Equatable {
    var isEnabled = false
    /// Distances are output pixels, independent of preview magnification.
    var size: Double = 150
    var usesWatermark = false
    var watermarkScale: Double = 1
    /// Normalized positions within the remaining room, from -1 to 1.
    var offsetX: Double = 0
    var offsetY: Double = 0

    func sanitized() -> LongStitchMargin {
        var value = self
        value.size = longStitchClamp(size, to: 0...16_384, fallback: 150)
        value.watermarkScale = longStitchClamp(watermarkScale, to: 0.05...5, fallback: 1)
        value.offsetX = longStitchClamp(offsetX, to: -1...1, fallback: 0)
        value.offsetY = longStitchClamp(offsetY, to: -1...1, fallback: 0)
        return value
    }
}

nonisolated struct LongStitchSettings: Codable, Equatable {
    var direction: LongStitchDirection = .vertical
    var spacing: Double = 20
    var top = LongStitchMargin()
    var bottom = LongStitchMargin(isEnabled: true, usesWatermark: true)
    var left = LongStitchMargin()
    var right = LongStitchMargin()
    var watermarkNote = ""
    var exportShortEdge = "2560"
    var exportPNG = true
    var panKey: LongStitchPanKey = .space
    var zoomModifier: LongStitchZoomModifier = .option

    subscript(edge: LongStitchEdge) -> LongStitchMargin {
        get {
            switch edge {
            case .top: return top
            case .bottom: return bottom
            case .left: return left
            case .right: return right
            }
        }
        set {
            switch edge {
            case .top: top = newValue
            case .bottom: bottom = newValue
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }

    func sanitized() -> LongStitchSettings {
        var value = self
        value.spacing = longStitchClamp(spacing, to: 0...16_384, fallback: 20)
        for edge in LongStitchEdge.allCases { value[edge] = self[edge].sanitized() }
        // Keep text edits, including an empty field, so the UI can validate them.
        return value
    }

    var validatedExportShortEdge: Int? {
        guard let value = Int(exportShortEdge.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...16_384).contains(value) else { return nil }
        return value
    }
}

nonisolated private func longStitchClamp(_ value: Double, to range: ClosedRange<Double>,
                                       fallback: Double) -> Double {
    value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
}

@MainActor
final class LongStitchPreferences: ObservableObject {
    static let settingsKey = "longStitchSettings.v1"
    static let shared = LongStitchPreferences(
        defaults: .standard,
        watermarkURL: defaultWatermarkURL
    )

    @Published var settings: LongStitchSettings {
        didSet { persistSettings() }
    }
    @Published private(set) var watermark: NSImage?

    private let defaults: UserDefaults
    private let watermarkURL: URL?

    /// A custom store never reads or overwrites the application's shared image.
    /// Supply a private URL to persist a watermark for a custom defaults suite.
    init(defaults: UserDefaults = .standard, watermarkURL: URL? = nil) {
        self.defaults = defaults
        self.watermarkURL = watermarkURL
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(LongStitchSettings.self, from: data) {
            settings = decoded.sanitized()
        } else {
            settings = LongStitchSettings()
        }
        if let watermarkURL { watermark = NSImage(contentsOf: watermarkURL) }
    }

    func importWatermark(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url),
              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LongStitchRenderError.cannotReadWatermark
        }
        guard let watermarkURL else { throw LongStitchRenderError.watermarkStorageUnavailable }
        let bitmap = NSBitmapImageRep(cgImage: pixels)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw LongStitchRenderError.cannotEncodeWatermark
        }
        do {
            try FileManager.default.createDirectory(at: watermarkURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: watermarkURL, options: .atomic)
        } catch {
            throw LongStitchRenderError.cannotSaveWatermark(error.localizedDescription)
        }
        watermark = NSImage(cgImage: pixels,
                            size: NSSize(width: pixels.width, height: pixels.height))
    }

    func removeWatermark() {
        watermark = nil
        if let watermarkURL { try? FileManager.default.removeItem(at: watermarkURL) }
    }

    func restoreDefaults() {
        settings = LongStitchSettings()
        removeWatermark()
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings.sanitized()) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    private static var defaultWatermarkURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("aoipic/LongStitch/watermark.png")
    }
}

/// All rectangles use output pixels and a top-left origin. Four outer margins
/// never enter the calculation of the photograph content's short edge.
nonisolated struct LongStitchLayout {
    var photoRects: [CGRect]
    var contentRect: CGRect
    var canvasSize: CGSize
    var marginRects: [LongStitchEdge: CGRect]

    init(aspects: [CGFloat], settings: LongStitchSettings) {
        let settings = settings.sanitized()
        let target = CGFloat(settings.validatedExportShortEdge ?? 2560)
        let spacing = CGFloat(settings.spacing)
        let factors = aspects.map { aspect -> CGFloat in
            let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 1
            return settings.direction.isVertical ? 1 / safeAspect : safeAspect
        }
        let totalFactor = factors.reduce(0, +)
        let totalSpacing = CGFloat(max(0, factors.count - 1)) * spacing
        // Usually the cross-axis is the short edge. A single wide photograph,
        // or a short row of portrait photographs, can make the main axis shorter.
        let cross = totalFactor > 0 ? max(target, (target - totalSpacing) / totalFactor) : target
        let main = totalFactor * cross + totalSpacing
        let contentSize = settings.direction.isVertical
            ? CGSize(width: cross, height: main)
            : CGSize(width: main, height: cross)

        let top = settings.top.isEnabled ? CGFloat(settings.top.size) : 0
        let bottom = settings.bottom.isEnabled ? CGFloat(settings.bottom.size) : 0
        let left = settings.left.isEnabled ? CGFloat(settings.left.size) : 0
        let right = settings.right.isEnabled ? CGFloat(settings.right.size) : 0
        contentRect = CGRect(x: left, y: top, width: contentSize.width, height: contentSize.height)
        canvasSize = CGSize(width: ceil(left + contentSize.width + right),
                            height: ceil(top + contentSize.height + bottom))
        marginRects = [
            .top: CGRect(x: 0, y: 0, width: canvasSize.width, height: top),
            .bottom: CGRect(x: 0, y: contentRect.maxY,
                            width: canvasSize.width, height: bottom),
            .left: CGRect(x: 0, y: top, width: left, height: contentSize.height),
            .right: CGRect(x: contentRect.maxX, y: top,
                           width: right, height: contentSize.height)
        ]
        var position: CGFloat = 0
        photoRects = factors.map { factor in
            let length = cross * factor
            let rect = settings.direction.isVertical
                ? CGRect(x: left, y: top + position, width: cross, height: length)
                : CGRect(x: left + position, y: top, width: length, height: cross)
            position += length + spacing
            return rect
        }
    }

    static func watermarkRect(imageSize: CGSize, in region: CGRect,
                              contentShortEdge: CGFloat, margin: LongStitchMargin) -> CGRect {
        guard region.width.isFinite, region.height.isFinite,
              region.width > 0, region.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let margin = margin.sanitized()
        let shortEdge = contentShortEdge.isFinite && contentShortEdge > 0 ? contentShortEdge : 1
        let desiredWidth = shortEdge * 0.3 * CGFloat(margin.watermarkScale)
        let desiredHeight = desiredWidth * imageSize.height / imageSize.width
        let fit = min(1, min(region.width / desiredWidth, region.height / desiredHeight))
        let width = desiredWidth * fit
        let height = desiredHeight * fit
        let x = region.minX + (region.width - width) * CGFloat(margin.offsetX + 1) / 2
        let y = region.minY + (region.height - height) * CGFloat(margin.offsetY + 1) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated enum LongStitchRenderError: LocalizedError {
    case invalidSize
    case tooLarge
    case renderFailed
    case cannotReadImage(Int)
    case cannotReadWatermark
    case cannotEncodeWatermark
    case watermarkStorageUnavailable
    case cannotSaveWatermark(String)

    var errorDescription: String? {
        switch self {
        case .invalidSize: return "长图尺寸无效，请检查照片、间距和留白设置。"
        case .tooLarge: return "长图超过 6400 万像素或单边 131072 像素，请减小短边像素、间距或留白。"
        case .renderFailed: return "无法分配长图所需的内存，请减小短边像素。"
        case .cannotReadImage(let index): return "无法读取第 \(index + 1) 张照片，请重新导入。"
        case .cannotReadWatermark: return "无法读取水印图片，请选择有效的图片文件。"
        case .cannotEncodeWatermark: return "无法保存水印图片，请尝试其他图片。"
        case .watermarkStorageUnavailable: return "水印保存位置不可用。"
        case .cannotSaveWatermark(let reason): return "无法保存水印：\(reason)"
        }
    }
}

nonisolated enum LongStitchRenderer {
    static let maximumDimension = 131_072
    static let maximumPixelCount: Int64 = 64_000_000

    static func render(images: [NSImage], layout: LongStitchLayout,
                       settings: LongStitchSettings, watermark: NSImage?) throws -> NSImage {
        let size = layout.canvasSize
        guard !images.isEmpty, images.count == layout.photoRects.count,
              size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            throw LongStitchRenderError.invalidSize
        }
        guard size.width <= CGFloat(maximumDimension), size.height <= CGFloat(maximumDimension) else {
            throw LongStitchRenderError.tooLarge
        }
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        guard Int64(width) * Int64(height) <= maximumPixelCount else {
            throw LongStitchRenderError.tooLarge
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LongStitchRenderError.renderFailed
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, image) in images.enumerated() {
            guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw LongStitchRenderError.cannotReadImage(index)
            }
            let rect = layout.photoRects[index]
            context.draw(pixels, in: bitmapRect(rect, height: CGFloat(height)))
        }
        if let watermark,
           let pixels = watermark.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let settings = settings.sanitized()
            for edge in LongStitchEdge.allCases {
                let margin = settings[edge]
                guard margin.isEnabled, margin.usesWatermark,
                      let region = layout.marginRects[edge], region.width > 0, region.height > 0 else { continue }
                let rect = LongStitchLayout.watermarkRect(
                    imageSize: watermark.size, in: region,
                    contentShortEdge: min(layout.contentRect.width, layout.contentRect.height),
                    margin: margin
                )
                context.saveGState()
                context.clip(to: bitmapRect(region, height: CGFloat(height)))
                context.draw(pixels, in: bitmapRect(rect, height: CGFloat(height)))
                context.restoreGState()
            }
        }
        guard let image = context.makeImage() else { throw LongStitchRenderError.renderFailed }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    private static func bitmapRect(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
