import SwiftUI
import AppKit

struct CanvasWorkspace: NSViewRepresentable {
    @ObservedObject var store: CanvasStore
    var isActive: Bool
    var onCrop: (CanvasLayer) -> Void
    var onInspect: (CanvasLayer) -> Void

    func makeNSView(context: Context) -> CanvasWorkspaceView {
        let view = CanvasWorkspaceView()
        view.store = store; view.onCrop = onCrop; view.onInspect = onInspect
        return view
    }

    func updateNSView(_ view: CanvasWorkspaceView, context: Context) {
        view.isActive = isActive
        view.onCrop = onCrop
        view.onInspect = onInspect
        view.snapshot = CanvasRenderSnapshot(store.document, preview: true)
        if view.lastFitRequest != store.fitRequest {
            view.lastFitRequest = store.fitRequest
            view.resetViewport()
        }
        view.needsDisplay = true
    }
}

final class CanvasWorkspaceView: NSView {
    var store: CanvasStore!
    var snapshot: CanvasRenderSnapshot?
    var onCrop: ((CanvasLayer) -> Void)?
    var onInspect: ((CanvasLayer) -> Void)?
    var isActive = true
    var lastFitRequest = -1
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var spacePressed = false
    private var dragStart = CGPoint.zero
    private var initialLayer: CanvasLayer?
    private var panStart = CGPoint.zero
    private var didDrag = false
    private var guideX = false
    private var guideY = false
    private enum Interaction { case move, resize(Int), rotate, pan }
    private var interaction: Interaction?
    private let cornerSigns = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1),
                               CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1)]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("拼图画布。使用素材列表选择图片，方向键移动，Shift 加方向键移动十个像素。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var fitScale: CGFloat {
        guard let size = snapshot?.size else { return 1 }
        return max(0.01, min((bounds.width - 100) / size.width, (bounds.height - 100) / size.height))
    }
    private var scale: CGFloat { fitScale * zoom }
    private var origin: CGPoint {
        guard let size = snapshot?.size else { return .zero }
        return CGPoint(x: (bounds.width - size.width * scale) / 2 + pan.x,
                       y: (bounds.height - size.height * scale) / 2 + pan.y)
    }
    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
    private func eventPoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    func resetViewport() {
        zoom = 1; pan = .zero
        store?.displayedZoom = 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let snapshot, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y); context.scaleBy(x: scale, y: scale)
        context.setShadow(offset: CGSize(width: 0, height: 2 / scale), blur: 12 / scale,
                          color: CGColor(gray: 0, alpha: 0.12))
        context.setFillColor(snapshot.background.cgColor); context.fill(CGRect(origin: .zero, size: snapshot.size))
        context.setShadow(offset: .zero, blur: 0, color: nil)
        CanvasRenderer.draw(snapshot, in: context)
        if guideX || guideY {
            context.setStrokeColor(NSColor.systemTeal.cgColor); context.setLineWidth(1 / scale)
            if guideX { context.move(to: CGPoint(x: snapshot.size.width / 2, y: 0)); context.addLine(to: CGPoint(x: snapshot.size.width / 2, y: snapshot.size.height)) }
            if guideY { context.move(to: CGPoint(x: 0, y: snapshot.size.height / 2)); context.addLine(to: CGPoint(x: snapshot.size.width, y: snapshot.size.height / 2)) }
            context.strokePath()
        }
        if let layer = store.selectedLayer { drawSelection(layer, context: context) }
        context.restoreGState()
    }

    private func drawSelection(_ layer: CanvasLayer, context: CGContext) {
        context.saveGState()
        context.translateBy(x: layer.center.x, y: layer.center.y); context.rotate(by: layer.rotation * .pi / 180)
        let rect = CGRect(x: -layer.size.width / 2, y: -layer.size.height / 2, width: layer.size.width, height: layer.size.height)
        let accent = layer.locked ? NSColor.secondaryLabelColor : NSColor.controlAccentColor
        context.setStrokeColor(accent.cgColor); context.setLineWidth(1.5 / scale)
        context.stroke(rect)
        guard !layer.locked else { context.restoreGState(); return }
        let radius = 4.5 / scale
        for sign in cornerSigns {
            let point = CGPoint(x: sign.x * layer.size.width / 2, y: sign.y * layer.size.height / 2)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        let rotationY = -layer.size.height / 2 - 26 / scale
        context.move(to: CGPoint(x: 0, y: rect.minY)); context.addLine(to: CGPoint(x: 0, y: rotationY)); context.strokePath()
        context.setFillColor(NSColor.white.cgColor)
        let rotationRect = CGRect(x: -radius, y: rotationY - radius, width: radius * 2, height: radius * 2)
        context.fillEllipse(in: rotationRect); context.strokeEllipse(in: rotationRect)
        context.restoreGState()
    }

    private func handle(at point: CGPoint, layer: CanvasLayer) -> Interaction? {
        guard !layer.locked else { return nil }
        let local = CanvasGeometry.localPoint(point, center: layer.center, rotation: layer.rotation)
        let tolerance = 10 / scale
        let rotatePoint = CGPoint(x: 0, y: -layer.size.height / 2 - 26 / scale)
        if hypot(local.x - rotatePoint.x, local.y - rotatePoint.y) < tolerance { return .rotate }
        for (index, sign) in cornerSigns.enumerated() {
            if hypot(local.x - sign.x * layer.size.width / 2, local.y - sign.y * layer.size.height / 2) < tolerance {
                return .resize(index)
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let point = eventPoint(event)
        dragStart = canvasPoint(point); panStart = pan; didDrag = false
        if spacePressed {
            dragStart = point; interaction = .pan; NSCursor.closedHand.set(); return
        }
        if let selected = store.selectedLayer, let selectedHandle = handle(at: dragStart, layer: selected) {
            initialLayer = selected; interaction = selectedHandle; return
        }
        let hit = layer(at: dragStart)
        store.selectedID = hit?.id; initialLayer = hit
        interaction = hit?.locked == false ? .move : nil
        if event.clickCount == 2, let hit, hit.kind == .photo, !hit.locked {
            interaction = nil; onCrop?(hit)
        }
        needsDisplay = true
    }

    private func layer(at point: CGPoint) -> CanvasLayer? {
        guard CGRect(origin: .zero, size: store.document.size).contains(point) else { return nil }
        return store.document.layers.reversed().first { layer in
            let local = CanvasGeometry.localPoint(point, center: layer.center, rotation: layer.rotation)
            return abs(local.x) <= layer.size.width / 2 && abs(local.y) <= layer.size.height / 2
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isActive, let hit = layer(at: canvasPoint(eventPoint(event))) else { return }
        window?.makeFirstResponder(self)
        interaction = nil
        store.selectedID = hit.id
        onInspect?(hit)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let interaction else { return }
        if case .pan = interaction {
            let point = eventPoint(event)
            pan = CGPoint(x: panStart.x + point.x - dragStart.x, y: panStart.y + point.y - dragStart.y)
            needsDisplay = true; return
        }
        guard let layer = initialLayer else { return }
        if !didDrag { store.beginContinuousChange(); didDrag = true }
        let point = canvasPoint(eventPoint(event))
        guideX = false; guideY = false
        switch interaction {
        case .move:
            var center = CGPoint(x: layer.center.x + point.x - dragStart.x, y: layer.center.y + point.y - dragStart.y)
            if !event.modifierFlags.contains(.option) {
                let canvas = store.document.size
                if abs(center.x - canvas.width / 2) < 6 / scale { center.x = canvas.width / 2; guideX = true }
                if abs(center.y - canvas.height / 2) < 6 / scale { center.y = canvas.height / 2; guideY = true }
            }
            store.editLayer(layer.id) { $0.center = center }
        case .rotate:
            let initialAngle = atan2(dragStart.y - layer.center.y, dragStart.x - layer.center.x)
            let angle = atan2(point.y - layer.center.y, point.x - layer.center.x)
            var degrees = layer.rotation + (angle - initialAngle) * 180 / .pi
            if event.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
            let normalized = ((degrees + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
            store.editLayer(layer.id) { $0.rotation = normalized }
        case .resize(let index):
            resize(layer, corner: index, to: point, keepAspect: layer.preservesAspect || event.modifierFlags.contains(.shift))
        case .pan: break
        }
    }

    private func resize(_ layer: CanvasLayer, corner: Int, to point: CGPoint, keepAspect: Bool) {
        let sign = cornerSigns[corner]
        let anchor = CanvasGeometry.worldPoint(CGPoint(x: -sign.x * layer.size.width / 2, y: -sign.y * layer.size.height / 2),
                                               center: layer.center, rotation: layer.rotation)
        let relative = CanvasGeometry.localPoint(point, center: anchor, rotation: layer.rotation)
        var size = CGSize(width: max(12, relative.x * sign.x), height: max(12, relative.y * sign.y))
        if keepAspect {
            let aspect = layer.size.width / layer.size.height
            if size.width / layer.size.width > size.height / layer.size.height { size.height = size.width / aspect }
            else { size.width = size.height * aspect }
        }
        size.width = min(32000, size.width); size.height = min(32000, size.height)
        let center = CanvasGeometry.worldPoint(CGPoint(x: sign.x * size.width / 2, y: sign.y * size.height / 2),
                                               center: anchor, rotation: layer.rotation)
        store.editLayer(layer.id) { $0.size = size; $0.center = center }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag { store.endContinuousChange() }
        interaction = nil; initialLayer = nil; didDrag = false
        guideX = false; guideY = false
        NSCursor.arrow.set(); needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else { super.keyDown(with: event); return }
        if event.keyCode == 49 { spacePressed = true; NSCursor.openHand.set(); return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": event.modifierFlags.contains(.shift) ? store.redo() : store.undo(); return
            case "d": store.duplicateSelected(); return
            default: super.keyDown(with: event); return
            }
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: store.deleteSelected()
        case 123: store.editSelected { $0.center.x -= step }
        case 124: store.editSelected { $0.center.x += step }
        case 125: store.editSelected { $0.center.y += step }
        case 126: store.editSelected { $0.center.y -= step }
        case 53: store.selectedID = nil
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "q" { resetViewport() }
            else { super.keyDown(with: event) }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spacePressed = false; NSCursor.arrow.set() }
        else { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        spacePressed = false
        if didDrag { store.endContinuousChange() }
        interaction = nil; didDrag = false
        return super.resignFirstResponder()
    }

    private func changeZoom(factor: CGFloat, around point: CGPoint) {
        let before = canvasPoint(point)
        zoom = min(12, max(0.2, zoom * factor))
        let after = canvasPoint(point)
        pan.x += (after.x - before.x) * scale; pan.y += (after.y - before.y) * scale
        store.displayedZoom = zoom; needsDisplay = true
    }
    override func magnify(with event: NSEvent) { changeZoom(factor: max(0.1, 1 + event.magnification), around: eventPoint(event)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            changeZoom(factor: exp(event.scrollingDeltaY * 0.015), around: eventPoint(event))
        } else {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            pan.x += event.scrollingDeltaX * factor; pan.y += event.scrollingDeltaY * factor
            needsDisplay = true
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isActive && !store.isLoading ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isActive, !store.isLoading,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let point = canvasPoint(convert(sender.draggingLocation, from: nil))
        let size = store.document.size
        let clamped = CGPoint(x: min(size.width, max(0, point.x)), y: min(size.height, max(0, point.y)))
        store.importURLs(urls, at: clamped)
        return true
    }
}
