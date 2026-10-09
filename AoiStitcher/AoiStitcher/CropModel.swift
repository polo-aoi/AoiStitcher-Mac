import SwiftUI
import Combine
import AppKit

enum CropTool: String, CaseIterable, Identifiable {
    case crop = "裁剪", straighten = "拉直", watermark = "水印"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .crop: return "crop"; case .straighten: return "level"; case .watermark: return "photo.badge.plus" }
    }
}

nonisolated enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    var direction: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: -1, y: -1)
        case .top: return CGPoint(x: 0, y: -1)
        case .topRight: return CGPoint(x: 1, y: -1)
        case .right: return CGPoint(x: 1, y: 0)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom: return CGPoint(x: 0, y: 1)
        case .bottomLeft: return CGPoint(x: -1, y: 1)
        case .left: return CGPoint(x: -1, y: 0)
        }
    }
    func point(on rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX + direction.x * rect.width / 2, y: rect.midY + direction.y * rect.height / 2)
    }
}

struct CropState: Equatable {
    var rect: CGRect
    var imageCenter: CGPoint
    var imageScale: CGFloat = 1
    var quarterTurns = 0
    var straighten: CGFloat = 0
    var preset: CropRatioPreset = .free
    var aspectRatio: CGFloat?
    var watermarks: [OverlayWatermark] = []
    var rotation: CGFloat { CGFloat(quarterTurns) * 90 + straighten }
}

nonisolated enum CropGeometry {
    static func requiredScale(rect: CGRect, imageSize: CGSize, rotation: CGFloat) -> CGFloat {
        let angle = rotation * .pi / 180
        return max((rect.width * abs(cos(angle)) + rect.height * abs(sin(angle))) / imageSize.width,
                   (rect.width * abs(sin(angle)) + rect.height * abs(cos(angle))) / imageSize.height)
    }

    static func clampedCenter(_ center: CGPoint, rect: CGRect, imageSize: CGSize,
                              scale: CGFloat, rotation: CGFloat) -> CGPoint {
        let cropCenter = CGPoint(x: rect.midX, y: rect.midY)
        let relative = CanvasGeometry.localPoint(center, center: cropCenter, rotation: rotation)
        let angle = rotation * .pi / 180
        let limitX = max(0, (imageSize.width * scale - rect.width * abs(cos(angle)) - rect.height * abs(sin(angle))) / 2)
        let limitY = max(0, (imageSize.height * scale - rect.width * abs(sin(angle)) - rect.height * abs(cos(angle))) / 2)
        return CanvasGeometry.worldPoint(CGPoint(x: min(limitX, max(-limitX, relative.x)),
                                                 y: min(limitY, max(-limitY, relative.y))), center: cropCenter, rotation: rotation)
    }

    static func contains(_ rect: CGRect, imageSize: CGSize, center: CGPoint, scale: CGFloat, rotation: CGFloat) -> Bool {
        CropHandle.allCases.filter { $0.direction.x != 0 && $0.direction.y != 0 }.allSatisfy {
            let point = CanvasGeometry.localPoint($0.point(on: rect), center: center, rotation: rotation)
            return abs(point.x) <= imageSize.width * scale / 2 + 0.001 &&
                   abs(point.y) <= imageSize.height * scale / 2 + 0.001
        }
    }

    static func resized(_ rect: CGRect, handle: CropHandle, delta: CGPoint,
                        ratio: CGFloat?, minimum: CGFloat) -> CGRect {
        let sign = handle.direction
        let anchor = CGPoint(x: rect.midX - sign.x * rect.width / 2, y: rect.midY - sign.y * rect.height / 2)
        var width = sign.x == 0 ? rect.width : max(minimum, rect.width + sign.x * delta.x)
        var height = sign.y == 0 ? rect.height : max(minimum, rect.height + sign.y * delta.y)
        if let ratio {
            if sign.x == 0 { width = height * ratio }
            else if sign.y == 0 { height = width / ratio }
            else {
                // Project the pointer onto the aspect-ratio diagonal instead of
                // favoring one axis, so all four corner handles feel identical.
                width = max(minimum, (width + height / ratio) / (1 + 1 / (ratio * ratio)))
                height = width / ratio
            }
            if height < minimum { height = minimum; width = height * ratio }
            if width < minimum { width = minimum; height = width / ratio }
        }
        return CGRect(x: sign.x == 0 ? rect.midX - width / 2 : (sign.x > 0 ? anchor.x : anchor.x - width),
                      y: sign.y == 0 ? rect.midY - height / 2 : (sign.y > 0 ? anchor.y : anchor.y - height),
                      width: width, height: height)
    }

    static func constrainedRect(from start: CGRect, to candidate: CGRect,
                                imageSize: CGSize, center: CGPoint, scale: CGFloat, rotation: CGFloat) -> CGRect {
        if contains(candidate, imageSize: imageSize, center: center, scale: scale, rotation: rotation) { return candidate }
        var lower: CGFloat = 0, upper: CGFloat = 1
        func interpolate(_ amount: CGFloat) -> CGRect {
            CGRect(x: start.minX + (candidate.minX - start.minX) * amount,
                   y: start.minY + (candidate.minY - start.minY) * amount,
                   width: start.width + (candidate.width - start.width) * amount,
                   height: start.height + (candidate.height - start.height) * amount)
        }
        for _ in 0..<32 {
            let middle = (lower + upper) / 2
            if contains(interpolate(middle), imageSize: imageSize, center: center, scale: scale, rotation: rotation) { lower = middle }
            else { upper = middle }
        }
        return interpolate(lower)
    }
}

