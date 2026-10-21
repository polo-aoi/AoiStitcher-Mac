import SwiftUI
import Combine
import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct CanvasColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .white
        red = rgb.redComponent; green = rgb.greenComponent
        blue = rgb.blueComponent; alpha = rgb.alphaComponent
    }

    var nsColor: NSColor { NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { nsColor.cgColor }
    static let white = CanvasColor(.white)
}

nonisolated enum CanvasLayerKind: String { case photo, paper }
nonisolated enum CanvasAspectRatio: String, CaseIterable, Identifiable {
    case square = "1:1", landscapePhoto = "3:2", portraitPhoto = "2:3"
    case landscape = "4:3", portrait = "3:4", widescreen = "16:9", tall = "9:16"
    case custom = "自定义"
    var id: String { rawValue }
    var value: CGFloat? {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        return CGFloat(width / height)
    }

    /// Logical composition dimensions. Export pixels are selected separately.
    func size(forWidth width: CGFloat) -> CGSize? {
        guard let ratio = value, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: width / ratio)
    }

    static func ratio(width: CGFloat, height: CGFloat) -> CGFloat? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return width / height
    }

    static func matching(_ size: CGSize) -> Self {
        guard let ratio = ratio(width: size.width, height: size.height) else { return .custom }
        return allCases.first { preset in
            guard let value = preset.value else { return false }
            return abs(ratio - value) < 0.000001
        } ?? .custom
    }
}

/// Canvas layers are stored in paint order (bottom to top). Papers are a
/// dedicated background group and must never paint above photos.
nonisolated enum CanvasLayerOrdering {
    static func normalized(_ layers: [CanvasLayer]) -> [CanvasLayer] {
        layers.filter { $0.kind == .paper } + layers.filter { $0.kind == .photo }
    }
}

nonisolated enum CanvasPaperStyle: String, CaseIterable, Identifiable {
    case plain = "纯色色纸", warm = "米色纸", fiber = "纤维纸", grid = "方格纸"
    var id: String { rawValue }
    var color: CanvasColor {
        switch self {
        case .plain: return .white
        case .warm: return CanvasColor(NSColor(deviceRed: 0.95, green: 0.91, blue: 0.82, alpha: 1))
        case .fiber: return CanvasColor(NSColor(deviceRed: 0.93, green: 0.94, blue: 0.92, alpha: 1))
        case .grid: return CanvasColor(NSColor(deviceWhite: 0.98, alpha: 1))
        }
    }
}

struct CanvasLayer: Identifiable {
    var id = UUID()
    var name: String
    var kind: CanvasLayerKind
    var image: CGImage?
    var previewImage: CGImage?
    var texture: CGImage?
    var photo: StitchItem?
    var center: CGPoint
    var size: CGSize
    var rotation: CGFloat = 0
    var opacity: CGFloat = 1
    var locked = false
    var color: CanvasColor = .white
    var preservesAspect: Bool { kind == .photo || image != nil }
}

struct CanvasDocument {
    var size = CGSize(width: 800, height: 600)
    var background = CanvasColor.white
    // Additive field for newer documents; legacy documents infer this from
    // their color and paper layers.
    var backgroundIsExplicit = false
    // Array order is the paint order, bottom to top.
    var layers: [CanvasLayer] = []

    // Keep the pre-backgroundIsExplicit memberwise call shape available to
    // project files and older callers.
    init(size: CGSize = CGSize(width: 800, height: 600),
         background: CanvasColor = .white,
         layers: [CanvasLayer] = [],
         backgroundIsExplicit: Bool = false) {
        self.size = size
        self.background = background
        self.layers = layers
        self.backgroundIsExplicit = backgroundIsExplicit
    }

    var aspectRatio: CGFloat { size.width / max(1, size.height) }
    var aspectPreset: CanvasAspectRatio { CanvasAspectRatio.matching(size) }
}

nonisolated enum CanvasGeometry {
    static func rotate(_ point: CGPoint, by degrees: CGFloat) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: point.x * cos(angle) - point.y * sin(angle),
                       y: point.x * sin(angle) + point.y * cos(angle))
    }

    static func localPoint(_ point: CGPoint, center: CGPoint, rotation: CGFloat) -> CGPoint {
        rotate(CGPoint(x: point.x - center.x, y: point.y - center.y), by: -rotation)
    }

    static func worldPoint(_ point: CGPoint, center: CGPoint, rotation: CGFloat) -> CGPoint {
        let rotated = rotate(point, by: rotation)
        return CGPoint(x: center.x + rotated.x, y: center.y + rotated.y)
    }
}

