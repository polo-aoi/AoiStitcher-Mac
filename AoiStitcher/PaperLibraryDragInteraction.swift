import AppKit
import SwiftUI

enum PaperLibraryDragNode: Codable, Equatable {
    case folder(UUID)
    case item(UUID)
}

enum PaperLibraryDropFeedback: Equatable {
    case root
    case insideFolder(UUID)
    case beforeFolder(UUID)
    case afterFolder(UUID)
    case beforeItem(UUID)
    case afterItem(UUID)
}

struct PaperLibraryDragPayload: Codable {
    static let type = NSPasteboard.PasteboardType("com.aoipic.paper-library-node")
    let node: PaperLibraryDragNode
    let directory: URL

    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(self) { item.setData(data, forType: Self.type) }
        return item
    }

    static func read(from pasteboard: NSPasteboard, library: PaperLibraryStore) -> PaperLibraryDragNode? {
        guard let data = pasteboard.data(forType: type),
              let payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.directory.standardizedFileURL == library.directory else { return nil }
        switch payload.node {
        case .folder(let id): return library.folders.contains { $0.id == id } ? payload.node : nil
        case .item(let id): return library.items.contains { $0.id == id } ? payload.node : nil
        }
    }
}

struct PaperLibraryDropDestination {
    enum Target { case root, folder(UUID), breadcrumbFolder(UUID), item(UUID) }
    let target: Target
    let library: PaperLibraryStore

    func feedback(for node: PaperLibraryDragNode, at point: CGPoint, height: CGFloat) -> PaperLibraryDropFeedback? {
        switch target {
        case .root:
            return .root
        case .folder(let id):
            guard let folder = library.folders.first(where: { $0.id == id }) else { return nil }
            if case .folder(let sourceID) = node {
                guard sourceID != id else { return nil }
                if point.y < 7 || point.y > height - 7 {
                    guard canMove(node, into: folder.parentID) else { return nil }
                    return point.y < 7 ? .beforeFolder(id) : .afterFolder(id)
                }
            }
            return canMove(node, into: id) ? .insideFolder(id) : nil
        case .breadcrumbFolder(let id):
            return canMove(node, into: id) ? .insideFolder(id) : nil
        case .item(let id):
            guard case .item(let sourceID) = node, sourceID != id,
                  library.items.contains(where: { $0.id == id }) else { return nil }
            return point.y < height / 2 ? .beforeItem(id) : .afterItem(id)
        }
    }

    private func canMove(_ node: PaperLibraryDragNode, into parentID: UUID?) -> Bool {
        guard let parentID else { return true }
        guard library.folders.contains(where: { $0.id == parentID }) else { return false }
        guard case .folder(let sourceID) = node else { return true }
        var current: UUID? = parentID
        var visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted {
            if id == sourceID { return false }
            current = library.folders.first(where: { $0.id == id })?.parentID
        }
        return true
    }

    func move(_ node: PaperLibraryDragNode, to placement: PaperLibraryDropFeedback) -> Bool {
        switch placement {
        case .root, .insideFolder:
            let parentID: UUID?
            if case .insideFolder(let id) = placement { parentID = id } else { parentID = nil }
            switch node {
            case .folder(let id): return library.moveFolder(id: id, to: parentID)
            case .item(let id): return library.moveItem(id: id, to: parentID)
            }
        case .beforeFolder(let targetID), .afterFolder(let targetID):
            guard case .folder(let sourceID) = node,
                  let folder = library.folders.first(where: { $0.id == targetID }) else { return false }
            var beforeID: UUID? = targetID
            if case .afterFolder = placement {
                let siblings = library.folders.filter { $0.parentID == folder.parentID && $0.id != sourceID }
                guard let index = siblings.firstIndex(where: { $0.id == targetID }) else { return false }
                beforeID = siblings.dropFirst(index + 1).first?.id
            }
            return library.moveFolder(id: sourceID, to: folder.parentID, beforeFolderID: beforeID)
        case .beforeItem(let targetID), .afterItem(let targetID):
            guard case .item(let sourceID) = node,
                  let item = library.items.first(where: { $0.id == targetID }) else { return false }
            var beforeID: UUID? = targetID
            if case .afterItem = placement {
                let siblings = library.items.filter { $0.parentID == item.parentID && $0.id != sourceID }
                guard let index = siblings.firstIndex(where: { $0.id == targetID }) else { return false }
                beforeID = siblings.dropFirst(index + 1).first?.id
            }
            return library.moveItem(id: sourceID, to: item.parentID, beforeItemID: beforeID)
        }
    }