@MainActor final class CropStore: ObservableObject {
    let item: StitchItem
    let imageSize: CGSize
    let originalImage: CGImage?
    let previewImage: CGImage?
    @Published private(set) var state: CropState
    @Published var tool: CropTool = .crop
    @Published var selectedWatermarkID: UUID?
    @Published var showGrid = true
    @Published var fitRequest = 0
    @Published var displayedZoom: CGFloat = 1
    @Published var isSaving = false
    @Published var message: String?
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    private var undoStack: [CropState] = []
    private var redoStack: [CropState] = []
    private var gestureStart: CropState?
    private var gestureChanged = false
    private(set) var watermarkPreviews: [UUID: CGImage] = [:]

    init(item: StitchItem) {
        self.item = item
        imageSize = item.image.size
        originalImage = item.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        previewImage = originalImage.map { CanvasImageLoader.thumbnail($0, maximum: 1800) }
        let center = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        state = CropState(rect: CGRect(origin: .zero, size: imageSize), imageCenter: center,
                          preset: .original, aspectRatio: imageSize.width / imageSize.height, watermarks: item.watermarks)
        if let info = item.cropInfo, info.scale > 0, info.scale.isFinite {
            let turns = Int((info.rotation / 90).rounded())
            state.rect = CGRect(x: info.uiCropRect.minX / info.scale, y: info.uiCropRect.minY / info.scale,
                                width: info.uiCropRect.width / info.scale, height: info.uiCropRect.height / info.scale)
            state.imageCenter = CGPoint(x: info.imageCenter.x / info.scale, y: info.imageCenter.y / info.scale)
            state.quarterTurns = turns
            state.straighten = CGFloat(info.rotation) - CGFloat(turns) * 90
            state.preset = .free; state.aspectRatio = nil
            coverImage(&state)
        }
        for watermark in state.watermarks { cacheWatermark(watermark) }
    }