nonisolated struct CanvasLoadedImage {
    var url: URL
    var image: CGImage
    var preview: CGImage
}

nonisolated enum CanvasImageLoader {
    static func load(_ url: URL) -> CanvasLoadedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        // Decode with EXIF orientation applied, retaining the original pixel dimensions.
        let longest = max(width.intValue, height.intValue)
        guard longest > 0, Double(width.intValue) * Double(height.intValue) <= 160_000_000 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return CanvasLoadedImage(url: url, image: full, preview: thumbnail(full))
    }

    static func thumbnail(_ image: CGImage, maximum: CGFloat = 1600) -> CGImage {
        let scale = min(1, maximum / CGFloat(max(image.width, image.height)))
        guard scale < 1,
              let context = CGContext(data: nil, width: max(1, Int(CGFloat(image.width) * scale)),
                                      height: max(1, Int(CGFloat(image.height) * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage() ?? image
    }

    static func paperTexture(_ style: CanvasPaperStyle) -> CGImage? {
        guard style != .plain else { return nil }
        let side = 512
        var seed: UInt32 = 42
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for index in stride(from: 0, to: side * side * 4, by: 4) {
            seed = seed &* 1664525 &+ 1013904223
            let grain = UInt8(225 + seed % 31)
            pixels[index] = grain; pixels[index + 1] = grain; pixels[index + 2] = grain
            pixels[index + 3] = 255
        }
        if style == .grid {
            context.setStrokeColor(CGColor(gray: 0.65, alpha: 1)); context.setLineWidth(0.7)
            for coordinate in stride(from: 0, through: side, by: 32) {
                context.move(to: CGPoint(x: coordinate, y: 0)); context.addLine(to: CGPoint(x: coordinate, y: side))
                context.move(to: CGPoint(x: 0, y: coordinate)); context.addLine(to: CGPoint(x: side, y: coordinate))
            }
            context.strokePath()
        } else if style == .fiber {
            context.setStrokeColor(CGColor(gray: 0.76, alpha: 0.5)); context.setLineWidth(0.6)
            for _ in 0..<1400 {
                seed = seed &* 1664525 &+ 1013904223
                let x = CGFloat(seed % 512)
                seed = seed &* 1664525 &+ 1013904223
                let y = CGFloat(seed % 512)
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + CGFloat(seed % 12) - 6, y: y + CGFloat(seed % 5) - 2))
            }
            context.strokePath()
        }
        return context.makeImage()
    }
}

@MainActor final class CanvasStore: ObservableObject {
    static let maximumPaperLayers = 5
    @Published private(set) var document = CanvasDocument()
    @Published var selectedID: UUID?
    @Published var isLoading = false
    @Published var isExporting = false
    @Published var message: String?
    @Published var fitRequest = 0
    @Published var displayedZoom: CGFloat = 1
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    private var undoStack: [CanvasDocument] = []
    private var redoStack: [CanvasDocument] = []
    private var continuousChange = false
    var selectedLayer: CanvasLayer? { document.layers.first { $0.id == selectedID } }
    var photoCount: Int { document.layers.filter { $0.kind == .photo }.count }
    var paperCount: Int { document.layers.filter { $0.kind == .paper }.count }

    /// The default white canvas is treated as unset so a lone photo can ask
    /// for confirmation before export. A paper or explicit color counts as a
    /// background material.
    var hasBackground: Bool {
        paperCount > 0 || document.backgroundIsExplicit || document.background != .white
    }
    var shouldWarnMissingBackground: Bool { photoCount > 0 && !hasBackground }
    var missingBackgroundMessage: String? {
        shouldWarnMissingBackground ? "当前没有背景，是否继续导出？" : nil
    }

    func setBackground(_ color: CanvasColor) {
        mutate { doc in
            doc.background = color
            doc.backgroundIsExplicit = true
        }
    }

    func clearBackground() {
        mutate { doc in
            doc.background = .white
            doc.backgroundIsExplicit = false
        }
    }

