import AppKit
import SwiftUI

struct GridCollageDragPreview {
    let slot: CollageSlot
    let frame: CGRect
    let radius: CGFloat
    let targetID: String?
    let isPan: Bool
}

/// A single event owner keeps swapping and in-frame panning mutually exclusive.
/// The floating preview follows the long-stitch canvas's six-point drag threshold.
struct GridCollageInteractionReader: NSViewRepresentable {
    @ObservedObject var store: GridCollageStore
    var isActive: Bool
    var canvasFrame: CGRect
    var toolbarSize: CGSize
    var panMode: DragPanMode
    var panKey: LongStitchPanKey
    @Binding var dragPreview: GridCollageDragPreview?

    func makeNSView(context: Context) -> GridCollageInteractionView {
        let view = GridCollageInteractionView()
        view.wantsLayer = true
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: GridCollageInteractionView, context: Context) {
        view.configure(store: store, isActive: isActive, canvasFrame: canvasFrame,
                       toolbarSize: toolbarSize, panMode: panMode, panKey: panKey) {
            dragPreview = $0
        }
    }

    static func dismantleNSView(_ view: GridCollageInteractionView, coordinator: ()) {
        view.disconnect()
    }
}

final class GridCollageInteractionView: NSView {
    private struct GestureSession {
        let slot: CollageSlot
        let templateID: String
        let rootNode: SplitNode
        let photoIDs: [String: UUID]
        let startPoint: CGPoint
        let slotFrame: CGRect
        let isPan: Bool
        let isRightMouse: Bool
        let layout: GridCollageLayout
        let gap: CGFloat
        let padding: CGFloat
        let radius: CGFloat
        var didDrag = false
        var isCancelled = false
    }

