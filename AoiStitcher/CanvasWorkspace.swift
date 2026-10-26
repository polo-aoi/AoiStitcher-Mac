import SwiftUI
import AppKit

struct CanvasWorkspace: NSViewRepresentable {
    @ObservedObject var store: CanvasStore
    var isActive: Bool
    var settings: CanvasInteractionSettings
    var onCrop: (CanvasLayer) -> Void
    var onInspect: (CanvasLayer) -> Void

    func makeNSView(context: Context) -> CanvasWorkspaceView {
        let view = CanvasWorkspaceView()
        view.store = store; view.onCrop = onCrop; view.onInspect = onInspect
        view.isActive = isActive; view.settings = settings
        return view
    }

    func updateNSView(_ view: CanvasWorkspaceView, context: Context) {
        view.isActive = isActive
        view.settings = settings
        view.onCrop = onCrop
        view.onInspect = onInspect
        view.synchronizeDocument()
        if view.lastFitRequest != store.fitRequest {
            view.lastFitRequest = store.fitRequest
            view.resetViewport()
        }
    }

    static func dismantleNSView(_ view: CanvasWorkspaceView, coordinator: ()) {
        view.disconnect()
    }
}

final class CanvasWorkspaceView: NSView {
    var store: CanvasStore!
    var snapshot: CanvasRenderSnapshot?
    var onCrop: ((CanvasLayer) -> Void)?
    var onInspect: ((CanvasLayer) -> Void)?
    var isActive = true {
        didSet {
            guard oldValue != isActive else { return }
            if isActive {
                registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("com.aoipic.paper-url")])
            } else {
                unregisterDraggedTypes()
                finishInteraction(clearKeyboard: true)
            }
            needsDisplay = true
        }
    }
    var settings = CanvasInteractionSettings() {
        didSet { if settings != oldValue { finishInteraction(clearKeyboard: true) } }
    }
    var lastFitRequest = -1
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var spacePressed = false
    private var dragStart = CGPoint.zero
    private var initialLayer: CanvasLayer?
    private var previewLayer: CanvasLayer?
    private var previewLayerIndex: Int?
    private var interactionRevision: UInt64?
    private var snapshotRevision: UInt64?
    private var lastSelectionID: UUID?
    private var zoomPublication: DispatchWorkItem?
    private var panStart = CGPoint.zero
    private var guideX = false
    private var guideY = false
    private var rightClickStart: CGPoint?
    private var rightClickLayerID: UUID?
    private var rightClickDidDrag = false
    private var keyboardMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private enum Interaction { case move, resize(Int), rotate, pan }
    private var interaction: Interaction?
    private let cornerSigns = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1),
                               CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1)]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("com.aoipic.paper-url")])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("拼图画布。使用素材列表选择图片，方向键移动，Shift 加方向键移动十个像素。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disconnect()
        guard let window else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown
        ]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyboardEvent(event)
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.finishInteraction(clearKeyboard: true)
            })
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        finishInteraction(clearKeyboard: true)
    }

    func disconnect() {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor); self.keyboardMonitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        zoomPublication?.cancel(); zoomPublication = nil
        finishInteraction(clearKeyboard: true)
    }

    func synchronizeDocument() {
        guard let store else { return }
        if lastSelectionID != store.selectedID {
            lastSelectionID = store.selectedID
            needsDisplay = true
        }
        guard snapshotRevision != store.documentRevision || snapshot == nil else { return }
        if let interactionRevision, interactionRevision != store.documentRevision {
            finishInteraction(clearKeyboard: true, commit: false)
            return
        }
        snapshot = CanvasRenderSnapshot(store.document, preview: true)
        snapshotRevision = store.documentRevision
        needsDisplay = true
    }

    private var acceptsInteraction: Bool {
        isActive && !isHiddenOrHasHiddenAncestor && window?.isKeyWindow == true && window?.attachedSheet == nil
    }

    private func handleKeyboardEvent(_ event: NSEvent) -> NSEvent? {
        guard acceptsInteraction, let window, event.window === window || event.window == nil else { return event }
        // Menu shortcuts can bypass keyDown on the view. Finish the local
        // preview before export, undo or another command reads the document.
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           interaction != nil || rightClickStart != nil {
            finishInteraction(clearKeyboard: true)
        }
        let textInput = window.firstResponder is NSTextView || window.firstResponder is NSTextField
        if textInput {
            spacePressed = false
            stopKeyboardPan()
            return event
        }
        if event.type == .keyUp, event.keyCode == 49, spacePressed {
            spacePressed = false
            stopKeyboardPan()
            NSCursor.arrow.set()
            return nil
        }
        if event.type == .flagsChanged, settings.panMode == .keyboard, settings.panKey != .space,
           !event.modifierFlags.contains(settings.panKey.modifierFlags) {
            stopKeyboardPan()
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !bounds.contains(eventPoint(event)) {
                spacePressed = false
                stopKeyboardPan()
            }
            return event
        }
        // Keyboard events lack pointer coordinates. Observe only Space over
        // this active viewport, so panning also works before its first click.
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if event.type == .keyDown, event.keyCode == 49,
           settings.panMode == .keyboard, settings.panKey == .space,
           spacePressed || bounds.contains(pointer) {
            spacePressed = true
            NSCursor.openHand.set()
            return nil
        }
        return event
    }

    private func keyboardPanRequested(_ event: NSEvent) -> Bool {
        settings.panMode == .keyboard && (settings.panKey == .space
            ? spacePressed : event.modifierFlags.contains(settings.panKey.modifierFlags))
    }

    private func stopKeyboardPan() {
        if case .pan = interaction, rightClickStart == nil {
            finishInteraction(clearKeyboard: false)
        }
    }

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
        finishInteraction(clearKeyboard: true)
        zoomPublication?.cancel(); zoomPublication = nil
        zoom = 1; pan = .zero
        store?.displayedZoom = 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let snapshot, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.translateBy(x: origin.x, y: origin.y); context.scaleBy(x: scale, y: scale)
        CanvasRenderer.draw(snapshot, in: context,
                            interpolationQuality: interaction != nil || rightClickDidDrag || zoomPublication != nil ? .medium : .high)
        if guideX || guideY {
            context.setStrokeColor(NSColor.systemTeal.cgColor); context.setLineWidth(1 / scale)
            if guideX { context.move(to: CGPoint(x: snapshot.size.width / 2, y: 0)); context.addLine(to: CGPoint(x: snapshot.size.width / 2, y: snapshot.size.height)) }
            if guideY { context.move(to: CGPoint(x: 0, y: snapshot.size.height / 2)); context.addLine(to: CGPoint(x: snapshot.size.width, y: snapshot.size.height / 2)) }
            context.strokePath()
        }
        if let layer = previewLayer ?? store.selectedLayer { drawSelection(layer, context: context) }
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
        guard acceptsInteraction, bounds.contains(eventPoint(event)) else { return }
        finishInteraction(clearKeyboard: false)
        synchronizeDocument()
        let keyboardPan = keyboardPanRequested(event)
        if event.modifierFlags.contains(.control), !keyboardPan { rightMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let point = eventPoint(event)
        dragStart = canvasPoint(point); panStart = pan
        if keyboardPan {
            dragStart = point; interaction = .pan; NSCursor.closedHand.set(); return
        }
        if let selected = store.selectedLayer, let selectedHandle = handle(at: dragStart, layer: selected) {
            beginLayerInteraction(selected, interaction: selectedHandle); return
        }
        let hit = layer(at: dragStart)
        store.selectedID = hit?.id
        if event.clickCount == 2, let hit, hit.kind == .photo, !hit.locked {
            onCrop?(hit)
        } else if let hit, !hit.locked {
            beginLayerInteraction(hit, interaction: .move)
        }
        needsDisplay = true
    }

    private func beginLayerInteraction(_ layer: CanvasLayer, interaction: Interaction) {
        initialLayer = layer
        interactionRevision = store.documentRevision
        previewLayerIndex = snapshot?.layers.firstIndex { $0.id == layer.id }
        self.interaction = interaction
    }

    private func layer(at point: CGPoint) -> CanvasLayer? {
        guard CGRect(origin: .zero, size: store.document.size).contains(point) else { return nil }
        return store.document.layers.reversed().first { layer in
            let local = CanvasGeometry.localPoint(point, center: layer.center, rotation: layer.rotation)
            return abs(local.x) <= layer.size.width / 2 && abs(local.y) <= layer.size.height / 2
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard acceptsInteraction, bounds.contains(eventPoint(event)) else { return }
        window?.makeFirstResponder(self)
        finishInteraction(clearKeyboard: false)
        let point = eventPoint(event)
        rightClickStart = point
        rightClickLayerID = layer(at: canvasPoint(point))?.id
        panStart = pan
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard acceptsInteraction, let start = rightClickStart else { return }
        let point = eventPoint(event)
        if hypot(point.x - start.x, point.y - start.y) >= 5 { rightClickDidDrag = true }
        guard rightClickDidDrag, settings.panMode == .rightMouse else { return }
        pan = CGPoint(x: panStart.x + point.x - start.x, y: panStart.y + point.y - start.y)
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let start = rightClickStart else { return }
        let point = eventPoint(event)
        let isClick = !rightClickDidDrag && hypot(point.x - start.x, point.y - start.y) < 5
        let clickedID = rightClickLayerID
        finishInteraction(clearKeyboard: false)
        if acceptsInteraction, isClick, bounds.contains(point),
           let hit = store.document.layers.first(where: { $0.id == clickedID }) {
            store.selectedID = hit.id
            onInspect?(hit)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if rightClickStart != nil { rightMouseDragged(with: event); return }
        guard acceptsInteraction else { finishInteraction(clearKeyboard: true); return }
        guard let interaction else { return }
        if case .pan = interaction {
            let point = eventPoint(event)
            pan = CGPoint(x: panStart.x + point.x - dragStart.x, y: panStart.y + point.y - dragStart.y)
            needsDisplay = true; return
        }
        guard let layer = initialLayer, interactionRevision == store.documentRevision else {
            finishInteraction(clearKeyboard: true, commit: false)
            return
        }
        let point = canvasPoint(eventPoint(event))
        var updated = layer
        invalidatePreview(previewLayer ?? layer)
        invalidateGuides()
        guideX = false; guideY = false
        switch interaction {
        case .move:
            var center = CGPoint(x: layer.center.x + point.x - dragStart.x, y: layer.center.y + point.y - dragStart.y)
            if !event.modifierFlags.contains(.option) {
                let canvas = store.document.size
                if abs(center.x - canvas.width / 2) < 6 / scale { center.x = canvas.width / 2; guideX = true }
                if abs(center.y - canvas.height / 2) < 6 / scale { center.y = canvas.height / 2; guideY = true }
            }
            updated.center = center
        case .rotate:
            let initialAngle = atan2(dragStart.y - layer.center.y, dragStart.x - layer.center.x)
            let angle = atan2(point.y - layer.center.y, point.x - layer.center.x)
            var degrees = layer.rotation + (angle - initialAngle) * 180 / .pi
            if event.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
            let normalized = ((degrees + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
            updated.rotation = normalized
        case .resize(let index):
            updated = resized(layer, corner: index, to: point, keepAspect: layer.preservesAspect || event.modifierFlags.contains(.shift))
        case .pan: break
        }
        previewLayer = updated
        if let previewLayerIndex, snapshot?.layers.indices.contains(previewLayerIndex) == true {
            snapshot?.layers[previewLayerIndex] = CanvasRenderLayer(updated, preview: true)
        }
        invalidatePreview(updated)
        invalidateGuides()
    }

    private func invalidatePreview(_ layer: CanvasLayer) {
        let rect = CanvasRenderLayer(layer, preview: true).bounds
        let viewRect = CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
                              width: rect.width * scale, height: rect.height * scale)
        // Include selection handles and the rotation handle outside the photo.
        setNeedsDisplay(viewRect.insetBy(dx: -40, dy: -40))
    }

    private func invalidateGuides() {
        guard let size = snapshot?.size else { return }
        if guideX {
            setNeedsDisplay(CGRect(x: origin.x + size.width * scale / 2 - 2, y: origin.y,
                                   width: 4, height: size.height * scale))
        }
        if guideY {
            setNeedsDisplay(CGRect(x: origin.x, y: origin.y + size.height * scale / 2 - 2,
                                   width: size.width * scale, height: 4))
        }
    }

    private func resized(_ layer: CanvasLayer, corner: Int, to point: CGPoint, keepAspect: Bool) -> CanvasLayer {
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
        var updated = layer
        updated.size = size; updated.center = center
        return updated
    }

    override func mouseUp(with event: NSEvent) {
        if rightClickStart != nil { rightMouseUp(with: event); return }
        finishInteraction(clearKeyboard: false)
    }

    private func finishInteraction(clearKeyboard: Bool, commit: Bool = true) {
        let finalLayer = previewLayer
        let revision = interactionRevision
        let hadPreview = previewLayer != nil
        previewLayer = nil; previewLayerIndex = nil; interactionRevision = nil
        interaction = nil; initialLayer = nil
        rightClickStart = nil; rightClickLayerID = nil; rightClickDidDrag = false
        if clearKeyboard { spacePressed = false }
        guideX = false; guideY = false
        if commit, let finalLayer, let revision {
            store?.commitTransform(finalLayer, expectedRevision: revision)
        }
        if hadPreview { snapshotRevision = nil }
        synchronizeDocument()
        NSCursor.arrow.set(); needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsInteraction else { super.keyDown(with: event); return }
        if event.keyCode == 53, interaction != nil || rightClickStart != nil {
            finishInteraction(clearKeyboard: true, commit: false)
            return
        }
        if interaction != nil || rightClickStart != nil { finishInteraction(clearKeyboard: true) }
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
        if event.keyCode == 49, spacePressed {
            spacePressed = false; stopKeyboardPan(); NSCursor.arrow.set()
        }
        else { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        finishInteraction(clearKeyboard: true)
        return super.resignFirstResponder()
    }

    private func changeZoom(factor: CGFloat, around point: CGPoint) {
        let before = canvasPoint(point)
        zoom = min(12, max(0.2, zoom * factor))
        let after = canvasPoint(point)
        pan.x += (after.x - before.x) * scale; pan.y += (after.y - before.y) * scale
        // The viewport updates immediately; the toolbar percentage does not
        // need to rebuild the SwiftUI workspace for every wheel event.
        zoomPublication?.cancel()
        let update = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.store?.displayedZoom = self.zoom
            self.zoomPublication = nil
            self.needsDisplay = true
        }
        zoomPublication = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: update)
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard acceptsInteraction, bounds.contains(eventPoint(event)), interaction == nil, rightClickStart == nil else { return }
        changeZoom(factor: max(0.1, 1 + event.magnification), around: eventPoint(event))
    }
    override func scrollWheel(with event: NSEvent) {
        guard acceptsInteraction, bounds.contains(eventPoint(event)), interaction == nil, rightClickStart == nil else { return }
        // Precise deltas also occur on touch mice. Gesture phases distinguish
        // continuous gestures; their behavior can be overridden in Settings.
        let isContinuousGesture = event.hasPreciseScrollingDeltas && (event.phase != [] || event.momentumPhase != [])
        let behavior = isContinuousGesture ? settings.gestureBehavior : settings.wheelBehavior
        if behavior == .zoom {
            let sensitivity = settings.zoomSensitivity.isFinite ? min(3, max(0.25, settings.zoomSensitivity)) : 1
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
            let direction: CGFloat = settings.reverseZoom ? -1 : 1
            let exponent = event.scrollingDeltaY * unit * CGFloat(sensitivity) * direction
            changeZoom(factor: exp(min(2, max(-2, exponent))), around: eventPoint(event))
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
        guard isActive, !store.isLoading else { return false }
        let paperType = NSPasteboard.PasteboardType("com.aoipic.paper-url")
        let paperURL = sender.draggingPasteboard.data(forType: paperType)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(URL.init(string:))
        let urls = paperURL.map { [$0] } ??
            (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
        guard !urls.isEmpty else { return false }
        let point = canvasPoint(convert(sender.draggingLocation, from: nil))
        let size = store.document.size
        let clamped = CGPoint(x: min(size.width, max(0, point.x)), y: min(size.height, max(0, point.y)))
        store.importURLs(urls, as: paperURL == nil ? .photo : .paper, at: clamped)
        return true
    }
}
