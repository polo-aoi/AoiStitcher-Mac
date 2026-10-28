import AppKit
import SwiftUI

/// Native destination routing and SwiftUI attachment in undisplayed windows.
/// These checks never import files into or modify the user's project library.
@MainActor enum ProjectGroupBlankDropTests {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectGroupBlankDropTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 500))
        window.contentView = root
        let scroll = NSScrollView(frame: CGRect(x: 20, y: 20, width: 520, height: 440))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        let document = FlippedBlankDropView(frame: CGRect(x: 0, y: 0, width: 500, height: 250))
        scroll.documentView = document
        root.addSubview(scroll)
        let row = ProjectPhotoGroupContainerView(scrollView: NSScrollView(frame: .zero))
        row.frame = CGRect(x: 4, y: 20, width: 480, height: 80)
        let board = ProjectMaterialDocumentView(frame: CGRect(x: 0, y: 0, width: 440, height: 80))
        row.scrollView.documentView = board
        document.addSubview(row)
        row.layoutSubtreeIfNeeded()
        let second = ProjectPhotoGroupContainerView(scrollView: NSScrollView(frame: .zero))
        second.frame = CGRect(x: 4, y: 120, width: 480, height: 80)
        document.addSubview(second)
        second.layoutSubtreeIfNeeded()
        scroll.tile()
        scroll.contentView.scroll(to: .zero)
        root.layoutSubtreeIfNeeded()
        let source = ProjectMaterialDocumentView(frame: .zero)
        let firstID = UUID(), secondID = UUID(), staleID = UUID()
        let valid: Set<UUID> = [firstID, secondID]
        let destination = ProjectGroupBlankDropView(frame: .zero)
        destination.validAssetIDs = valid
        var created: [Set<UUID>] = []
        var highlights: [Bool] = []
        destination.onCreateGroup = { created.append($0); return true }
        destination.onTargetChange = { highlights.append($0) }
        destination.attach(to: scroll)
        defer {
            ProjectMaterialDragState.shared.assetIDs = []
            destination.detach()
            window.close()
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let drag = BlankPhotoDraggingInfo(pasteboard: pasteboard, source: source)
        func payload(_ ids: [UUID]) throws {
            pasteboard.clearContents()
            pasteboard.setData(try JSONEncoder().encode(ids.map(\.uuidString)),
                               forType: ProjectMaterialBoard.assetPasteboardType)
            ProjectMaterialDragState.shared.assetIDs = ids
        }
        func point(_ view: NSView, _ point: CGPoint) {
            drag.draggingLocation = view.convert(point, to: nil)
        }
        func rootHit(_ view: NSView, _ point: CGPoint) -> NSView? {
            root.hitTest(root.superview?.convert(view.convert(point, to: nil), from: nil)
                         ?? view.convert(point, to: nil))
        }
        func nativeDestination(_ hit: NSView?) -> NSView? {
            var view = hit
            while let current = view {
                if current.registeredDraggedTypes.contains(ProjectMaterialBoard.assetPasteboardType) { return current }
                view = current.superview
            }
            return nil
        }
        try check(destination.superview === scroll.contentView && destination.frame == scroll.contentView.bounds,
                  "The scoped overlay covers exactly the viewport, including unused space below content")
        try check(rootHit(document, CGPoint(x: 200, y: 110)) !== destination,
                  "Normal mouse hits pass through the overlay")
        try check(destination.registeredDraggedTypes.isEmpty,
                  "An idle overlay has no AppKit drag region, independently of normal hit testing")
        try payload([firstID, secondID])
        try check(destination.registeredDraggedTypes == [ProjectMaterialBoard.assetPasteboardType],
                  "The incoming Published multi-photo drag immediately registers the blank destination")
        for p in [CGPoint(x: 200, y: 8), CGPoint(x: 200, y: 110), CGPoint(x: 200, y: 350)] {
            point(document, p)
            try check(rootHit(document, p) === destination,
                      "Padding, inter-row gaps and blank viewport below short content reach the new destination")
            try check(destination.draggingEntered(drag) == .move && destination.isDropTarget,
                      "Multiple current photos highlight blank space as a new group destination")
            try check(destination.prepareForDragOperation(drag) && destination.performDragOperation(drag),
                      "A blank drop commits a group using the final pointer position")
        }
        try check(created.count == 3 && created.allSatisfy { $0 == valid } && highlights.last == false,
                  "Each accepted drop delivers exactly the selected IDs and clears feedback")
        for (view, p) in [(row.handleView as NSView, CGPoint(x: 12, y: 40)),
                          (board as NSView, CGPoint(x: 30, y: 40)),
                          (second as NSView, CGPoint(x: 400, y: 40))] {
            point(view, p)
            try check(rootHit(view, p) !== destination && nativeDestination(rootHit(view, p)) !== destination,
                      "Existing group photos, handles and trailing blank space keep native destination routing")
            try check(destination.draggingUpdated(drag).isEmpty && !destination.performDragOperation(drag),
                      "The blank destination never creates a group inside an existing row")
        }
        point(document, CGPoint(x: 200, y: 350))
        row.onDropAssets = { created.append($0) }
        point(row.handleView, CGPoint(x: 12, y: 40))
        try check(nativeDestination(rootHit(row.handleView, CGPoint(x: 12, y: 40))) === row &&
                  row.performDragOperation(drag) && created.last == valid,
                  "An active blank overlay leaves existing row add-photos behavior callable through its native target")
        point(document, CGPoint(x: 200, y: 350))
        _ = destination.draggingEntered(drag)
        ProjectMaterialDragState.shared.assetIDs = []
        try check(!destination.isDropTarget && rootHit(document, CGPoint(x: 200, y: 350)) !== destination &&
                  destination.registeredDraggedTypes.isEmpty && !destination.performDragOperation(drag),
                  "Cancelling the source immediately unregisters its drag region and clears feedback")
        try payload([firstID])
        try check(destination.registeredDraggedTypes.contains(ProjectMaterialBoard.assetPasteboardType) &&
                  destination.draggingEntered(drag) == .move && destination.prepareForDragOperation(drag) &&
                  destination.performDragOperation(drag) && created.last == [firstID],
                  "A single photo registers the blank destination and creates a one-photo group")
        try payload([firstID, secondID, staleID])
        try check(destination.draggingEntered(drag).isEmpty && !destination.performDragOperation(drag),
                  "Payloads containing stale or foreign IDs do not silently create partial groups")
        try payload([firstID, secondID])
        destination.validAssetIDs = [firstID]
        try check(destination.draggingEntered(drag).isEmpty && !destination.performDragOperation(drag),
                  "Changes to the active project are revalidated at drop time")
        destination.validAssetIDs = valid
        drag.source = NSObject()
        try check(destination.draggingEntered(drag).isEmpty && !destination.performDragOperation(drag),
                  "External sources cannot forge an internal photo drag")
        drag.source = source
        pasteboard.setString(UUID().uuidString, forType: ProjectPhotoGroupDragPayload.type)
        try check(!destination.prepareForDragOperation(drag) && !destination.performDragOperation(drag),
                  "Whole-group drag payloads cannot accidentally create new groups")
        try payload([firstID, secondID])
        pasteboard.setData(Data("bad-json".utf8), forType: ProjectMaterialBoard.assetPasteboardType)
        try check(destination.draggingEntered(drag).isEmpty && !destination.performDragOperation(drag),
                  "Malformed payloads are rejected")
        try payload([firstID, secondID])
        pasteboard.setData(try JSONEncoder().encode([firstID.uuidString, "invalid-uuid"]),
                           forType: ProjectMaterialBoard.assetPasteboardType)
        try check(!destination.performDragOperation(drag), "Malformed UUID members invalidate the whole payload")
        try payload([firstID, secondID])
        _ = destination.draggingEntered(drag)
        destination.isActive = false
        try check(!destination.isDropTarget && rootHit(document, CGPoint(x: 200, y: 350)) !== destination &&
                  !destination.prepareForDragOperation(drag) && !destination.performDragOperation(drag),
                  "Inactive or modal workspaces release hits and reject drops")
        destination.isActive = true
        destination.onCreateGroup = { _ in false }
        try check(!destination.performDragOperation(drag), "A failed model commit reports failure to AppKit")
        destination.onCreateGroup = { created.append($0); return true }
        document.frame.size.height = 800
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
        try check(destination.frame == scroll.contentView.bounds,
                  "Scrolling keeps the destination over the visible clip, rather than the original content origin")
        point(scroll.contentView, CGPoint(x: 200, y: 600))
        try check(destination.draggingEntered(drag) == .move, "Blank content remains droppable after scrolling")
        scroll.frame.size = CGSize(width: 440, height: 330)
        scroll.tile()
        try check(destination.frame == scroll.contentView.bounds,
                  "Resizing the pane follows the actual clip dimensions and excludes scrollbars")
        destination.attach(to: scroll)
        try check(scroll.contentView.subviews.filter { $0 === destination }.count == 1,
                  "Repeated attachment never duplicates the overlay")
        _ = destination.draggingEntered(drag)
        destination.detach()
        try check(destination.superview == nil && destination.scrollView == nil && !destination.isDropTarget &&
                  !destination.performDragOperation(drag), "Detaching clears feedback and rejects stale drops")

        // The empty SwiftUI pane must attach to the outer viewport and allow
        // drops even when its lazy content is much shorter than that viewport.
        let host = NSHostingView(rootView: BlankDropFixture(isActive: true, validIDs: valid))
        host.frame = root.bounds
        window.contentView = host
        func settle() async throws {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        guard let reader = descendants(of: host, matching: ProjectGroupBlankDropReaderView.self).first,
              let enclosing = reader.enclosingScrollView else {
            throw NSError(domain: "ProjectGroupBlankDropTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "SwiftUI blank drop reader did not attach"])
        }
        let installed = reader.destination
        try check(installed.superview === enclosing.contentView && installed.frame == enclosing.contentView.bounds &&
                  reader.hitTest(.zero) == nil, "The SwiftUI reader installs a scoped destination over the whole empty viewport")
        let blank = CGPoint(x: enclosing.contentView.bounds.midX, y: enclosing.contentView.bounds.maxY - 30)
        point(enclosing.contentView, blank)
        let hostPoint = host.superview?.convert(drag.draggingLocation, from: nil) ?? drag.draggingLocation
        try check(host.hitTest(hostPoint) === installed && installed.performDragOperation(drag),
                  "The real SwiftUI empty pane routes and accepts a drop below its short content")
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blank-drop-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let fixtureLibrary = ProjectLibraryStore(projectsDirectory: fixtureDirectory)
        let fixtureGroup = UUID()
        let fixtureMembers = [firstID, secondID].map {
            ProjectAsset(id: $0, fileName: "photo.png", name: "photo.png", position: .zero, groupID: fixtureGroup)
        }
        host.rootView = BlankDropFixture(isActive: true, validIDs: valid, library: fixtureLibrary,
                                         groupID: fixtureGroup, members: fixtureMembers)
        try await settle()
        guard let hostedRow = descendants(of: host, matching: ProjectPhotoGroupContainerView.self).first,
              let hostedBoard = hostedRow.scrollView.documentView as? ProjectMaterialDocumentView else {
            throw NSError(domain: "ProjectGroupBlankDropTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "SwiftUI group row did not attach"])
        }
        let previousCreated = created.count
        installed.onCreateGroup = { created.append($0); return true }
        for (view, p) in [(hostedRow.handleView as NSView, CGPoint(x: 12, y: 35)),
                          (hostedBoard as NSView, CGPoint(x: 24, y: 35)),
                          (hostedRow as NSView, CGPoint(x: hostedRow.bounds.maxX - 20, y: 35))] {
            point(view, p)
            let rootPoint = host.superview?.convert(drag.draggingLocation, from: nil) ?? drag.draggingLocation
            let hit = host.hitTest(rootPoint)
            try check(hit !== installed && nativeDestination(hit) !== installed && nativeDestination(hit) != nil,
                      "A real SwiftUI group row retains native photo/handle/trailing-space routing during a photo drag")
            try check(!installed.draggingEntered(drag).isEmpty && installed.prepareForDragOperation(drag) &&
                      installed.performDragOperation(drag) && created.count == previousCreated,
                      "If AppKit targets the registered overlay over a row, it forwards to the existing row without creating a group")
        }
        host.rootView = BlankDropFixture(isActive: false, validIDs: valid)
        try await settle()
        try check(!installed.isActive && !installed.performDragOperation(drag), "SwiftUI active state reaches the installed destination")
        reader.disconnect()
        try await settle()
        try check(installed.superview == nil && installed.onCreateGroup == nil && installed.onTargetChange == nil,
                  "Dismantling removes the overlay, callbacks and pending attachment")
        try check(!window.isVisible, "All routing tests leave the window undisplayed")
        return checks
    }

    private static func descendants<T: NSView>(of root: NSView, matching type: T.Type) -> [T] {
        root.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: child, matching: type)
        }
    }
}

