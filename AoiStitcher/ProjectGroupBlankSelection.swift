import AppKit
import SwiftUI

extension View {
    /// Apply to the content inside the photo-group ScrollView. The recognizer
    /// covers the viewport, including gaps and unused space below the last row.
    func projectGroupBlankSelection(isActive: Bool, onClearSelection: @escaping () -> Void) -> some View {
        background(ProjectGroupBlankSelectionReader(isActive: isActive,
                                                     onClearSelection: onClearSelection)
            .allowsHitTesting(false))
    }
}

private struct ProjectGroupBlankSelectionReader: NSViewRepresentable {
    let isActive: Bool
    let onClearSelection: () -> Void

    func makeNSView(context: Context) -> ProjectGroupBlankSelectionReaderView {
        ProjectGroupBlankSelectionReaderView()
    }

    func updateNSView(_ view: ProjectGroupBlankSelectionReaderView, context: Context) {
        view.update(isActive: isActive, onClearSelection: onClearSelection)
    }

    static func dismantleNSView(_ view: ProjectGroupBlankSelectionReaderView, coordinator: ()) {
        view.disconnect()
    }
}

@MainActor final class ProjectGroupBlankSelectionReaderView: NSView {
    let selectionController = ProjectGroupBlankSelectionController()
    private var attachmentScheduled = false
    private var disconnected = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isActive: Bool, onClearSelection: @escaping () -> Void) {
        disconnected = false
        selectionController.isActive = isActive
        selectionController.onClearSelection = onClearSelection
        scheduleAttach()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { selectionController.detach() } else { scheduleAttach() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { selectionController.detach() } else { scheduleAttach() }
    }

    private func scheduleAttach() {
        guard !disconnected, !attachmentScheduled else { return }
        attachmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachmentScheduled = false
            guard !self.disconnected, self.window != nil,
                  let scroll = self.enclosingScrollView else { return }
            self.selectionController.attach(to: scroll)
        }
    }

    func disconnect() {
        disconnected = true
        selectionController.isActive = false
        selectionController.onClearSelection = nil
        selectionController.detach()
    }
}

/// Observes only blank clicks in one group viewport. Photo boards and handles
/// keep their native click/drag behavior; no application-wide event monitor is used.
@MainActor final class ProjectGroupBlankSelectionController: NSObject, NSGestureRecognizerDelegate {
    let clickRecognizer = NSClickGestureRecognizer(target: nil, action: nil)
    private(set) weak var scrollView: NSScrollView?
    var onClearSelection: (() -> Void)?
    var isActive = true {
        didSet {
            clickRecognizer.isEnabled = isActive
            if !isActive { acceptedBlankMouseDown = false }
        }
    }
    private var acceptedBlankMouseDown = false

    override init() {
        super.init()
        clickRecognizer.target = self
        clickRecognizer.action = #selector(clearBlankSelection(_:))
        clickRecognizer.delegate = self
        clickRecognizer.buttonMask = 1
        clickRecognizer.numberOfClicksRequired = 1
        clickRecognizer.delaysPrimaryMouseButtonEvents = false
        clickRecognizer.delaysSecondaryMouseButtonEvents = false
    }

    func attach(to scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        scrollView.addGestureRecognizer(clickRecognizer)
    }

    func detach() {
        scrollView?.removeGestureRecognizer(clickRecognizer)
        scrollView = nil
        acceptedBlankMouseDown = false
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let accepts = gestureRecognizer === clickRecognizer && isActive
            && event.type == .leftMouseDown && !event.modifierFlags.contains(.control)
            && event.window === scrollView?.window && scrollView?.window != nil
            && isBlankContent(at: event.locationInWindow)
        acceptedBlankMouseDown = accepts
        return accepts
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        true
    }

    @objc private func clearBlankSelection(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer === clickRecognizer, recognizer.state == .ended,
              isActive, acceptedBlankMouseDown,
              isBlankContent(at: recognizer.location(in: nil)) else { return }
        acceptedBlankMouseDown = false
        onClearSelection?()
    }

    private func isBlankContent(at windowPoint: NSPoint) -> Bool {
        guard let scrollView, let root = scrollView.window?.contentView else { return false }
        let clip = scrollView.contentView
        guard clip.bounds.contains(clip.convert(windowPoint, from: nil)) else { return false }
        let rootPoint = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
        var hit = root.hitTest(rootPoint)
        while let view = hit {
            if view === scrollView { return true }
            if view is ProjectMaterialDocumentView || view is ProjectPhotoGroupHandleView
                || view is ProjectPhotoGroupContainerView || view is NSControl
                || view is NSText || view is NSScrollView {
                return false
            }
            hit = view.superview
        }
        return false
    }
}
