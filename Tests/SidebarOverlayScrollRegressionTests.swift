import AppKit
import SwiftUI

/// Real nested sidebar lists in an undisplayed window, using isolated paper data.
@MainActor enum SidebarOverlayScrollRegressionTests {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "SidebarOverlayScrollRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-scroll-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PaperLibraryStore(directory: directory)
        for index in 0..<12 { library.createFolder(named: "纸张 \(index)", parentID: nil) }
        let store = CanvasStore()
        store.mutate { document in
            document.layers = (0..<20).map { index in
                CanvasLayer(name: "照片 \(index)", kind: .photo, center: .zero,
                            size: CGSize(width: 100, height: 100))
            }
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 304, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SidebarScrollFixture(store: store, library: library))
        window.contentView = host
        await settle(host)

        let scrolls = descendants(of: host, matching: NSScrollView.self)
        try check(scrolls.count == 3, "The outer sidebar, paper library and canvas layers each have a scroll view (found \(scrolls.count))")
        let reference = ProjectOverlayScrollView(frame: .zero)
        func verify(_ label: String) throws {
            for scroll in scrolls {
                try check(scroll.scrollerStyle == .overlay && scroll.autohidesScrollers,
                          "\(label): sidebar scrollbars use overlay geometry and auto-hide")
                try check(type(of: scroll.verticalScroller!) == type(of: reference.verticalScroller!) &&
                          scroll.verticalScroller?.controlSize == .small,
                          "\(label): sidebar thumbs use the same thin native scroller as project materials")
                try check(abs(scroll.contentView.bounds.width - scroll.bounds.width) < 0.5,
                          "\(label): the scrollbar reserves no width from its content")
            }
        }
        try verify("Overflowing sidebar")

        let widths = scrolls.map { $0.contentView.bounds.width }
        for scroll in scrolls { scroll.flashScrollers() }
        await settle(host)
        try check(zip(scrolls, widths).allSatisfy { abs($0.contentView.bounds.width - $1) < 0.5 },
                  "Showing the thumbs never changes any sidebar content width")

        for scroll in scrolls { scroll.scrollerStyle = .legacy }
        await settle(host)
        try verify("After AppKit requests legacy scrollbars")

        window.setContentSize(CGSize(width: 304, height: 1000))
        await settle(host)
        try verify("Sidebar fits vertically")
        try check(zip(scrolls, widths).allSatisfy { abs($0.contentView.bounds.width - $1) < 0.5 },
                  "Crossing the vertical overflow threshold leaves all content widths unchanged")

        window.setContentSize(CGSize(width: 304, height: 360))
        store.mutate { $0.layers = Array($0.layers.prefix(1)) }
        await settle(host)
        try verify("Short layer list")
        try check(zip(scrolls, widths).allSatisfy { abs($0.contentView.bounds.width - $1) < 0.5 },
                  "Removing overflowing layers does not resize the layer or paper columns")

        guard let layerScroll = scrolls.first(where: { $0.documentView is CanvasLayersTableView }),
              let table = layerScroll.documentView as? CanvasLayersTableView else {
            throw NSError(domain: "SidebarOverlayScrollRegressionTests", code: 2)
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try check(store.selectedID == store.document.layers.first?.id,
                  "The overlay scrollbar preserves native layer selection")
        for scroll in scrolls where scroll.documentView!.bounds.height > scroll.contentView.bounds.height {
            scroll.documentView!.scroll(CGPoint(x: 0, y: 50))
            try check(scroll.contentView.bounds.minY > 0, "Overflowing sidebar content remains scrollable")
        }
        try check(!window.isVisible, "All sidebar checks leave the window undisplayed")
        return checks
    }

    private static func settle(_ host: NSView) async {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
    }

    private static func descendants<T: NSView>(of root: NSView, matching type: T.Type) -> [T] {
        root.subviews.flatMap { child in
            ((child as? T).map { [$0] } ?? []) + descendants(of: child, matching: type)
        }
    }
}

@MainActor private struct SidebarScrollFixture: View {
    @ObservedObject var store: CanvasStore
    @ObservedObject var library: PaperLibraryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("画布").font(.headline)
                PaperLibrarySidebar(library: library, isActive: true, isApplying: false,
                                    onUse: { _ in }, onAddLayer: { _ in }, onImageReplaced: { _, _, _ in })
                Text("画布图层").font(.headline)
                CanvasLayersList(store: store, onCrop: { _ in }, onReplace: { _ in })
                    .frame(height: 132)
            }
            .padding(16)
            .projectOverlayScrollbars()
        }
    }
}
