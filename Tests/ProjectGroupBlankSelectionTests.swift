import AppKit
import SwiftUI

/// Real hit testing and SwiftUI attachment in undisplayed windows. No event
/// monitors, screenshots, or changes to the user's library are involved.
@MainActor enum ProjectGroupBlankSelectionTests {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectGroupBlankSelectionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 500))
        window.contentView = root
        let scroll = NSScrollView(frame: CGRect(x: 20, y: 20, width: 520, height: 440))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        let document = FlippedBlankSelectionView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
        scroll.documentView = document
        root.addSubview(scroll)

        let photoScroll = NSScrollView(frame: .zero)
        let board = ProjectMaterialDocumentView(frame: CGRect(x: 0, y: 0, width: 440, height: 80))
        photoScroll.documentView = board
        let row = ProjectPhotoGroupContainerView(scrollView: photoScroll)
        row.frame = CGRect(x: 0, y: 20, width: 480, height: 80)
        document.addSubview(row)
        row.layoutSubtreeIfNeeded()
        let secondRow = ProjectPhotoGroupContainerView(scrollView: NSScrollView(frame: .zero))
        secondRow.frame = CGRect(x: 0, y: 140, width: 480, height: 80)
        document.addSubview(secondRow)
        secondRow.layoutSubtreeIfNeeded()
        let button = NSButton(frame: CGRect(x: 12, y: 250, width: 130, height: 28))
        button.title = "保留选择的操作"
        document.addSubview(button)
        let controlChild = NSView(frame: CGRect(x: 4, y: 4, width: 20, height: 16))
        button.addSubview(controlChild)
        let text = NSTextView(frame: CGRect(x: 200, y: 250, width: 100, height: 30))
        document.addSubview(text)
        let outside = NSView(frame: CGRect(x: 560, y: 40, width: 60, height: 80))
        root.addSubview(outside)
        scroll.tile()
        scroll.contentView.scroll(to: .zero)
        root.layoutSubtreeIfNeeded()

        let controller = ProjectGroupBlankSelectionController()
        var clears = 0
        controller.onClearSelection = { clears += 1 }
        controller.attach(to: scroll)
        let recognizer = controller.clickRecognizer
        func attempt(_ view: NSView, _ point: CGPoint,
                     flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .leftMouseDown) -> Bool {
            let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                                          modifierFlags: flags, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: 1, pressure: 1)!
            return controller.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: event)
        }
        try check(recognizer.view === scroll && !recognizer.delaysPrimaryMouseButtonEvents,
                  "The viewport recognizer is installed without delaying native mouse-down events")
        for point in [CGPoint(x: 200, y: 8), CGPoint(x: 200, y: 120), CGPoint(x: 200, y: 350)] {
            try check(attempt(document, point), "Empty padding, inter-row gaps and space below rows accept deselection")
        }
        try check(!attempt(board, CGPoint(x: 40, y: 30)),
                  "Native photo boards keep single selection, multi-selection and photo dragging")
        try check(!attempt(row.handleView, CGPoint(x: 12, y: 30)),
                  "The group handle keeps its whole-group click and reorder drag")
        try check(!attempt(secondRow, CGPoint(x: 300, y: 40)),
                  "A group row's own blank space is left to its existing native handler")
        try check(!attempt(button, CGPoint(x: 80, y: 12)) &&
                  !attempt(controlChild, CGPoint(x: 8, y: 8)),
                  "Controls and their internal children preserve selected photos for actions")
        try check(!attempt(text, CGPoint(x: 20, y: 12)), "Text editors do not clear the photo selection")
        if let scroller = scroll.verticalScroller {
            try check(!attempt(scroller, CGPoint(x: scroller.bounds.midX, y: scroller.bounds.midY)),
                      "The native scrollbar remains independent of selection")
        }
        try check(!attempt(outside, CGPoint(x: 10, y: 10)),
                  "The recognizer cannot clear selection from outside its group viewport")
        try check(!attempt(document, CGPoint(x: 200, y: 350), flags: .control) &&
                  !attempt(document, CGPoint(x: 200, y: 350), type: .rightMouseDown),
                  "Context-menu clicks preserve selection")
        controller.isActive = false
        try check(!recognizer.isEnabled && !attempt(document, CGPoint(x: 200, y: 350)),
                  "Modal or inactive workspaces disable blank deselection")
        controller.isActive = true
        try check(recognizer.isEnabled && attempt(document, CGPoint(x: 200, y: 350)),
                  "Reactivating the workspace restores blank selection behavior")
        controller.attach(to: scroll)
        try check(scroll.gestureRecognizers.filter { $0 === recognizer }.count == 1,
                  "Repeated view updates never install duplicate recognizers")
        let other = NSClickGestureRecognizer(target: nil, action: nil)
        try check(controller.gestureRecognizer(recognizer, shouldRecognizeSimultaneouslyWith: other),
                  "Blank clicks do not monopolize other viewport gestures")
        try check(clears == 0, "Hit testing alone never clears selection before a click completes")
        controller.detach()
        try check(recognizer.view == nil && controller.scrollView == nil &&
                  !attempt(document, CGPoint(x: 200, y: 350)),
                  "Detaching removes the recognizer and rejects stale events")

        // SwiftUI's background reader must attach to the enclosing viewport,
        // rather than intercepting hits inside the lazy content's own bounds.
        let host = NSHostingView(rootView: BlankSelectionFixture(isActive: true))
        host.frame = root.bounds
        window.contentView = host
        func settle() async throws {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                // Reader attachment is dispatched to the main queue. Yield the
                // actor instead of nesting RunLoop.run inside an async test job.
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        guard let reader = descendants(of: host, matching: ProjectGroupBlankSelectionReaderView.self).first,
              let enclosing = reader.enclosingScrollView else {
            throw NSError(domain: "ProjectGroupBlankSelectionTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "SwiftUI group reader did not reach its viewport"])
        }
        try check(reader.selectionController.clickRecognizer.view === enclosing &&
                  reader.hitTest(.zero) == nil,
                  "The SwiftUI modifier observes the enclosing viewport without owning a hit region: window=\(String(describing: reader.window)), enclosing=\(enclosing), installed=\(String(describing: reader.selectionController.clickRecognizer.view))")
        host.rootView = BlankSelectionFixture(isActive: false)
        try await settle()
        try check(!reader.selectionController.clickRecognizer.isEnabled,
                  "SwiftUI modal state disables the installed recognizer")
        reader.disconnect()
        try await settle()
        try check(reader.selectionController.clickRecognizer.view == nil &&
                  reader.selectionController.onClearSelection == nil,
                  "Dismantling the reader removes its recognizer, callback and pending attachment")
        try check(!window.isVisible, "All selection routing tests keep their window off screen")
        return checks
    }

    private static func descendants<T: NSView>(of root: NSView, matching type: T.Type) -> [T] {
        root.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: child, matching: type)
        }
    }
}

private final class FlippedBlankSelectionView: NSView {
    override var isFlipped: Bool { true }
}

private struct BlankSelectionFixture: View {
    let isActive: Bool
    var body: some View {
        ScrollView {
            LazyVStack {
                Color.clear.frame(height: 80)
                Color.clear.frame(height: 80)
            }
            .projectGroupBlankSelection(isActive: isActive, onClearSelection: {})
        }
    }
}
