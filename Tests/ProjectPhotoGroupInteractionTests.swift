import AppKit

/// Calls native mouse and drag destination methods directly. No application,
/// window, screenshot, or interactive drag session is started by these checks.
@MainActor enum ProjectPhotoGroupInteractionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectPhotoGroupInteractionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        let sourceID = UUID()
        let targetID = UUID()
        let handle = RecordingGroupHandle(frame: CGRect(x: 0, y: 0, width: 32, height: 120))
        handle.groupID = sourceID
        handle.memberCount = 4
        try check(handle.accessibilityLabel() == "照片组，4 张照片" &&
                  handle.toolTip == "4 张照片；点击选中整组；拖动调整顺序",
                  "The compact handle preserves photo counts in accessibility and hover help")
        var chosen = 0
        var began = 0
        var ended = 0
        handle.onChoose = { chosen += 1 }
        handle.onDragBegan = { began += 1 }
        handle.onDragEnded = { ended += 1 }

        // Clicks anywhere in the full-height strip select the group.
        for point in [CGPoint(x: 4, y: 4), CGPoint(x: 16, y: 60), CGPoint(x: 28, y: 116)] {
            handle.mouseDown(with: mouse(.leftMouseDown, point, in: handle))
            handle.mouseUp(with: mouse(.leftMouseUp, point, in: handle))
        }
        try check(chosen == 3 && began == 0, "The whole handle strip selects without beginning a drag")
        handle.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 40), in: handle))
        handle.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 20, y: 43), in: handle))
        try check(began == 0, "Sub-threshold mouse movement remains a click")
        handle.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 20, y: 44), in: handle))
        try check(began == 1 && handle.startedItems.count == 1,
                  "Four points of movement starts the native group drag from the handle")
        try check(handle.startedItems[0].string(forType: ProjectPhotoGroupDragPayload.type) == sourceID.uuidString &&
                  handle.startedItems[0].data(forType: ProjectMaterialBoard.assetPasteboardType) == nil,
                  "The native source writes only a dedicated group payload")
        handle.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 20, y: 90), in: handle))
        try check(began == 1, "Further mouse movement does not start a second session")
        handle.finishDrag()
        handle.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 20, y: 90), in: handle))
        try check(ended == 1 && chosen == 3, "Ending or cancelling a drag clears the pending click")
        handle.finishDrag()
        try check(ended == 1, "A drag end callback is issued exactly once")

        handle.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10, y: 20), in: handle))
        handle.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 10, y: 30), in: handle))
        handle.isActive = false
        handle.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 10, y: 30), in: handle))
        try check(began == 2 && ended == 2 && chosen == 3, "Disabling a source cancels its drag and pending click")
        handle.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10, y: 20), in: handle))
        handle.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 10, y: 40), in: handle))
        try check(began == 2 && !handle.accessibilityPerformPress(), "Inactive handles reject mouse and accessibility actions")
        handle.isActive = true
        try check(handle.accessibilityPerformPress() && chosen == 4, "Keyboard and accessibility activation select the group")

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 120))
        let destination = ProjectPhotoGroupContainerView(scrollView: scroll)
        destination.groupID = targetID
        destination.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        destination.layoutSubtreeIfNeeded()
        try check(destination.handleView.frame == CGRect(x: 0, y: 0, width: 32, height: 120) &&
                  scroll.frame == CGRect(x: 32, y: 0, width: 288, height: 120),
                  "The compact native handle spans the full row and reserves only 32 points")
        for y in [CGFloat(3), 60, 117] {
            try check(destination.hitTest(CGPoint(x: 20, y: y)) === destination.handleView,
                      "Clicks at each height reach the native handle")
        }
        try check(destination.registeredDraggedTypes.contains(ProjectPhotoGroupDragPayload.type) &&
                  destination.registeredDraggedTypes.contains(ProjectMaterialBoard.assetPasteboardType),
                  "The native parent accepts group drops throughout the row and photo drops on the handle")
        destination.frame.size = CGSize(width: 470, height: 280)
        destination.layoutSubtreeIfNeeded()
        try check(destination.handleView.frame == CGRect(x: 0, y: 0, width: 32, height: 280) &&
                  scroll.frame == CGRect(x: 32, y: 0, width: 438, height: 280),
                  "Resizing thumbnails or the sidebar preserves a full-height 32-point handle and fills the photo viewport")
        destination.frame.size = CGSize(width: 320, height: 120)
        destination.layoutSubtreeIfNeeded()

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([ProjectPhotoGroupDragPayload.item(for: sourceID)])
        let drag = GroupDraggingInfo(pasteboard: pasteboard, source: handle)
        var hovered: [(UUID, Bool)] = []
        var dropped: [(UUID, Bool)] = []
        var exits = 0
        destination.onGroupDragHover = { id, before in hovered.append((id, before)); return id == sourceID }
        destination.onDropGroup = { id, before in dropped.append((id, before)); return id == sourceID }
        destination.onGroupDragExit = { exits += 1 }

        // The entire row uses one flipped coordinate space, including photos.
        drag.draggingLocation = destination.convert(CGPoint(x: 250, y: 15), to: nil)
        try check(destination.draggingEntered(drag) == .move && hovered.last?.1 == true,
                  "Dragging over the upper photo region proposes insertion before the row")
        drag.draggingLocation = destination.convert(CGPoint(x: 20, y: 105), to: nil)
        try check(destination.draggingUpdated(drag) == .move && hovered.last?.1 == false,
                  "Dragging over the lower handle region proposes insertion after the row")
        destination.draggingExited(drag)
        try check(exits == 1, "Leaving the row clears its insertion indicator")
        drag.draggingLocation = destination.convert(CGPoint(x: 250, y: 15), to: nil)
        try check(destination.performDragOperation(drag) && dropped.last?.0 == sourceID && dropped.last?.1 == true,
                  "A drop is resolved from its own payload and location even after hover state was cleared")
        drag.draggingLocation = destination.convert(CGPoint(x: 250, y: 105), to: nil)
        try check(destination.prepareForDragOperation(drag) && destination.performDragOperation(drag) &&
                  dropped.last?.1 == false,
                  "The final lower-half drop inserts after, independently of a previous before marker")

        destination.groupID = sourceID
        try check(destination.draggingUpdated(drag).isEmpty && !destination.performDragOperation(drag),
                  "Dropping a group onto itself does not produce a move")
        destination.groupID = targetID
        drag.source = NSObject()
        try check(destination.draggingUpdated(drag).isEmpty && !destination.performDragOperation(drag),
                  "External sources cannot forge a group move using copied text or a custom type")
        drag.source = handle
        pasteboard.clearContents()
        pasteboard.setString("not-a-uuid", forType: ProjectPhotoGroupDragPayload.type)
        try check(!destination.prepareForDragOperation(drag) && !destination.performDragOperation(drag),
                  "Malformed group data is rejected")
        pasteboard.clearContents()
        pasteboard.setString(sourceID.uuidString, forType: .string)
        try check(destination.draggingUpdated(drag).isEmpty && !destination.performDragOperation(drag),
                  "Plain text UUIDs do not sort groups")
        pasteboard.clearContents()
        pasteboard.writeObjects([ProjectPhotoGroupDragPayload.item(for: UUID())])
        try check(!destination.performDragOperation(drag), "A group payload must match its native source")

        let asset = UUID()
        var receivedAssets: Set<UUID> = []
        var photoHighlights: [Bool] = []
        destination.onDropAssets = { receivedAssets = $0 }
        destination.onAssetDropTargetChange = { photoHighlights.append($0) }
        pasteboard.clearContents()
        pasteboard.setData(try JSONEncoder().encode([asset.uuidString]), forType: ProjectMaterialBoard.assetPasteboardType)
        let groupDropCount = dropped.count
        try check(destination.draggingEntered(drag) == .move && photoHighlights.last == true,
                  "A photo dropped onto the left strip highlights a photo destination")
        try check(destination.performDragOperation(drag) && receivedAssets == [asset] && dropped.count == groupDropCount &&
                  photoHighlights.last == false,
                  "Photo drops move members without invoking group reordering and clear feedback")
        pasteboard.clearContents()
        pasteboard.setData(Data("broken".utf8), forType: ProjectMaterialBoard.assetPasteboardType)
        try check(destination.draggingUpdated(drag).isEmpty && !destination.performDragOperation(drag),
                  "Malformed photo data is rejected without changing membership")

        pasteboard.clearContents()
        pasteboard.writeObjects([ProjectPhotoGroupDragPayload.item(for: sourceID)])
        _ = destination.draggingEntered(drag)
        let previousExits = exits
        destination.isActive = false
        try check(exits == previousExits + 1 && destination.registeredDraggedTypes.isEmpty &&
                  destination.draggingUpdated(drag).isEmpty && !destination.prepareForDragOperation(drag) &&
                  !destination.performDragOperation(drag),
                  "Inactive destinations remove feedback, unregister types and reject drops")
        destination.isActive = true
        destination.disconnect()
        try check(!destination.isActive && !destination.handleView.isActive && destination.onDropGroup == nil,
                  "Dismantling the row disconnects native callbacks")
        return checks
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                          clickCount: 1, pressure: 1)!
    }
}

@MainActor private final class RecordingGroupHandle: ProjectPhotoGroupHandleView {
    var startedItems: [NSPasteboardItem] = []

    override func beginGroupDragging(with event: NSEvent, item: NSPasteboardItem) {
        startedItems.append(item)
    }
}

@MainActor private final class GroupDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var source: AnyObject?
    var draggingSource: Any? { source }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation = CGPoint.zero
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard, source: AnyObject?) {
        draggingPasteboard = pasteboard
        self.source = source
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