    private weak var store: GridCollageStore?
    private var isActive = false
    private var canvasFrame = CGRect.zero
    private var toolbarSize = CGSize.zero
    private var panMode = DragPanMode.rightMouse
    private var panKey = LongStitchPanKey.space
    private var onPreviewChange: ((GridCollageDragPreview?) -> Void)?
    private var session: GestureSession?
    private var spacePressed = false
    private var hasPreview = false
    private var localPreview: GridCollageDragPreview?
    private var previewImage: NSImage?
    private var publishedTargetID: String?
    /// A menu command can finish editing before the physical mouse release.
    /// Keep consuming that original sequence even if a command switches tools.
    private var pendingMouseRelease: Int?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(store: GridCollageStore, isActive: Bool, canvasFrame: CGRect,
                   toolbarSize: CGSize, panMode: DragPanMode, panKey: LongStitchPanKey,
                   onPreviewChange: @escaping (GridCollageDragPreview?) -> Void) {
        self.onPreviewChange = onPreviewChange
        if !isActive || self.panMode != panMode || self.panKey != panKey || self.canvasFrame != canvasFrame {
            cancelInteraction(deferPreviewUpdate: true)
        }
        self.store = store
        self.isActive = isActive
        self.canvasFrame = canvasFrame
        self.toolbarSize = toolbarSize
        self.panMode = panMode
        self.panKey = panKey
        if let session, !isCurrent(session) { cancelInteraction(deferPreviewUpdate: true) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disconnect()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
            .keyDown, .keyUp, .flagsChanged, .scrollWheel, .magnify
        ]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.cancelInteraction()
            })
        }
    }

    func disconnect() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        cancelInteraction(deferPreviewUpdate: true)
        pendingMouseRelease = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if let button = pendingMouseRelease, event.window === window {
            let dragged: NSEvent.EventType = button == 1 ? .rightMouseDragged : .leftMouseDragged
            let released: NSEvent.EventType = button == 1 ? .rightMouseUp : .leftMouseUp
            let pressed: NSEvent.EventType = button == 1 ? .rightMouseDown : .leftMouseDown
            if event.type == released { pendingMouseRelease = nil; return nil }
            if event.type == dragged { return nil }
            // Recover when focus/window changes caused the original release to be lost.
            if event.type == pressed { pendingMouseRelease = nil }
        }
        let isKeyboardEvent = [.keyDown, .keyUp, .flagsChanged].contains(event.type)
        guard isActive, let store, !store.isLoading, let window,
              window.isKeyWindow, window.attachedSheet == nil,
              event.window === window || (isKeyboardEvent && event.window == nil) else { return event }

        let isTextInput = window.firstResponder is NSTextView || window.firstResponder is NSTextField
        if isTextInput {
            spacePressed = false
            stopKeyboardPan()
        }

        if event.type == .keyUp, event.keyCode == 49, spacePressed {
            spacePressed = false
            stopKeyboardPan()
            return nil
        }
        if event.type == .flagsChanged, panMode == .keyboard, panKey != .space,
           !event.modifierFlags.contains(panKey.modifierFlags) {
            stopKeyboardPan()
            return event
        }
        if event.type == .keyDown {
            if event.modifierFlags.contains(.command), session != nil {
                finishBeforeCommand()
                return event
            }
            if event.keyCode == 53, session != nil {
                // Keep ownership until mouse-up; an aborted drag must not
                // turn into a SwiftUI click or a different gesture midway.
                session?.isCancelled = true
                spacePressed = false
                clearPreview()
                NSCursor.arrow.set()
                return nil
            }
            // Keyboard events do not carry a reliable pointer location.
            let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if panMode == .keyboard, panKey == .space, event.keyCode == 49,
               !isTextInput,
               spacePressed || (canvasFrame.contains(pointer) && !toolbarFrame.contains(pointer)) {
                spacePressed = true
                return nil
            }
            return event
        }

        let point = convert(event.locationInWindow, from: nil)
        if [.leftMouseDown, .rightMouseDown].contains(event.type),
           !canvasFrame.contains(point) || toolbarFrame.contains(point) {
            spacePressed = false
            stopKeyboardPan()
        }
        if var session {
            if !isCurrent(session) {
                session.isCancelled = true
                self.session = session
                clearPreview()
            }
            let dragged: NSEvent.EventType = session.isRightMouse ? .rightMouseDragged : .leftMouseDragged
            let released: NSEvent.EventType = session.isRightMouse ? .rightMouseUp : .leftMouseUp
            if event.type == dragged {
                if !session.isCancelled { updateGesture(at: point) }
                return nil
            }
            if event.type == released {
                if !session.isCancelled { updateGesture(at: point) }
                if let current = self.session, current.didDrag, !current.isCancelled {
                    if current.isPan, let preview = localPreview {
                        store.setPan(CGPoint(x: preview.slot.transform.translateX,
                                             y: preview.slot.transform.translateY),
                                     for: current.slot.id, viewport: current.slotFrame.size)
                    } else if let target = slot(at: point, excludingControls: false), target.id != current.slot.id,
                              current.photoIDs[target.id] == target.photoID {
                        store.swapImages(current.slot.id, target.id)
                    }
                }
                finishGesture()
                return nil
            }
            if event.type == .scrollWheel || event.type == .magnify { return nil }
            if [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .rightMouseDragged,
                .leftMouseUp, .rightMouseUp].contains(event.type) { return nil }
        }

        guard let slot = slot(at: point, excludingControls: true), slot.hasImage,
              let layout, let frame = layout.slotRects[slot.id], frame.width > 0, frame.height > 0 else { return event }
        if event.type == .leftMouseDown || (event.type == .rightMouseDown && panMode == .rightMouse) {
            let keyboardPan = panMode == .keyboard && (panKey == .space
                ? spacePressed : event.modifierFlags.contains(panKey.modifierFlags))
            session = GestureSession(slot: slot, templateID: store.state.activeTemplateId,
                                     rootNode: store.state.rootNode,
                                     photoIDs: store.state.slots.mapValues(\.photoID), startPoint: point,
                                     slotFrame: frame, isPan: event.type == .rightMouseDown || keyboardPan,
                                     isRightMouse: event.type == .rightMouseDown, layout: layout,
                                     gap: store.state.style.gap, padding: store.state.style.padding,
                                     radius: store.state.style.borderRadius)
            previewImage = (slot.previewImage ?? slot.image).map { NSImage(cgImage: $0, size: .zero) }
            window.makeFirstResponder(self)
            store.selectSlot(slot.id)
            return nil
        }
        if event.type == .scrollWheel || event.type == .magnify {
            let factor: CGFloat
            if event.type == .magnify {
                factor = max(0.1, 1 + event.magnification)
            } else {
                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.04
                factor = exp(event.scrollingDeltaY * sensitivity)
            }
            store.selectSlot(slot.id)
            store.setScale(slot.transform.scale * factor, for: slot.id, viewport: frame.size)
            return nil
        }
        return event
    }

    private var layout: GridCollageLayout? {
        session?.layout ?? store.map { GridCollageLayoutEngine.layout(state: $0.state, in: canvasFrame) }
    }

    private var toolbarFrame: CGRect {
        guard !hasPreview, let store, let slot = store.selectedSlot, slot.hasImage,
              let rect = layout?.slotRects[slot.id] else { return .zero }
        let center = SelectedImageToolbarPlacement.position(for: rect, in: bounds.size, toolbarSize: toolbarSize)
        return CGRect(x: center.x - toolbarSize.width / 2, y: center.y - toolbarSize.height / 2,
                      width: toolbarSize.width, height: toolbarSize.height)
    }

    private func slot(at point: CGPoint, excludingControls: Bool) -> CollageSlot? {
        guard let store, canvasFrame.contains(point), let layout else { return nil }
        if excludingControls {
            guard !toolbarFrame.contains(point) else { return nil }
            for divider in layout.dividers {
                let horizontal = divider.direction == .horizontal
                let size = CGSize(width: horizontal ? 22 : divider.containerRect.width,
                                  height: horizontal ? divider.containerRect.height : 22)
                let hitRect = CGRect(x: divider.rect.midX - size.width / 2,
                                     y: divider.rect.midY - size.height / 2,
                                     width: size.width, height: size.height)
                if hitRect.contains(point) { return nil }
            }
        }
        return store.state.rootNode.slotIDs.first(where: { layout.slotRects[$0]?.contains(point) == true })
            .flatMap { store.state.slots[$0] }
    }

    private func updateGesture(at point: CGPoint) {
        guard var session, let store else { return }
        let delta = CGPoint(x: point.x - session.startPoint.x, y: point.y - session.startPoint.y)
        if !session.didDrag {
            guard hypot(delta.x, delta.y) >= (session.isPan ? 3 : 6) else { return }
            session.didDrag = true
            self.session = session
        }
        NSCursor.closedHand.set()
        var previewSlot = session.slot
        let target = session.isPan ? nil : slot(at: point, excludingControls: false)
        let radius = min(store.state.style.borderRadius * canvasFrame.width / 1000,
                         min(session.slotFrame.width, session.slotFrame.height) / 2)
        if session.isPan {
            previewSlot.transform.translateX += delta.x / session.slotFrame.width
            previewSlot.transform.translateY += delta.y / session.slotFrame.height
            if let imageSize = previewSlot.imageSize {
                previewSlot.transform = GridCollageLayoutEngine.clampedTransform(
                    previewSlot.transform, imageSize: imageSize,
                    viewport: session.slotFrame.size, fill: previewSlot.fill)
            }
        }
        let preview = GridCollageDragPreview(
            slot: previewSlot,
            frame: session.isPan ? session.slotFrame : session.slotFrame.offsetBy(dx: delta.x, dy: delta.y),
            radius: radius, targetID: target?.id == session.slot.id ? nil : target?.id, isPan: session.isPan)
        if let old = localPreview { setNeedsDisplay(old.frame.insetBy(dx: -3, dy: -3)) }
        localPreview = preview
        setNeedsDisplay(preview.frame.insetBy(dx: -3, dy: -3))
        // Publish only gesture/target transitions. Pointer movement stays in this view.
        if !hasPreview || publishedTargetID != preview.targetID {
            hasPreview = true
            publishedTargetID = preview.targetID
            onPreviewChange?(preview)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // This view owns a transparent backing layer. Clear the invalidated
        // region so a finished/moved preview never leaves cached pixels behind.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard let preview = localPreview, let image = previewImage,
              let imageSize = preview.slot.imageSize else { return }
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: preview.frame, xRadius: preview.radius, yRadius: preview.radius)
        clip.addClip()
        NSGraphicsContext.current?.imageInterpolation = .medium
        let imageRect = GridCollageLayoutEngine.imageRect(imageSize: imageSize, viewport: preview.frame,
                                                         transform: preview.slot.transform, fill: preview.slot.fill)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.controlAccentColor.setStroke()
        clip.lineWidth = 2
        clip.stroke()
    }

    private func isCurrent(_ session: GestureSession) -> Bool {
        guard let store, let slot = store.state.slots[session.slot.id] else { return false }
        return !store.isLoading && store.state.activeTemplateId == session.templateID &&
            store.state.rootNode == session.rootNode &&
            store.state.style.gap == session.gap && store.state.style.padding == session.padding &&
            store.state.style.borderRadius == session.radius &&
            slot.photoID == session.slot.photoID && slot.transform == session.slot.transform &&
            slot.fill == session.slot.fill && slot.imageURL == session.slot.imageURL &&
            slot.editedImageURL == session.slot.editedImageURL && slot.editRecipe == session.slot.editRecipe
    }

    private func finishBeforeCommand() {
        guard let session else { return }
        let button = session.isRightMouse ? 1 : 0
        // Export/undo/menu actions must observe the crop currently being shown.
        // A swap still requires a mouse release over a destination, so discard it.
        if session.isPan, session.didDrag, !session.isCancelled,
           isCurrent(session), let preview = localPreview {
            store?.setPan(CGPoint(x: preview.slot.transform.translateX,
                                  y: preview.slot.transform.translateY),
                          for: session.slot.id, viewport: session.slotFrame.size)
        }
        spacePressed = false
        finishGesture()
        pendingMouseRelease = button
    }

    private func stopKeyboardPan() {
        guard let session, session.isPan, !session.isRightMouse else { return }
        // Releasing the pan modifier stops movement at the current crop. Escape
        // and focus/layout cancellation still discard the uncommitted gesture.
        finishBeforeCommand()
        NSCursor.arrow.set()
    }

    private func finishGesture(deferPreviewUpdate: Bool = false) {
        let wasInteracting = session != nil || hasPreview
        session = nil
        clearPreview(deferPreviewUpdate: deferPreviewUpdate)
        previewImage = nil
        if wasInteracting { restoreCursor() }
    }

    private func clearPreview(deferPreviewUpdate: Bool = false) {
        if let preview = localPreview { setNeedsDisplay(preview.frame.insetBy(dx: -3, dy: -3)) }
        localPreview = nil
        publishedTargetID = nil
        if hasPreview {
            hasPreview = false
            if deferPreviewUpdate {
                let callback = onPreviewChange
                DispatchQueue.main.async { callback?(nil) }
            } else {
                onPreviewChange?(nil)
            }
        }
    }

    private func restoreCursor() {
        let point = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        guard canvasFrame.contains(point) else { NSCursor.arrow.set(); return }
        guard let layout else { NSCursor.arrow.set(); return }
        for divider in layout.dividers {
            let horizontal = divider.direction == .horizontal
            let size = CGSize(width: horizontal ? 22 : divider.containerRect.width,
                              height: horizontal ? divider.containerRect.height : 22)
            let hitRect = CGRect(x: divider.rect.midX - size.width / 2,
                                 y: divider.rect.midY - size.height / 2,
                                 width: size.width, height: size.height)
            if hitRect.contains(point) {
                horizontal ? NSCursor.resizeLeftRight.set() : NSCursor.resizeUpDown.set()
                return
            }
        }
        if slot(at: point, excludingControls: false)?.hasImage == true {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func cancelInteraction(deferPreviewUpdate: Bool = false) {
        spacePressed = false
        finishGesture(deferPreviewUpdate: deferPreviewUpdate)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