    func parentID(for placement: PaperLibraryDropFeedback) -> UUID? {
        switch placement {
        case .root: return nil
        case .insideFolder(let id): return id
        case .beforeFolder(let id), .afterFolder(let id): return library.folders.first { $0.id == id }?.parentID
        case .beforeItem(let id), .afterItem(let id): return library.items.first { $0.id == id }?.parentID
        }
    }
}

/// A native source owns the initial mouse gesture, so the hosted SwiftUI
/// button cannot consume the drag in its click-tracking loop.
struct PaperLibraryDragRow<Content: View>: NSViewRepresentable {
    let library: PaperLibraryStore
    let target: PaperLibraryDropDestination.Target
    var node: PaperLibraryDragNode? = nil
    var isEnabled: Bool
    var onClick: ((CGPoint) -> Void)? = nil
    var onDragState: (Bool) -> Void
    var onFeedback: (PaperLibraryDropFeedback?) -> Void
    var onMove: (UUID?) -> Void
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> PaperLibraryDragView {
        let view = PaperLibraryDragView(frame: .zero)
        let host = NSHostingView(rootView: content())
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        view.hostedView = host
        return view
    }

    func updateNSView(_ view: PaperLibraryDragView, context: Context) {
        (view.hostedView as? NSHostingView<Content>)?.rootView = content()
        view.destination = PaperLibraryDropDestination(target: target, library: library)
        view.node = node
        view.onClick = onClick
        view.onDragState = onDragState
        view.onFeedback = onFeedback
        view.onMove = onMove
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: PaperLibraryDragView, coordinator: ()) { view.disconnect() }
}

class PaperLibraryDragView: NSView, NSDraggingSource {
    var hostedView: NSView?
    var destination: PaperLibraryDropDestination?
    var node: PaperLibraryDragNode?
    var isEnabled = true {
        didSet {
            if isEnabled { registerForDraggedTypes([PaperLibraryDragPayload.type]) }
            else { unregisterDraggedTypes(); finishDrag() }
        }
    }
    var onClick: ((CGPoint) -> Void)?
    var onDragState: ((Bool) -> Void)?
    var onFeedback: ((PaperLibraryDropFeedback?) -> Void)?
    var onMove: ((UUID?) -> Void)?
    private var mouseDownPoint: CGPoint?
    private(set) var isDragging = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        hostedView?.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Keep context menus and accessibility on the original SwiftUI content.
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true { return hit }
        return isEnabled && node != nil ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, node != nil else { return }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, !isDragging, let start = mouseDownPoint,
              let node, let destination, !destination.library.isBusy else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        isDragging = true
        onDragState?(true)
        let payload = PaperLibraryDragPayload(node: node, directory: destination.library.directory)
        beginPaperDragging(with: event, item: payload.pasteboardItem())
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shouldClick = isEnabled && mouseDownPoint != nil && !isDragging && bounds.contains(point)
        mouseDownPoint = nil
        if shouldClick { onClick?(point) }
    }

    func beginPaperDragging(with event: NSEvent, item: NSPasteboardItem) {
        guard window != nil else { finishDrag(); return }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag()
    }

    func finishDrag() {
        mouseDownPoint = nil
        if isDragging { isDragging = false; onDragState?(false) }
        onFeedback?(nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (_, placement) = proposal(for: sender) else { onFeedback?(nil); return [] }
        onFeedback?(placement)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onFeedback?(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onFeedback?(nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { proposal(for: sender) != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onFeedback?(nil) }
        guard let destination, let (node, placement) = proposal(for: sender),
              destination.move(node, to: placement) else { return false }
        onMove?(destination.parentID(for: placement))
        return true
    }

    private func proposal(for sender: NSDraggingInfo) -> (PaperLibraryDragNode, PaperLibraryDropFeedback)? {
        guard isEnabled, let destination, !destination.library.isBusy,
              let node = PaperLibraryDragPayload.read(from: sender.draggingPasteboard, library: destination.library) else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        guard bounds.contains(point),
              let placement = destination.feedback(for: node, at: point, height: bounds.height) else { return nil }
        return (node, placement)
    }

    func disconnect() {
        isEnabled = false
        destination = nil
        onClick = nil
        onDragState = nil
        onFeedback = nil
        onMove = nil
    }
}