    var selectedWatermark: OverlayWatermark? { state.watermarks.first { $0.id == selectedWatermarkID } }
    var minimumImageScale: CGFloat { CropGeometry.requiredScale(rect: state.rect, imageSize: imageSize, rotation: state.rotation) }
    var outputSize: CGSize {
        let pixelsPerUnit = CGFloat(originalImage?.width ?? Int(imageSize.width)) / imageSize.width
        return CGSize(width: (state.rect.width / state.imageScale * pixelsPerUnit).rounded(),
                      height: (state.rect.height / state.imageScale * pixelsPerUnit).rounded())
    }

    func beginChange() { if gestureStart == nil { gestureStart = state; gestureChanged = false } }
    func endChange() { gestureStart = nil; gestureChanged = false }
    func change(_ action: (inout CropState) -> Void) {
        var next = state
        action(&next)
        guard next != state else { return }
        if gestureStart == nil || !gestureChanged {
            undoStack.append(gestureStart ?? state)
            if undoStack.count > 80 { undoStack.removeFirst() }
            redoStack.removeAll()
            gestureChanged = gestureStart != nil
        }
        state = next
        updateHistory()
    }
    private func updateHistory() { undoCount = undoStack.count; redoCount = redoStack.count }
    func undo() {
        endChange()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state); state = previous; updateHistory()
    }
    func redo() {
        endChange()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state); state = next; updateHistory()
    }
    private func coverImage(_ value: inout CropState) {
        value.imageScale = max(value.imageScale, CropGeometry.requiredScale(rect: value.rect, imageSize: imageSize, rotation: value.rotation))
        value.imageCenter = CropGeometry.clampedCenter(value.imageCenter, rect: value.rect, imageSize: imageSize,
                                                       scale: value.imageScale, rotation: value.rotation)
    }
    func moveImage(to center: CGPoint) {
        change { $0.imageCenter = CropGeometry.clampedCenter(center, rect: $0.rect, imageSize: imageSize,
                                                            scale: $0.imageScale, rotation: $0.rotation) }
    }
    func resizeCrop(from initial: CropState, handle: CropHandle, delta: CGPoint, minimum: CGFloat, keepAspect: Bool) {
        let ratio = initial.aspectRatio ?? (keepAspect ? initial.rect.width / initial.rect.height : nil)
        let candidate = CropGeometry.resized(initial.rect, handle: handle, delta: delta, ratio: ratio, minimum: minimum)
        change { $0.rect = CropGeometry.constrainedRect(from: initial.rect, to: candidate, imageSize: imageSize,
                                                       center: initial.imageCenter, scale: initial.imageScale, rotation: initial.rotation) }
    }
    func moveCrop(from initial: CropState, delta: CGPoint) {
        change { $0.rect = CropGeometry.constrainedRect(from: initial.rect, to: initial.rect.offsetBy(dx: delta.x, dy: delta.y),
                                                       imageSize: imageSize, center: initial.imageCenter,
                                                       scale: initial.imageScale, rotation: initial.rotation) }
    }
    func setStraighten(_ angle: CGFloat) {
        guard angle.isFinite else { return }
        let reference = gestureStart ?? state
        change { value in
            value.straighten = min(45, max(-45, angle))
            let pivot = CGPoint(x: reference.rect.midX, y: reference.rect.midY)
            let offset = CanvasGeometry.rotate(CGPoint(x: reference.imageCenter.x - pivot.x,
                                                       y: reference.imageCenter.y - pivot.y),
                                               by: value.straighten - reference.straighten)
            value.imageScale = max(reference.imageScale,
                                   CropGeometry.requiredScale(rect: value.rect, imageSize: imageSize, rotation: value.rotation))
            let factor = value.imageScale / reference.imageScale
            value.imageCenter = CGPoint(x: pivot.x + offset.x * factor, y: pivot.y + offset.y * factor)
            coverImage(&value)
        }
    }
    func setImageScale(_ scale: CGFloat, around point: CGPoint? = nil) {
        guard scale.isFinite else { return }
        change { value in
            let minimum = CropGeometry.requiredScale(rect: value.rect, imageSize: imageSize, rotation: value.rotation)
            let next = min(max(8, minimum), max(minimum, scale))
            let anchor = point ?? CGPoint(x: value.rect.midX, y: value.rect.midY)
            let factor = next / value.imageScale
            value.imageCenter = CGPoint(x: anchor.x + (value.imageCenter.x - anchor.x) * factor,
                                        y: anchor.y + (value.imageCenter.y - anchor.y) * factor)
            value.imageScale = next
            coverImage(&value)
        }
    }
    func applyPreset(_ preset: CropRatioPreset) {
        change { value in
            value.preset = preset
            value.aspectRatio = preset == .original ? (value.quarterTurns % 2 == 0 ? imageSize.width / imageSize.height : imageSize.height / imageSize.width) : preset.ratioValue
            guard let ratio = value.aspectRatio else { return }
            let width = min(value.rect.width, value.rect.height * ratio)
            value.rect = CGRect(x: value.rect.midX - width / 2, y: value.rect.midY - width / ratio / 2,
                                width: width, height: width / ratio)
            coverImage(&value)
        }
    }
    func swapAspect() {
        change { value in
            let ratio = value.rect.height / value.rect.width
            let width = min(value.rect.width, value.rect.height * ratio)
            value.rect = CGRect(x: value.rect.midX - width / 2, y: value.rect.midY - width / ratio / 2, width: width, height: width / ratio)
            if value.aspectRatio != nil {
                value.aspectRatio = ratio
                value.preset = CropRatioPreset.allCases.first { $0.ratioValue.map { abs($0 - ratio) < 0.000001 } ?? false } ?? .free
            }
            coverImage(&value)
        }
    }
    func rotateQuarter() {
        change { value in
            let cropCenter = CGPoint(x: value.rect.midX, y: value.rect.midY)
            let relative = CanvasGeometry.rotate(CGPoint(x: value.imageCenter.x - cropCenter.x,
                                                         y: value.imageCenter.y - cropCenter.y), by: 90)
            value.rect = CGRect(x: cropCenter.x - value.rect.height / 2, y: cropCenter.y - value.rect.width / 2,
                                width: value.rect.height, height: value.rect.width)
            value.imageCenter = CGPoint(x: cropCenter.x + relative.x, y: cropCenter.y + relative.y)
            value.quarterTurns = (value.quarterTurns + 1) % 4
            if let ratio = value.aspectRatio {
                value.aspectRatio = 1 / ratio
                if value.preset != .original {
                    value.preset = CropRatioPreset.allCases.first { $0.ratioValue.map { abs($0 - 1 / ratio) < 0.000001 } ?? false } ?? .free
                }
            }
            coverImage(&value)
        }
        fitRequest += 1
    }
    func reset() {
        change {
            $0.rect = CGRect(origin: .zero, size: imageSize)
            $0.imageCenter = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
            $0.imageScale = 1; $0.quarterTurns = 0; $0.straighten = 0
            $0.preset = .original; $0.aspectRatio = imageSize.width / imageSize.height
        }
        fitRequest += 1
    }
    func setCropSize(width: CGFloat, height: CGFloat) {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return }
        let units = state.imageScale * imageSize.width / CGFloat(originalImage?.width ?? Int(imageSize.width))
        change { value in
            value.rect = CGRect(x: value.rect.midX - width * units / 2, y: value.rect.midY - height * units / 2,
                                width: width * units, height: height * units)
            value.preset = .free; value.aspectRatio = nil
            coverImage(&value)
        }
    }
    private func cacheWatermark(_ watermark: OverlayWatermark) {
        if let image = watermark.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            watermarkPreviews[watermark.id] = CanvasImageLoader.thumbnail(image, maximum: 600)
        }
    }
    func addWatermark(_ image: NSImage) {
        let watermark = OverlayWatermark(image: image)
        cacheWatermark(watermark)
        change { $0.watermarks.append(watermark) }
        selectedWatermarkID = watermark.id; tool = .watermark
    }
    func editWatermark(_ id: UUID, _ action: (inout OverlayWatermark) -> Void) {
        change { value in
            guard let index = value.watermarks.firstIndex(where: { $0.id == id }) else { return }
            action(&value.watermarks[index])
        }
    }
    func deleteWatermark() {
        guard let id = selectedWatermarkID else { return }
        change { $0.watermarks.removeAll { $0.id == id } }; selectedWatermarkID = nil
    }
    func makeItem(image: CGImage, savedState: CropState? = nil) -> StitchItem {
        let state = savedState ?? state
        var updated = item
        updated.cropInfo = CropInfo(uiCropRect: state.rect, rotation: Double(state.rotation),
                                    imageCenter: state.imageCenter, scale: state.imageScale)
        updated.watermarks = state.watermarks
        updated.croppedImage = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        return updated
    }
}

