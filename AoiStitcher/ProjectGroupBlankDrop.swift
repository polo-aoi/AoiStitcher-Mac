import AppKit
import Combine
import SwiftUI

extension View {
    /// Installs a destination over the whole group viewport, including unused
    /// space below the content. Existing native rows retain their destinations.
    func projectGroupBlankDrop(isActive: Bool, validAssetIDs: Set<UUID>,
                              onCreateGroup: @escaping (Set<UUID>) -> Bool,
                              onTargetChange: @escaping (Bool) -> Void = { _ in }) -> some View {
        background(ProjectGroupBlankDropReader(isActive: isActive, validAssetIDs: validAssetIDs,
                                               onCreateGroup: onCreateGroup, onTargetChange: onTargetChange)
            .allowsHitTesting(false))
    }
}

private struct ProjectGroupBlankDropReader: NSViewRepresentable {
    let isActive: Bool
    let validAssetIDs: Set<UUID>
    let onCreateGroup: (Set<UUID>) -> Bool
    let onTargetChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProjectGroupBlankDropReaderView {
        ProjectGroupBlankDropReaderView()
    }

    func updateNSView(_ view: ProjectGroupBlankDropReaderView, context: Context) {
        view.update(isActive: isActive, validAssetIDs: validAssetIDs,
                    onCreateGroup: onCreateGroup, onTargetChange: onTargetChange)
    }

    static func dismantleNSView(_ view: ProjectGroupBlankDropReaderView, coordinator: ()) {
        view.disconnect()
    }
}

@MainActor final class ProjectGroupBlankDropReaderView: NSView {
    let destination = ProjectGroupBlankDropView()
    private var attachmentScheduled = false
    private var disconnected = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(isActive: Bool, validAssetIDs: Set<UUID>,
                onCreateGroup: @escaping (Set<UUID>) -> Bool,
                onTargetChange: @escaping (Bool) -> Void) {
        disconnected = false
        destination.isActive = isActive
        destination.validAssetIDs = validAssetIDs
        destination.onCreateGroup = onCreateGroup
        destination.onTargetChange = onTargetChange
        scheduleAttach()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { destination.detach() } else { scheduleAttach() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { destination.detach() } else { scheduleAttach() }
    }

    private func scheduleAttach() {
        guard !disconnected, !attachmentScheduled else { return }
        attachmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachmentScheduled = false
            guard !self.disconnected, self.window != nil,
                  let scroll = self.enclosingScrollView else { return }
            self.destination.attach(to: scroll)
        }
    }

    func disconnect() {
        disconnected = true
        destination.isActive = false
        destination.detach()
        destination.onCreateGroup = nil
        destination.onTargetChange = nil
    }
}

