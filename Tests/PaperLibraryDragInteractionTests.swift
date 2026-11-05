import AppKit
import SwiftUI

/// Native handlers are called on undisplayed views. The recording source
/// replaces only beginDraggingSession, so no system input or screen is used.
@MainActor enum PaperLibraryDragInteractionTests {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "PaperLibraryDragInteractionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("paper-drag-tests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: directory) }
        let library = PaperLibraryStore(directory: directory)
        let first = library.createFolder(named: "第一", parentID: nil)!
        let second = library.createFolder(named: "第二", parentID: nil)!
        let child = library.createFolder(named: "子级", parentID: first)!
        let grandchild = library.createFolder(named: "孙级", parentID: child)!
        let paper = library.createColor(named: "子级纸张", color: .red, parentID: child)!
        let rootPaper = library.createColor(named: "根目录纸张", color: .blue, parentID: nil)!
        let lastPaper = library.createColor(named: "末尾纸张", color: .green, parentID: nil)!

        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = PaperDragTestContent(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        window.contentView = content
        defer { window.close() }
        var rowNumber = 0
        func row(_ target: PaperLibraryDropDestination.Target, node: PaperLibraryDragNode? = nil) -> RecordingPaperDragView {
            let view = RecordingPaperDragView(frame: CGRect(x: 20, y: 20 + rowNumber * 34, width: 300, height: 28))
            rowNumber += 1
            view.destination = PaperLibraryDropDestination(target: target, library: library)
            view.node = node
            view.isEnabled = true
            content.addSubview(view)
            return view
        }
        var pasteboards: [NSPasteboard] = []
        defer { pasteboards.forEach { $0.releaseGlobally() } }
        func pasteboard(_ node: PaperLibraryDragNode, directory: URL? = nil) -> NSPasteboard {
            let board = NSPasteboard(name: NSPasteboard.Name("paper-drag-tests-\(UUID().uuidString)"))
            board.writeObjects([PaperLibraryDragPayload(node: node, directory: directory ?? library.directory).pasteboardItem()])
            pasteboards.append(board)
            return board
        }
        func drag(_ node: PaperLibraryDragNode, onto view: NSView, at point: CGPoint = CGPoint(x: 100, y: 14)) -> PaperTestDraggingInfo {
            PaperTestDraggingInfo(pasteboard: pasteboard(node), point: view.convert(point, to: nil))
        }

        let hostedWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 48),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        hostedWindow.isReleasedWhenClosed = false
        defer { hostedWindow.close() }
        let hostedRows = NSHostingView(rootView: VStack(spacing: 0) {
            PaperLibraryDragRow(library: library, target: .item(paper.id), node: .item(paper.id), isEnabled: true,
                                onClick: { _ in }, onDragState: { _ in }, onFeedback: { _ in }, onMove: { _ in }) {
                Button("纸张行") {}.frame(maxWidth: .infinity, minHeight: 28)
            }.frame(height: 28)
            PaperLibraryDragRow(library: library, target: .root, isEnabled: true,
                                onDragState: { _ in }, onFeedback: { _ in }, onMove: { _ in }) {
                Button("素材库根目录") {}.frame(maxWidth: .infinity, minHeight: 20)
            }.frame(height: 20)
        }.frame(width: 300, height: 48))
        hostedWindow.contentView = hostedRows
        settleLayout(hostedRows)
        func nativeRows(in view: NSView) -> [PaperLibraryDragView] {
            if let row = view as? PaperLibraryDragView { return [row] }
            return view.subviews.flatMap { nativeRows(in: $0) }
        }
        let nativeHostedRows = nativeRows(in: hostedRows)
        try check(nativeHostedRows.count == 2,
                  "The actual SwiftUI row representable installs native paper and root destinations")
        let hostedSource = nativeHostedRows.first { $0.node == .item(paper.id) }!
        let hostedRoot = nativeHostedRows.first { $0.node == nil }!
        try check(hostedSource.bounds.size == CGSize(width: 300, height: 28)
                  && hostedSource.hostedView?.frame.size == hostedSource.bounds.size,
                  "A hosted paper row and its content occupy the real full-width 28-point row")
        try check(hostedSource.hitTest(hostedSource.convert(CGPoint(x: 150, y: 14), to: hostedSource.superview)) === hostedSource,
                  "Hits on a real SwiftUI button label reach its native drag source")
        try check(nativeHostedRows.allSatisfy { $0.registeredDraggedTypes.contains(PaperLibraryDragPayload.type) },
                  "Both the hosted paper row and source-less root breadcrumb register the native drop type")
        let hostedRootDrop = drag(.folder(child), onto: hostedRoot, at: CGPoint(x: 150, y: 10))
        try check(hostedRoot.draggingEntered(hostedRootDrop) == .move && hostedRoot.prepareForDragOperation(hostedRootDrop),
                  "The actual hosted root breadcrumb accepts the payload from a folder at another level")
        hostedRoot.draggingExited(hostedRootDrop)

        let source = row(.item(paper.id), node: .item(paper.id))
        let hostedButton = NSHostingView(rootView: Button("子级纸张") {})
        source.hostedView = hostedButton
        source.addSubview(hostedButton)
        source.layoutSubtreeIfNeeded()
        try check(source.hitTest(source.convert(CGPoint(x: 100, y: 14), to: content)) === source,
                  "A native paper source owns mouse hits even when the row contains a SwiftUI button")
        var clicks = 0
        var states: [Bool] = []
        var feedback: PaperLibraryDropFeedback?
        source.onClick = { _ in clicks += 1 }
        source.onDragState = { states.append($0) }
        source.onFeedback = { feedback = $0 }
        source.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 14), in: source))
        source.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 33, y: 14), in: source))
        source.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 33, y: 14), in: source))
        try check(clicks == 1 && source.startedItems.isEmpty && states.isEmpty,
                  "A click with sub-threshold motion uses the paper without starting a drag")
        source.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 14), in: source))
        source.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 34, y: 14), in: source))
        source.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 100, y: 14), in: source))
        try check(source.isDragging && source.startedItems.count == 1 && states == [true],
                  "Four points of movement starts exactly one native paper drag")
        let sourceBoard = NSPasteboard(name: NSPasteboard.Name("paper-drag-source-\(UUID().uuidString)"))
        pasteboards.append(sourceBoard)
        sourceBoard.writeObjects([source.startedItems[0]])
        try check(PaperLibraryDragPayload.read(from: sourceBoard, library: library) == .item(paper.id)
                  && sourceBoard.availableType(from: [.fileURL, .string]) == nil,
                  "The real source encodes its library identity and paper identity in a dedicated payload")
        feedback = .root
        source.finishDrag()
        source.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 100, y: 14), in: source))
        source.finishDrag()
        try check(!source.isDragging && states == [true, false] && clicks == 1 && feedback == nil,
                  "Finishing or cancelling a drag clears feedback and never fires single-click use")
        source.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 14), in: source))
        source.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 35, y: 14), in: source))
        source.isEnabled = false
        source.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 35, y: 14), in: source))
        try check(!source.isDragging && clicks == 1 && states == [true, false, true, false],
                  "Disabling a row cancels its pending native drag without applying its paper")
        source.isEnabled = true

        let secondRow = row(.folder(second))
        var movedParents: [UUID?] = []
        secondRow.onFeedback = { feedback = $0 }
        secondRow.onMove = { movedParents.append($0) }
        for y: CGFloat in [1, 14, 27] {
            let incoming = drag(.item(paper.id), onto: secondRow, at: CGPoint(x: 100, y: y))
            try check(secondRow.draggingEntered(incoming) == .move && feedback == .insideFolder(second),
                      "Every part of a folder row accepts a paper as folder content")
            secondRow.draggingExited(incoming)
            try check(feedback == nil, "Exiting a folder clears its drag feedback")
        }
        let paperIntoFolder = drag(.item(paper.id), onto: secondRow)
        try check(secondRow.prepareForDragOperation(paperIntoFolder) && secondRow.performDragOperation(paperIntoFolder)
                  && library.items.first(where: { $0.id == paper.id })?.parentID == second
                  && movedParents == [second] && feedback == nil,
                  "The native folder destination moves a paper and clears feedback after committing")

        let firstRow = row(.folder(first))
        firstRow.onFeedback = { feedback = $0 }
        firstRow.onMove = { movedParents.append($0) }
        let promoteFolder = drag(.folder(child), onto: firstRow, at: CGPoint(x: 100, y: 2))
        try check(firstRow.draggingEntered(promoteFolder) == .move && feedback == .beforeFolder(first)
                  && firstRow.performDragOperation(promoteFolder)
                  && library.folders.first(where: { $0.id == child })?.parentID == nil
                  && library.folders.filter { $0.parentID == nil }.map(\.id) == [child, first, second]
                  && movedParents.last! == nil,
                  "Dropping a nested folder before a root folder promotes it despite the valid nil parent")
        let folderIntoFolder = drag(.folder(child), onto: secondRow)
        try check(secondRow.draggingUpdated(folderIntoFolder) == .move
                  && secondRow.performDragOperation(folderIntoFolder)
                  && library.folders.first(where: { $0.id == child })?.parentID == second
                  && library.folders.first(where: { $0.id == grandchild })?.parentID == child,
                  "A folder drops into another folder while retaining its descendants")
        let childRow = row(.folder(child))
        let cycle = drag(.folder(second), onto: childRow)
        try check(childRow.draggingEntered(cycle).isEmpty && !childRow.prepareForDragOperation(cycle)
                  && !childRow.performDragOperation(cycle)
                  && library.folders.first(where: { $0.id == second })?.parentID == nil,
                  "The native destination rejects dropping a folder inside its own descendant")
        let cycleEdge = drag(.folder(second), onto: childRow, at: CGPoint(x: 100, y: 2))
        try check(childRow.draggingUpdated(cycleEdge).isEmpty && !childRow.performDragOperation(cycleEdge),
                  "Sibling insertion into the dragged folder itself cannot create a hierarchy cycle")
        let selfDrop = drag(.folder(second), onto: secondRow)
        try check(secondRow.draggingUpdated(selfDrop).isEmpty && !secondRow.performDragOperation(selfDrop),
                  "A folder never accepts itself as a drag destination")

        let rootItemRow = row(.item(rootPaper.id))
        rootItemRow.onFeedback = { feedback = $0 }
        let promotePaper = drag(.item(paper.id), onto: rootItemRow, at: CGPoint(x: 100, y: 3))
        try check(rootItemRow.draggingEntered(promotePaper) == .move && feedback == .beforeItem(rootPaper.id)
                  && rootItemRow.performDragOperation(promotePaper)
                  && library.items.first(where: { $0.id == paper.id })?.parentID == nil
                  && library.items.filter { $0.parentID == nil }.map(\.id) == [paper.id, rootPaper.id, lastPaper.id],
                  "Dropping a nested paper before a root paper promotes it despite the valid nil parent")
        let afterPaper = drag(.item(paper.id), onto: rootItemRow, at: CGPoint(x: 100, y: 24))
        try check(rootItemRow.draggingUpdated(afterPaper) == .move && feedback == .afterItem(rootPaper.id)
                  && rootItemRow.performDragOperation(afterPaper)
                  && library.items.filter { $0.parentID == nil }.map(\.id) == [rootPaper.id, paper.id, lastPaper.id],
                  "The lower half of a paper row commits insertion after that paper")
        let noOpIndex = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let repeatedDrop = rootItemRow.performDragOperation(afterPaper)
        let indexAfterRepeatedDrop = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        try check(repeatedDrop && indexAfterRepeatedDrop == noOpIndex,
                  "An already adjacent drop succeeds without altering saved ordering")

        let rootRow = row(.root)
        let returnRoot = drag(.folder(child), onto: rootRow)
        try check(rootRow.draggingEntered(returnRoot) == .move && rootRow.performDragOperation(returnRoot)
                  && library.folders.first(where: { $0.id == child })?.parentID == nil,
                  "The native root breadcrumb receives a folder from another hierarchy level")
        let afterFolder = drag(.folder(child), onto: firstRow, at: CGPoint(x: 100, y: 25))
        try check(firstRow.draggingUpdated(afterFolder) == .move && feedback == .afterFolder(first)
                  && firstRow.performDragOperation(afterFolder)
                  && library.folders.filter { $0.parentID == nil }.map(\.id) == [first, child, second],
                  "The bottom edge of a root folder commits sibling insertion after its subtree")
        let folderNoOpIndex = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let repeatedFolderDrop = firstRow.performDragOperation(afterFolder)
        let folderIndexAfterRepeatedDrop = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        try check(repeatedFolderDrop && folderIndexAfterRepeatedDrop == folderNoOpIndex,
                  "An adjacent folder insertion succeeds without disturbing sibling order")
        let crumb = row(.breadcrumbFolder(first))
        let toBreadcrumb = drag(.item(paper.id), onto: crumb)
        try check(crumb.performDragOperation(toBreadcrumb)
                  && library.items.first(where: { $0.id == paper.id })?.parentID == first,
                  "An ancestor breadcrumb accepts a paper using the final pasteboard payload")

        let outside = drag(.item(paper.id), onto: secondRow)
        try check(secondRow.draggingEntered(outside) == .move, "A valid hover proposes a folder move")
        outside.draggingLocation = secondRow.convert(CGPoint(x: 100, y: 40), to: nil)
        try check(!secondRow.prepareForDragOperation(outside) && !secondRow.performDragOperation(outside)
                  && library.items.first(where: { $0.id == paper.id })?.parentID == first && feedback == nil,
                  "The final drop point is checked again and a stale hover cannot move a paper")
        let hoverThenExit = drag(.item(paper.id), onto: secondRow)
        _ = secondRow.draggingEntered(hoverThenExit)
        secondRow.draggingExited(hoverThenExit)
        try check(secondRow.performDragOperation(hoverThenExit)
                  && library.items.first(where: { $0.id == paper.id })?.parentID == second,
                  "Exit callback ordering cannot erase a valid final drop")

        let foreign = PaperTestDraggingInfo(pasteboard: pasteboard(.item(paper.id), directory: directory.appendingPathComponent("other")),
                                           point: secondRow.convert(CGPoint(x: 100, y: 14), to: nil))
        try check(secondRow.draggingEntered(foreign).isEmpty && !secondRow.performDragOperation(foreign),
                  "A payload from another library cannot move a matching local identity")
        let malformedBoard = NSPasteboard(name: NSPasteboard.Name("paper-drag-invalid-\(UUID().uuidString)"))
        pasteboards.append(malformedBoard)
        malformedBoard.setData(Data("not-json".utf8), forType: PaperLibraryDragPayload.type)
        let malformed = PaperTestDraggingInfo(pasteboard: malformedBoard,
                                             point: secondRow.convert(CGPoint(x: 100, y: 14), to: nil))
        try check(secondRow.draggingUpdated(malformed).isEmpty && !secondRow.performDragOperation(malformed),
                  "Malformed pasteboard payloads are rejected before changing the library")
        let unknown = drag(.item(UUID()), onto: secondRow)
        try check(secondRow.draggingEntered(unknown).isEmpty && !secondRow.performDragOperation(unknown),
                  "A removed or unknown source identity cannot be moved")
        secondRow.isEnabled = false
        let inactive = drag(.item(paper.id), onto: secondRow)
        try check(secondRow.draggingEntered(inactive).isEmpty && !secondRow.performDragOperation(inactive),
                  "Inactive and modal library destinations reject native drag events")
        secondRow.isEnabled = true

        let vanished = library.createFolder(named: "即将删除", parentID: nil)!
        let vanishedRow = row(.folder(vanished))
        let staleTarget = drag(.item(paper.id), onto: vanishedRow)
        try check(vanishedRow.draggingEntered(staleTarget) == .move, "An existing folder initially accepts hover")
        library.removeFolder(id: vanished)
        try check(!vanishedRow.performDragOperation(staleTarget)
                  && library.items.first(where: { $0.id == paper.id })?.parentID == second,
                  "A target removed after hover is revalidated at commit time")

        library.importURLs([directory.appendingPathComponent("missing-source.png")])
        try check(library.isBusy, "The fixture enters the real import busy gate before background processing")
        let busyDrop = drag(.item(paper.id), onto: firstRow)
        let startedBeforeBusy = source.startedItems.count
        source.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 14), in: source))
        source.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 50, y: 14), in: source))
        try check(firstRow.draggingEntered(busyDrop).isEmpty && !firstRow.performDragOperation(busyDrop)
                  && source.startedItems.count == startedBeforeBusy,
                  "Busy libraries reject both new native drags and pending destination commits")
        source.finishDrag()
        let deadline = Date().addingTimeInterval(10)
        while library.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(!library.isBusy, "The isolated import completes before its temporary directory is removed")

        let reopened = PaperLibraryStore(directory: directory)
        try check(reopened.folders == library.folders && reopened.items == library.items,
                  "Native drag commits persist both parent assignments and sibling order")
        source.disconnect()
        secondRow.disconnect()
        try check(source.destination == nil && secondRow.destination == nil && !source.isEnabled && !secondRow.isEnabled,
                  "Disconnecting native rows drops their destination and disables future event handling")
        return checks
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private static func settleLayout(_ view: NSView) {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

@MainActor private final class RecordingPaperDragView: PaperLibraryDragView {
    var startedItems: [NSPasteboardItem] = []
    override func beginPaperDragging(with event: NSEvent, item: NSPasteboardItem) { startedItems.append(item) }
}

@MainActor private final class PaperDragTestContent: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class PaperTestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    var draggingSource: Any? { nil }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard, point: CGPoint) { draggingPasteboard = pasteboard; draggingLocation = point }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