    func mutate(_ action: (inout CanvasDocument) -> Void) {
        if !continuousChange { rememberChange() }
        let oldBackground = document.background
        action(&document)
        if document.background != oldBackground { document.backgroundIsExplicit = true }
        document.layers = CanvasLayerOrdering.normalized(document.layers)
    }

    private func rememberChange() {
        undoStack.append(document)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateHistoryCounts()
    }

    func beginContinuousChange() {
        guard !continuousChange else { return }
        rememberChange(); continuousChange = true
    }

    func endContinuousChange() { continuousChange = false }
    private func updateHistoryCounts() { undoCount = undoStack.count; redoCount = redoStack.count }
    func undo() {
        endContinuousChange()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document); document = previous; validateSelection(); updateHistoryCounts()
    }

    func redo() {
        endContinuousChange()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document); document = next; validateSelection(); updateHistoryCounts()
    }

    private func validateSelection() {
        if !document.layers.contains(where: { $0.id == selectedID }) { selectedID = nil }
    }

    func editSelected(_ action: (inout CanvasLayer) -> Void) {
        guard let id = selectedID else { return }
        editLayer(id, action)
    }

    func editLayer(_ id: UUID, _ action: (inout CanvasLayer) -> Void) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }),
              !document.layers[index].locked else { return }
        mutate { action(&$0.layers[index]) }
    }

    func resizeCanvas(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        let newSize = CGSize(width: min(8000, max(200, size.width)), height: min(8000, max(200, size.height)))
        guard newSize != document.size else { return }
        mutate { doc in
            let sx = newSize.width / doc.size.width, sy = newSize.height / doc.size.height
            for index in doc.layers.indices where !doc.layers[index].locked {
                doc.layers[index].center.x *= sx; doc.layers[index].center.y *= sy
                doc.layers[index].size.width *= min(sx, sy); doc.layers[index].size.height *= min(sx, sy)
            }
            doc.size = newSize
        }
        fitRequest += 1
    }

    /// Applies a preset ratio while retaining the current logical canvas
    /// width. Export pixels remain controlled by the export-width setting.
    func resizeCanvas(to ratio: CanvasAspectRatio) {
        guard let size = ratio.size(forWidth: document.size.width) else { return }
        resizeCanvas(size)
    }

    /// Applies a custom ratio while retaining the current logical canvas width.
    func resizeCanvas(toRatio ratio: CGFloat) {
        guard ratio.isFinite, ratio > 0 else { return }
        resizeCanvas(CGSize(width: document.size.width, height: document.size.width / ratio))
    }

    func swapCanvasOrientation() {
        let oldSize = document.size
        guard oldSize.width != oldSize.height else { return }
        let newSize = CGSize(width: oldSize.height, height: oldSize.width)
        // Resize the sheet around its center. Photos keep their size and rotation.
        let offset = CGPoint(x: (newSize.width - oldSize.width) / 2,
                             y: (newSize.height - oldSize.height) / 2)
        mutate { doc in
            doc.size = newSize
            for index in doc.layers.indices where !doc.layers[index].locked {
                doc.layers[index].center.x += offset.x
                doc.layers[index].center.y += offset.y
            }
        }
        fitRequest += 1
    }

    @discardableResult func addPaper(_ style: CanvasPaperStyle) -> Bool {
        guard paperCount < Self.maximumPaperLayers else {
            message = "底图最多添加 \(Self.maximumPaperLayers) 层。"
            return false
        }
        let layer = CanvasLayer(name: style.rawValue, kind: .paper,
                                texture: CanvasImageLoader.paperTexture(style),
                                center: CGPoint(x: document.size.width / 2, y: document.size.height / 2),
                                size: document.size, color: style.color)
        mutate { doc in
            let firstPhoto = doc.layers.firstIndex { $0.kind == .photo } ?? doc.layers.count
            doc.layers.insert(layer, at: firstPhoto)
        }
        selectedID = layer.id
        return true
    }

    func importImages(as kind: CanvasLayerKind = .photo) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = kind == .photo ? "选择要放入画布的照片" : "选择纸张纹理或背景图片"
        if panel.runModal() == .OK { importURLs(panel.urls, as: kind) }
    }

    func importURLs(_ urls: [URL], as kind: CanvasLayerKind = .photo, at point: CGPoint? = nil) {
        guard !urls.isEmpty, !isLoading else { return }
        isLoading = true
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = urls.compactMap { CanvasImageLoader.load($0) }
            accessed.forEach { $0.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                self.isLoading = false
                self.addLoadedImages(loaded, as: kind, at: point)
                let failures = urls.count - loaded.count
                if failures > 0 { self.message = "有 \(failures) 个文件未能读取。请使用 PNG、JPEG、HEIC 或 TIFF 图片，单张图片不超过 1.6 亿像素。" }
            }
        }
    }

    func addLoadedImages(_ loaded: [CanvasLoadedImage], as kind: CanvasLayerKind, at point: CGPoint? = nil) {
        guard !loaded.isEmpty else { return }
        let assets: ArraySlice<CanvasLoadedImage>
        if kind == .paper {
            let available = max(0, Self.maximumPaperLayers - paperCount)
            guard available > 0 else {
                message = "底图最多添加 \(Self.maximumPaperLayers) 层。"
                return
            }
            assets = loaded.prefix(available)
            if loaded.count > available {
                message = "已添加 \(available) 张底图，底图最多保留 \(Self.maximumPaperLayers) 层。"
            }
        } else {
            assets = loaded[...]
        }
        let wasEmpty = photoCount == 0
        beginContinuousChange()
        for (index, asset) in assets.enumerated() {
            let aspect = CGFloat(asset.image.width) / CGFloat(asset.image.height)
            let width = min(document.size.width * 0.42, document.size.height * 0.7 * aspect)
            let offset = CGFloat(index % 8) * 20
            let center = point.map { CGPoint(x: $0.x + offset, y: $0.y + offset) }
                ?? CGPoint(x: document.size.width / 2 + offset, y: document.size.height / 2 + offset)
            let image = NSImage(cgImage: asset.image, size: CGSize(width: asset.image.width, height: asset.image.height))
            let layer = CanvasLayer(name: asset.url.lastPathComponent, kind: kind,
                                    image: asset.image, previewImage: asset.preview,
                                    photo: kind == .photo ? StitchItem(url: asset.url, image: image) : nil,
                                    center: center,
                                    size: kind == .paper ? fittedSize(aspect: aspect, in: document.size) : CGSize(width: width, height: width / aspect))
            mutate { doc in
                if kind == .paper {
                    // Paint order is bottom-to-top: insert after existing
                    // papers so a new paper sits above old papers but below
                    // every photo.
                    let firstPhoto = doc.layers.firstIndex { $0.kind == .photo } ?? doc.layers.count
                    doc.layers.insert(layer, at: firstPhoto)
                } else {
                    doc.layers.append(layer)
                }
            }
            selectedID = layer.id
        }
        if kind == .photo && wasEmpty && point == nil { arrange(horizontal: true, margin: 40, gap: 24, split: 0.5) }
        endContinuousChange()
        if wasEmpty { fitRequest += 1 }
    }

    func arrange(horizontal: Bool, margin: CGFloat, gap: CGFloat, split: CGFloat) {
        let indices = document.layers.indices.filter { document.layers[$0].kind == .photo && !document.layers[$0].locked }
        guard !indices.isEmpty else { return }
        mutate { doc in
            let dimension = horizontal ? doc.size.width : doc.size.height
            let otherDimension = horizontal ? doc.size.height : doc.size.width
            let safeMargin = min(max(0, margin), min(dimension, otherDimension) * 0.4)
            let available = dimension - safeMargin * 2
            let safeGap = min(max(0, gap), available / CGFloat(max(1, indices.count * 2)))
            let content = available - CGFloat(indices.count - 1) * safeGap
            var position = safeMargin
            for (order, index) in indices.enumerated() {
                let weight = indices.count == 2 ? (order == 0 ? min(0.85, max(0.15, split)) : 1 - min(0.85, max(0.15, split))) : 1 / CGFloat(indices.count)
                let length = content * weight
                let box = horizontal ? CGSize(width: length, height: otherDimension - safeMargin * 2)
                                     : CGSize(width: otherDimension - safeMargin * 2, height: length)
                let aspect = doc.layers[index].size.width / max(1, doc.layers[index].size.height)
                doc.layers[index].size = fittedSize(aspect: aspect, in: box)
                doc.layers[index].center = horizontal ? CGPoint(x: position + length / 2, y: otherDimension / 2)
                                                       : CGPoint(x: otherDimension / 2, y: position + length / 2)
                doc.layers[index].rotation = 0
                position += length + safeGap
            }
        }
    }

    private func fittedSize(aspect: CGFloat, in box: CGSize, fill: Bool = false) -> CGSize {
        let width = fill ? max(box.width, box.height * aspect) : min(box.width, box.height * aspect)
        return CGSize(width: max(1, width), height: max(1, width / max(0.001, aspect)))
    }

    func fitSelected(fill: Bool) {
        guard let layer = selectedLayer else { return }
        let size = layer.preservesAspect ? fittedSize(aspect: layer.size.width / layer.size.height, in: document.size, fill: fill) : document.size
        let center = CGPoint(x: document.size.width / 2, y: document.size.height / 2)
        editSelected { $0.size = size; $0.center = center; $0.rotation = 0 }
    }

    func centerSelected() {
        let center = CGPoint(x: document.size.width / 2, y: document.size.height / 2)
        editSelected { $0.center = center }
    }

    func duplicateSelected() {
        guard var layer = selectedLayer else { return }
        if layer.kind == .paper && paperCount >= Self.maximumPaperLayers {
            message = "底图最多添加 \(Self.maximumPaperLayers) 层。"
            return
        }
        layer.id = UUID(); layer.name += " 副本"; layer.locked = false
        layer.center.x += 20; layer.center.y += 20
        mutate { doc in
            let index = doc.layers.firstIndex(where: { $0.id == selectedID }) ?? doc.layers.count - 1
            doc.layers.insert(layer, at: min(doc.layers.count, index + 1))
        }
        selectedID = layer.id
    }

    func deleteSelected() {
        guard let layer = selectedLayer, !layer.locked else { return }
        mutate { $0.layers.removeAll { $0.id == layer.id } }; selectedID = nil
    }

    func toggleLock(_ id: UUID) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        mutate { $0.layers[index].locked.toggle() }
    }

    func reorderSelected(toTop: Bool) {
        guard let id = selectedID else { return }
        let rows = Array(CanvasLayerOrdering.normalized(document.layers).reversed())
        guard let layer = rows.first(where: { $0.id == id }) else { return }
        let photoRows = rows.filter { $0.kind == .photo }.count
        let index = toTop ? (layer.kind == .photo ? 0 : photoRows) : (layer.kind == .photo ? photoRows : rows.count)
        moveLayer(id, toListInsertionIndex: index)
    }

    // The list is top to bottom. The insertion index refers to the gap before
    // removing the dragged row, as supplied by NSTableView's drop indicator.
    @discardableResult func moveLayer(_ id: UUID, toListInsertionIndex insertion: Int) -> Bool {
        var layers = Array(CanvasLayerOrdering.normalized(document.layers).reversed())
        guard (0...layers.count).contains(insertion),
              let source = layers.firstIndex(where: { $0.id == id }),
              !layers[source].locked else { return false }
        let photoRows = layers.filter { $0.kind == .photo }.count
        let kind = layers[source].kind
        let lowerBound = kind == .photo ? 0 : photoRows
        let upperBound = kind == .photo ? photoRows : layers.count
        // A drop across the paper/photo boundary is clamped to the nearest
        // legal gap so the layer invariant cannot be violated.
        let legalInsertion = min(upperBound, max(lowerBound, insertion))
        let destination = legalInsertion > source ? legalInsertion - 1 : legalInsertion
        guard destination != source else { return false }
        let layer = layers.remove(at: source)
        layers.insert(layer, at: destination)
        mutate { $0.layers = Array(layers.reversed()) }
        selectedID = id
        return true
    }

    func updateCrop(_ item: StitchItem, layerID: UUID) {
        guard let image = item.displayImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        editLayer(layerID) {
            $0.photo = item; $0.image = image; $0.previewImage = CanvasImageLoader.thumbnail(image)
            $0.size.height = $0.size.width * CGFloat(image.height) / CGFloat(image.width)
        }
    }

    func clear() { mutate { $0.layers.removeAll() }; selectedID = nil }
}