/// This overlay owns hits only during a valid internal photo drag over blank
/// space. Returning nil over rows lets AppKit route to their existing handlers.
@MainActor final class ProjectGroupBlankDropView: NSView {
    private(set) weak var scrollView: NSScrollView?
    var validAssetIDs: Set<UUID> = [] { didSet { updateRegistration(for: ProjectMaterialDragState.shared.assetIDs) } }
    var isActive = true { didSet { updateRegistration(for: ProjectMaterialDragState.shared.assetIDs) } }
    var onCreateGroup: ((Set<UUID>) -> Bool)?
    var onTargetChange: ((Bool) -> Void)?
    private(set) var isDropTarget = false
    private var observations: [NSObjectProtocol] = []
    private var dragObservation: AnyCancellable?
    private weak var forwardedDestination: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        dragObservation = ProjectMaterialDragState.shared.$assetIDs.sink { [weak self] ids in
            // Published sends before its stored property changes. Use the
            // incoming selection, including cancellation, to register now.
            self?.updateRegistration(for: ids)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(to scroll: NSScrollView) {
        guard scrollView !== scroll else { updateFrame(); return }
        detach()
        scrollView = scroll
        let clip = scroll.contentView
        clip.addSubview(self, positioned: .above, relativeTo: nil)
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: clip,
                                                                       queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFrame() }
            })
        }
        updateFrame()
        updateRegistration(for: ProjectMaterialDragState.shared.assetIDs)
    }

    func detach() {
        setTarget(false)
        forwardedDestination?.draggingExited(nil)
        forwardedDestination = nil
        unregisterDraggedTypes()
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        removeFromSuperview()
        scrollView = nil
    }

    private func updateFrame() {
        guard let clip = scrollView?.contentView else { return }
        frame = clip.bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, onCreateGroup != nil, !currentDragIDs.isEmpty, let superview,
              frame.contains(point), isBlank(at: superview.convert(point, to: nil)) else { return nil }
        return self
    }

    private var currentDragIDs: Set<UUID> {
        let ids = Set(ProjectMaterialDragState.shared.assetIDs)
        return ids.isSubset(of: validAssetIDs) ? ids : []
    }

    private func isBlank(at windowPoint: NSPoint) -> Bool {
        guard let scrollView, scrollView.window != nil, let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        guard clip.bounds.contains(clip.convert(windowPoint, from: nil)) else { return false }
        // The overlay is a sibling of the document. Hit-test only the document
        // to avoid recursively hitting this overlay again.
        let point = document.superview?.convert(windowPoint, from: nil) ?? windowPoint
        var hit = document.hitTest(point)
        while let view = hit, view !== document {
            if view is ProjectPhotoGroupContainerView || view is ProjectMaterialDocumentView
                || view is ProjectPhotoGroupHandleView || view is NSScrollView
                || view is NSControl || view is NSText { return false }
            hit = view.superview
        }
        return true
    }

    private func rowDestination(at windowPoint: NSPoint) -> NSView? {
        guard let scrollView, let document = scrollView.documentView,
              scrollView.contentView.bounds.contains(scrollView.contentView.convert(windowPoint, from: nil)) else { return nil }
        let point = document.superview?.convert(windowPoint, from: nil) ?? windowPoint
        var hit = document.hitTest(point)
        while let view = hit, view !== document {
            if view is ProjectMaterialDocumentView || view is ProjectPhotoGroupContainerView { return view }
            hit = view.superview
        }
        return nil
    }

    private func forwardDestination(for sender: NSDraggingInfo) -> NSView? {
        let next = isActive ? rowDestination(at: sender.draggingLocation) : nil
        if next !== forwardedDestination {
            forwardedDestination?.draggingExited(sender)
            forwardedDestination = next
            if let next { _ = next.draggingEntered(sender) }
        }
        return next
    }

    private func assetIDs(from sender: NSDraggingInfo) -> Set<UUID> {
        guard isActive, onCreateGroup != nil,
              sender.draggingSource is ProjectMaterialDocumentView,
              sender.draggingPasteboard.availableType(from: [ProjectPhotoGroupDragPayload.type]) == nil,
              isBlank(at: sender.draggingLocation),
              let data = sender.draggingPasteboard.data(forType: ProjectMaterialBoard.assetPasteboardType),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        let decoded = values.compactMap(UUID.init(uuidString:))
        let ids = Set(decoded)
        guard decoded.count == values.count, !ids.isEmpty, ids == currentDragIDs else { return [] }
        return ids
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // AppKit's registered drag regions need not follow ordinary hitTest.
        // If it targets this viewport overlay over a row, explicitly preserve
        // that row's existing photo drop/reorder destination.
        if let destination = forwardDestination(for: sender) {
            setTarget(false)
            return destination.draggingUpdated(sender)
        }
        let accepted = !assetIDs(from: sender).isEmpty
        setTarget(accepted)
        return accepted ? .move : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let destination = forwardDestination(for: sender) { return destination.prepareForDragOperation(sender) }
        return !assetIDs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setTarget(false) }
        if let destination = forwardDestination(for: sender) {
            defer { forwardedDestination = nil }
            return destination.performDragOperation(sender)
        }
        let ids = assetIDs(from: sender)
        guard !ids.isEmpty else { return false }
        return onCreateGroup?(ids) ?? false
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        forwardedDestination?.draggingExited(sender)
        forwardedDestination = nil
        setTarget(false)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        forwardedDestination?.draggingEnded(sender)
        forwardedDestination = nil
        setTarget(false)
    }

    private func updateRegistration(for ids: [UUID]) {
        let selected = Set(ids)
        if isActive, scrollView != nil, !selected.isEmpty, selected.isSubset(of: validAssetIDs) {
            registerForDraggedTypes([ProjectMaterialBoard.assetPasteboardType])
        } else {
            unregisterDraggedTypes()
            forwardedDestination?.draggingExited(nil)
            forwardedDestination = nil
            setTarget(false)
        }
    }

    private func setTarget(_ targeted: Bool) {
        guard isDropTarget != targeted else { return }
        isDropTarget = targeted
        onTargetChange?(targeted)
    }
}