private final class FlippedBlankDropView: NSView {
    override var isFlipped: Bool { true }
}

private struct BlankDropFixture: View {
    let isActive: Bool
    let validIDs: Set<UUID>
    var library: ProjectLibraryStore? = nil
    var groupID = UUID()
    var members: [ProjectAsset] = []
    var body: some View {
        ScrollView {
            LazyVStack {
                if let library {
                    ProjectPhotoGroupRow(library: library,
                                         group: ProjectPhotoGroup(id: groupID, assetIDs: members.map(\.id)),
                                         members: members, thumbnailSize: 80, selection: .constant([]),
                                         isSelected: false, isActive: isActive, canMoveUp: false, canMoveDown: false,
                                         badges: [:], onChoose: {}, onClearSelection: {}, onFocus: {}, onSend: { _, _ in },
                                         showDropLineBefore: false, showDropLineAfter: false,
                                         onGroupDragBegan: {}, onGroupDragEnded: {}, onGroupDragHover: { _, _ in false },
                                         onGroupDragExit: {}, onDropGroup: { _, _ in false }, onAssetDropTargetChange: { _ in })
                } else {
                    Text("拖到空白处新建组").padding(30)
                }
            }.frame(maxWidth: .infinity)
                .projectGroupBlankDrop(isActive: isActive, validAssetIDs: validIDs, onCreateGroup: { _ in true })
        }
    }
}

@MainActor private final class BlankPhotoDraggingInfo: NSObject, NSDraggingInfo {
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
