import AppKit
import SwiftUI

struct GridCollageDragPreview {
    let slot: CollageSlot
    let frame: CGRect
    let radius: CGFloat
    let targetID: String?
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
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
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
                if let current = self.session, current.didDrag, !current.isPan, !current.isCancelled,
                   let target = slot(at: point, excludingControls: false), target.id != current.slot.id,
                   current.photoIDs[target.id] == target.photoID {
                    store.swapImages(current.slot.id, target.id)
                }
                finishGesture()
                return nil
            }
            if event.type == .scrollWheel || event.type == .magnify { return nil }
            if [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .rightMouseDragged,
                .leftMouseUp, .rightMouseUp].contains(event.type) { return nil }
        }

        guard let slot = slot(at: point, excludingControls: true), slot.hasImage,
              let frame = layout?.slotRects[slot.id], frame.width > 0, frame.height > 0 else { return event }
        if event.type == .leftMouseDown || (event.type == .rightMouseDown && panMode == .rightMouse) {
            let keyboardPan = panMode == .keyboard && (panKey == .space
                ? spacePressed : event.modifierFlags.contains(panKey.modifierFlags))
            session = GestureSession(slot: slot, templateID: store.state.activeTemplateId,
                                     rootNode: store.state.rootNode,
                                     photoIDs: store.state.slots.mapValues(\.photoID), startPoint: point,
                                     slotFrame: frame, isPan: event.type == .rightMouseDown || keyboardPan,
                                     isRightMouse: event.type == .rightMouseDown)
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
        store.map { GridCollageLayoutEngine.layout(state: $0.state, in: canvasFrame) }
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
        if session.isPan {
            store.setPan(CGPoint(x: session.slot.transform.translateX + delta.x / session.slotFrame.width,
                                 y: session.slot.transform.translateY + delta.y / session.slotFrame.height),
                         for: session.slot.id, viewport: session.slotFrame.size)
        } else {
            let target = slot(at: point, excludingControls: false)
            let radius = min(store.state.style.borderRadius * canvasFrame.width / 1000,
                             min(session.slotFrame.width, session.slotFrame.height) / 2)
            hasPreview = true
            onPreviewChange?(GridCollageDragPreview(
                slot: session.slot, frame: session.slotFrame.offsetBy(dx: delta.x, dy: delta.y), radius: radius,
                targetID: target?.id == session.slot.id ? nil : target?.id
            ))
        }
    }

    private func isCurrent(_ session: GestureSession) -> Bool {
        guard let store else { return false }
        return !store.isLoading && store.state.activeTemplateId == session.templateID &&
            store.state.rootNode == session.rootNode &&
            store.state.slots[session.slot.id]?.photoID == session.slot.photoID
    }

    private func stopKeyboardPan() {
        guard let session, session.isPan, !session.isRightMouse else { return }
        self.session?.isCancelled = true
        NSCursor.arrow.set()
    }

    private func finishGesture(deferPreviewUpdate: Bool = false) {
        let wasInteracting = session != nil || hasPreview
        session = nil
        clearPreview(deferPreviewUpdate: deferPreviewUpdate)
        if wasInteracting { restoreCursor() }
    }

    private func clearPreview(deferPreviewUpdate: Bool = false) {
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
