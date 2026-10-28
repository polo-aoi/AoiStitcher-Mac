import AppKit

/// Exercises real native source mouse events and every drag destination phase.
/// The recording source replaces only the interactive session, not selection,
/// drag thresholds, payload encoding, cleanup or destination implementation.
@MainActor enum ProjectPhotoTransferRegressionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectPhotoTransferRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = FlippedPhotoTransferView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = root
        defer { ProjectMaterialDragState.shared.assetIDs = []; window.close() }
        let ids = (0..<4).map { _ in UUID() }
        let assets = ids.enumerated().map {
            ProjectAsset(id: $0.element, fileName: "photo-\($0.offset).png", name: "photo.png",
                         position: CGPoint(x: CGFloat($0.offset) * 104, y: 0))
        }
        func newBoard(group: Bool, frame: CGRect) -> RecordingPhotoTransferSource {
            let scroll = NSScrollView(frame: frame)
            let board = RecordingPhotoTransferSource(frame: .zero)
            board.isGroupRow = group
            scroll.documentView = board
            root.addSubview(scroll)
            return board
        }
        let materials = newBoard(group: false, frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let outerScroll = NSScrollView(frame: CGRect(x: 420, y: 0, width: 480, height: 600))
        let groupsDocument = FlippedPhotoTransferView(frame: CGRect(x: 0, y: 0, width: 480, height: 600))
        outerScroll.documentView = groupsDocument
        root.addSubview(outerScroll)
        func newRow(y: CGFloat) -> (ProjectPhotoGroupContainerView, RecordingPhotoTransferSource) {
            let scroll = NSScrollView(frame: .zero)
            let board = RecordingPhotoTransferSource(frame: .zero)
            board.isGroupRow = true
            scroll.documentView = board
            let row = ProjectPhotoGroupContainerView(scrollView: scroll)
            row.frame = CGRect(x: 4, y: y, width: 472, height: 114)
            groupsDocument.addSubview(row)
            row.layoutSubtreeIfNeeded()
            return (row, board)
        }
        let (firstRow, firstGroup) = newRow(y: 4)
        let (secondRow, secondGroup) = newRow(y: 124)
        let blank = ProjectGroupBlankDropView(frame: .zero)
        blank.validAssetIDs = Set(ids)
        var newGroups: [Set<UUID>] = []
        blank.onCreateGroup = { newGroups.append($0); return true }
        blank.attach(to: outerScroll)
        defer { blank.detach() }
        var received: [(String, Set<UUID>)] = []
        materials.onDropAssets = { received.append(("materials", $0)) }
        firstGroup.onDropAssets = { received.append(("first", $0)) }
        secondGroup.onDropAssets = { received.append(("second", $0)) }
        firstRow.onDropAssets = { received.append(("first-handle", $0)) }
        secondRow.onDropAssets = { received.append(("second-handle", $0)) }
        func configure(_ board: RecordingPhotoTransferSource, selection: Set<UUID>) {
            board.configure(assets: assets, selection: selection, thumbnailSize: 96, viewZoom: 1,
                            fitRequest: 0, thumbnails: [:], assetURLs: [:], badges: [:], operations: [], isActive: true)
        }
        for board in [materials, firstGroup, secondGroup] { configure(board, selection: []) }
        root.layoutSubtreeIfNeeded()
        func event(_ type: NSEvent.EventType, point: CGPoint, in board: NSView) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: board.convert(point, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func start(_ board: RecordingPhotoTransferSource, count: Int) throws -> TransferDraggingInfo {
            let wanted = Set(ids.prefix(count))
            configure(board, selection: wanted)
            board.items.removeAll()
            let margin: CGFloat = board.isGroupRow ? 4 : 12
            let point = CGPoint(x: margin + 25, y: margin + 25)
            board.mouseDown(with: event(.leftMouseDown, point: point, in: board))
            board.mouseDragged(with: event(.leftMouseDragged, point: CGPoint(x: point.x + 3, y: point.y), in: board))
            try check(board.items.isEmpty && ProjectMaterialDragState.shared.assetIDs.isEmpty,
                      "\(count)-photo source waits for the native drag threshold")
            board.mouseDragged(with: event(.leftMouseDragged, point: CGPoint(x: point.x + 6, y: point.y), in: board))
            try check(board.items.count == 1 && Set(ProjectMaterialDragState.shared.assetIDs) == wanted,
                      "\(count)-photo source starts and publishes the exact selected photos")
            let pasteboard = NSPasteboard.withUniqueName()
            guard let item = board.items.first?.item as? NSPasteboardItem else {
                throw NSError(domain: "ProjectPhotoTransferRegressionTests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Native photo source did not encode its pasteboard item"])
            }
            pasteboard.writeObjects([item])
            let strings = try JSONDecoder().decode([String].self,
                from: pasteboard.data(forType: ProjectMaterialBoard.assetPasteboardType)!)
            try check(Set(strings.compactMap(UUID.init(uuidString:))) == wanted,
                      "The actual source pasteboard preserves both single and multi-photo payloads")
            try check(blank.registeredDraggedTypes.contains(ProjectMaterialBoard.assetPasteboardType),
                      "Both single and multi-photo sessions register the blank destination")
            return TransferDraggingInfo(pasteboard: pasteboard, source: board)
        }
        func transfer(source: RecordingPhotoTransferSource, destination: NSView,
                      point: CGPoint, count: Int, label: String) throws {
            let drag = try start(source, count: count)
            defer { source.finishPhotoDragging(); drag.draggingPasteboard.releaseGlobally() }
            drag.draggingLocation = destination.convert(point, to: nil)
            try check(!destination.draggingEntered(drag).isEmpty && !destination.draggingUpdated(drag).isEmpty,
                      "\(label): drag entry and updates accept the source payload")
            // AppKit can exit the overlay before preparing the underlying view.
            destination.draggingExited(drag)
            try check(destination.prepareForDragOperation(drag) && destination.performDragOperation(drag),
                      "\(label): final data survives an exit/prepare transition and commits")
        }
        for count in [1, 2] {
            for (source, destination, label) in [
                (materials, firstGroup as NSView, "materials to existing group"),
                (firstGroup, secondGroup as NSView, "group to another group"),
                (firstGroup, materials as NSView, "group back to materials")
            ] {
                let previous = received.count
                try transfer(source: source, destination: destination, point: CGPoint(x: 30, y: 30), count: count, label: label)
                try check(received.count == previous + 1 && received.last?.1 == Set(ids.prefix(count)),
                          "\(label): exactly \(count) photos are transferred once")
                try check(ProjectMaterialDragState.shared.assetIDs.isEmpty && blank.registeredDraggedTypes.isEmpty,
                          "Finishing \(label) clears the source and native overlay registration")
            }
            for (view, point, target) in [(secondGroup as NSView, CGPoint(x: 30, y: 30), "second"),
                                         (secondRow.handleView as NSView, CGPoint(x: 12, y: 30), "second-handle"),
                                         (secondGroup as NSView, CGPoint(x: 430, y: 30), "second")] {
                let drag = try start(firstGroup, count: count)
                drag.draggingLocation = view.convert(point, to: nil)
                let previous = received.count
                try check(!blank.draggingEntered(drag).isEmpty && !blank.draggingUpdated(drag).isEmpty &&
                          blank.prepareForDragOperation(drag) && blank.performDragOperation(drag),
                          "Overlay callbacks over row photos, handles and trailing blank forward every drag phase")
                try check(received.count == previous + 1 && received.last?.0 == target &&
                          received.last?.1 == Set(ids.prefix(count)) && newGroups.isEmpty,
                          "Forwarded row drops keep their existing destination and never create a new group")
                firstGroup.finishPhotoDragging()
                drag.draggingPasteboard.releaseGlobally()
            }
            var reordered: [UUID: CGPoint] = [:]
            firstGroup.onMove = { reordered = $0 }
            let sameRowDrag = try start(firstGroup, count: count)
            sameRowDrag.draggingLocation = firstGroup.convert(CGPoint(x: 280, y: 30), to: nil)
            let receivedBeforeReorder = received.count
            try check(blank.draggingEntered(sameRowDrag) == .move && blank.draggingUpdated(sameRowDrag) == .move &&
                      blank.prepareForDragOperation(sameRowDrag) && blank.performDragOperation(sameRowDrag),
                      "Dragging within the same row keeps the native internal-reorder path through overlay forwarding")
            try check(Set(reordered.keys) == Set(ids.prefix(count)) && received.count == receivedBeforeReorder,
                      "Single and multi-photo same-row drags reorder selected members instead of transferring or creating groups")
            firstGroup.finishPhotoDragging()
            sameRowDrag.draggingPasteboard.releaseGlobally()
        }
        let drag = try start(materials, count: 2)
        defer { materials.finishPhotoDragging(); drag.draggingPasteboard.releaseGlobally() }
        drag.draggingLocation = groupsDocument.convert(CGPoint(x: 250, y: 400), to: nil)
        try check(blank.draggingEntered(drag) == .move && blank.isDropTarget,
                  "A multi-photo session still highlights genuine blank space")
        drag.draggingLocation = secondGroup.convert(CGPoint(x: 30, y: 30), to: nil)
        try check(!blank.draggingUpdated(drag).isEmpty && !blank.isDropTarget,
                  "Moving into a row switches from new-group feedback to its native destination")
        drag.draggingLocation = groupsDocument.convert(CGPoint(x: 250, y: 400), to: nil)
        try check(blank.draggingUpdated(drag) == .move && blank.prepareForDragOperation(drag) &&
                  blank.performDragOperation(drag) && newGroups == [Set(ids.prefix(2))],
                  "Moving back to blank space creates exactly one new group at the final drop point")
        try check(!window.isVisible, "Source and destination tests never display a window or touch the user's library")
        return checks
    }
}

private final class RecordingPhotoTransferSource: ProjectMaterialDocumentView {
    var items: [NSDraggingItem] = []
    override func beginPhotoDragging(with event: NSEvent, item: NSDraggingItem) { items.append(item) }
}

private final class FlippedPhotoTransferView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class TransferDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var source: AnyObject?
    var draggingSource: Any? { source }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy] }
    var draggingLocation = CGPoint.zero
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(pasteboard: NSPasteboard, source: AnyObject?) { draggingPasteboard = pasteboard; self.source = source }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