nonisolated struct CropRenderWatermark {
    var image: CGImage
    var offset: CGSize
    var scale: CGFloat
    var rotation: Double
}

nonisolated struct CropRenderSnapshot {
    var image: CGImage
    var imageSize: CGSize
    var rect: CGRect
    var center: CGPoint
    var scale: CGFloat
    var rotation: CGFloat
    var watermarks: [CropRenderWatermark]
    @MainActor init?(_ store: CropStore, preview: Bool = false) {
        guard let image = preview ? store.previewImage : store.originalImage else { return nil }
        self.image = image; imageSize = store.imageSize
        rect = store.state.rect; center = store.state.imageCenter
        scale = store.state.imageScale; rotation = store.state.rotation
        watermarks = store.state.watermarks.compactMap { watermark in
            let image = preview ? store.watermarkPreviews[watermark.id] : watermark.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            guard let image else { return nil }
            return CropRenderWatermark(image: image, offset: watermark.offset, scale: watermark.scale, rotation: watermark.rotation)
        }
    }
}

nonisolated enum CropRenderer {
    static func draw(_ snapshot: CropRenderSnapshot, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: snapshot.center.x, y: snapshot.center.y)
        context.rotate(by: snapshot.rotation * .pi / 180)
        context.scaleBy(x: snapshot.scale, y: snapshot.scale)
        CanvasRenderer.drawImage(snapshot.image, in: CGRect(x: -snapshot.imageSize.width / 2, y: -snapshot.imageSize.height / 2,
                                                            width: snapshot.imageSize.width, height: snapshot.imageSize.height), context: context)
        for watermark in snapshot.watermarks {
            context.saveGState()
            context.translateBy(x: watermark.offset.width, y: watermark.offset.height)
            context.rotate(by: CGFloat(watermark.rotation) * .pi / 180)
            let width = snapshot.imageSize.width * 0.3 * watermark.scale
            let height = width * CGFloat(watermark.image.height) / CGFloat(watermark.image.width)
            CanvasRenderer.drawImage(watermark.image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), context: context)
            context.restoreGState()
        }
        context.restoreGState()
    }
    static func makeImage(_ snapshot: CropRenderSnapshot) throws -> CGImage {
        let factor = CGFloat(snapshot.image.width) / snapshot.imageSize.width / snapshot.scale
        let width = max(1, Int((snapshot.rect.width * factor).rounded()))
        let height = max(1, Int((snapshot.rect.height * factor).rounded()))
        guard width <= 16384, height <= 16384, Double(width) * Double(height) <= 64_000_000 else { throw CanvasExportError.tooLarge }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CanvasExportError.renderFailed }
        context.setFillColor(CGColor.white); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: CGFloat(width) / snapshot.rect.width, y: -CGFloat(height) / snapshot.rect.height)
        context.translateBy(x: -snapshot.rect.minX, y: -snapshot.rect.minY)
        draw(snapshot, in: context)
        guard let image = context.makeImage() else { throw CanvasExportError.renderFailed }
        return image
    }
}
