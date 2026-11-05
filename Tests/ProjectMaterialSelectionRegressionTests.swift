import AppKit
import QuickLookUI

@MainActor enum ProjectMaterialSelectionRegressionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectMaterialSelectionRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        let first = ProjectAsset(id: UUID(), fileName: "first.png", name: "first.png", position: .zero)
        let second = ProjectAsset(id: UUID(), fileName: "second.png", name: "second.png",
                                  position: CGPoint(x: ProjectMaterialLayout(thumbnailSize: 128).groupColumnStride, y: 0))
        let assets = [first, second]
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 176))
        let board = ProjectMaterialDocumentView(frame: .zero)
        scroll.documentView = board
        board.isGroupRow = true
        var selection = Set(assets.map(\.id))
        var clears = 0
        var moves = 0
        board.onSelectionChange = { selection = $0 }
        board.onGroupClearSelection = { clears += 1 }
        board.onMove = { _ in moves += 1 }
        board.onReorder = { _ in moves += 1 }
        func configure(_ ids: Set<UUID>) {
            selection = ids
            board.configure(assets: assets, selection: ids, thumbnailSize: 128, viewZoom: 1,
                            fitRequest: 0, thumbnails: [:], assetURLs: [:], badges: [:],
                            operations: [], isActive: true)
        }
        func click(_ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            let location = board.convert(point, to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                         modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                                       modifierFlags: modifiers, timestamp: 0.1, windowNumber: 0,
                                       context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            board.mouseDown(with: down)
            board.mouseUp(with: up)
            // Acknowledge the published binding as SwiftUI does before the next
            // click; otherwise the fixture leaves an old selection in flight.
            configure(selection)
        }

        configure(Set(assets.map(\.id)))
        click(CGPoint(x: 24, y: 24))
        try check(selection == [first.id] && clears == 0,
                  "Clicking a thumbnail after whole-group selection selects just that photo")
        configure(selection)
        click(CGPoint(x: 172, y: 24))
        try check(selection == [second.id], "Clicking another thumbnail replaces the selection")
        configure(selection)
        click(CGPoint(x: 24, y: 24), modifiers: .command)
        try check(selection == Set(assets.map(\.id)), "Explicit command-click still supports multiple photos")

        for point in [CGPoint(x: 138, y: 24), CGPoint(x: 420, y: 24), CGPoint(x: 24, y: 155)] {
            configure(Set(assets.map(\.id)))
            let previousClears = clears
            click(point)
            try check(selection.isEmpty && clears == previousClears + 1,
                      "Background click at \(point) clears selection (remaining: \(selection.count), clear callbacks: \(clears - previousClears))")
        }
        configure([])
        let previousClears = clears
        click(CGPoint(x: 420, y: 24))
        try check(selection.isEmpty && clears == previousClears + 1,
                  "Clicking an already-empty row background still clears the workspace selection")
        try check(moves == 0, "Selection clicks never reorder photos or change their positions")
        try check(!board.registeredDraggedTypes.contains(ProjectPhotoGroupDragPayload.type),
                  "The photo board leaves group drops to its native parent container")

        // The same padding is blank in the material grid, rather than an
        // invisible extension of the image's click target.
        func setGroupRowMode(_ groupRow: Bool) {
            board.isGroupRow = groupRow
            board.configure(assets: [], selection: [], thumbnailSize: 128, viewZoom: 1,
                            fitRequest: 0, thumbnails: [:], assetURLs: [:], badges: [:],
                            operations: [], isActive: true)
        }
        setGroupRowMode(false)
        configure(Set(assets.map(\.id)))
        click(CGPoint(x: 13, y: 13))
        try check(selection.isEmpty, "Clicking material-card padding clears selection")

        for groupRow in [false, true] {
            setGroupRowMode(groupRow)
            let margin: CGFloat = groupRow ? 4 : 12
            configure([])
            click(CGPoint(x: margin + 3.5, y: margin + 3.5))
            try check(selection == [first.id],
                      "\(groupRow): newly exposed photo edges remain clickable after reducing card padding")
            configure(Set(assets.map(\.id)))
            click(CGPoint(x: margin + 1, y: margin + 64))
            try check(selection.isEmpty,
                      "\(groupRow): the remaining narrow padding still clears selection")
            for size in [CGSize(width: 64, height: 128), CGSize(width: 128, height: 64)] {
                let image = NSImage(size: size)
                board.configure(assets: assets, selection: Set(assets.map(\.id)), thumbnailSize: 128,
                                viewZoom: 1, fitRequest: 0, thumbnails: [first.id: image], assetURLs: [:],
                                badges: [:], operations: [], isActive: true)
                let blank = size.width < size.height
                    ? CGPoint(x: margin + 12, y: margin + 64)
                    : CGPoint(x: margin + 64, y: margin + 12)
                click(blank)
                try check(selection.isEmpty,
                          "\(groupRow): aspect-fit letterbox space around a \(size) photo clears selection")
                board.configure(assets: assets, selection: [], thumbnailSize: 128, viewZoom: 1,
                                fitRequest: 0, thumbnails: [first.id: image], assetURLs: [:], badges: [:],
                                operations: [], isActive: true)
                click(CGPoint(x: margin + 64, y: margin + 64))
                try check(selection == [first.id],
                          "\(groupRow): the actual displayed \(size) photo remains clickable")
            }
        }

        // Alternate portrait and landscape photos so a marquee can cross four
        // cards while touching only their surrounding white space.
        let marqueeAssets = (0..<4).map {
            ProjectAsset(id: UUID(), fileName: "marquee-\($0).png", name: "marquee-\($0).png", position: .zero)
        }
        let marqueeImages = Dictionary(uniqueKeysWithValues: marqueeAssets.enumerated().map { index, asset in
            let portrait = index == 0 || index == 3
            return (asset.id, NSImage(size: portrait ? CGSize(width: 64, height: 128) : CGSize(width: 128, height: 64)))
        })
        let marqueeScroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 340))
        let marqueeBoard = ProjectMaterialDocumentView(frame: .zero)
        marqueeScroll.documentView = marqueeBoard
        var marqueeSelection = Set<UUID>()
        marqueeBoard.onSelectionChange = { marqueeSelection = $0 }
        func marquee(from start: CGPoint, through points: [CGPoint], initial: Set<UUID> = [],
                     modifiers: NSEvent.ModifierFlags = [], zoom: Double = 1) {
            marqueeSelection = initial
            marqueeBoard.configure(assets: marqueeAssets, selection: initial, thumbnailSize: 128,
                                   viewZoom: zoom, fitRequest: 0, thumbnails: marqueeImages, assetURLs: [:],
                                   badges: [:], operations: [], isActive: true)
            func send(_ type: NSEvent.EventType, at point: CGPoint) {
                let event = NSEvent.mouseEvent(with: type, location: marqueeBoard.convert(point, to: nil),
                                              modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                switch type {
                case .leftMouseDown: marqueeBoard.mouseDown(with: event)
                case .leftMouseDragged: marqueeBoard.mouseDragged(with: event)
                default: marqueeBoard.mouseUp(with: event)
                }
            }
            send(.leftMouseDown, at: start)
            for point in points { send(.leftMouseDragged, at: point) }
            send(.leftMouseUp, at: points.last ?? start)
            // Acknowledge the finished gesture before injecting a new external
            // selection, just as the SwiftUI binding does between gestures.
            marqueeBoard.configure(assets: marqueeAssets, selection: marqueeSelection, thumbnailSize: 128,
                                   viewZoom: zoom, fitRequest: 0, thumbnails: marqueeImages, assetURLs: [:],
                                   badges: [:], operations: [], isActive: true)
        }
        let marqueeLayout = ProjectMaterialGridLayout(count: 4, viewportWidth: marqueeScroll.contentView.bounds.width,
                                                     thumbnailSize: 128)
        let topLeft = marqueeLayout.frame(at: 0), topRight = marqueeLayout.frame(at: 1)
        let bottomRight = marqueeLayout.frame(at: 3)
        marquee(from: CGPoint(x: topRight.minX + 0.5, y: topRight.minY + 60),
                through: [CGPoint(x: topRight.minX + 2.5, y: topRight.minY + 100)])
        try check(marqueeSelection.isEmpty, "A marquee confined to card padding never selects the photo")
        marquee(from: CGPoint(x: topLeft.minX + 10, y: topLeft.minY + 10),
                through: [CGPoint(x: topLeft.minX + 30, y: topLeft.minY + 100)])
        try check(marqueeSelection.isEmpty, "A marquee in portrait side letterboxing never selects the photo")
        marquee(from: CGPoint(x: topRight.minX + 10, y: topRight.minY + 10),
                through: [CGPoint(x: topRight.minX + 100, y: topRight.minY + 30)])
        try check(marqueeSelection.isEmpty, "A marquee in landscape top letterboxing never selects the photo")
        marquee(from: CGPoint(x: topLeft.minX + 10, y: topLeft.minY + 10),
                through: [CGPoint(x: topLeft.minX + 35, y: topLeft.minY + 50)])
        try check(marqueeSelection.isEmpty, "A marquee merely touching a displayed photo edge never selects it")
        for (start, end) in [
            (CGPoint(x: topLeft.minX + 64, y: topLeft.minY + 1), CGPoint(x: topLeft.minX + 64, y: topLeft.minY + 80)),
            (CGPoint(x: topLeft.minX + 10, y: topLeft.minY + 64), CGPoint(x: topLeft.minX + 80, y: topLeft.minY + 64))
        ] {
            marquee(from: start, through: [end])
            try check(marqueeSelection.isEmpty, "A zero-width or zero-height marquee crossing a photo never selects it")
        }
        marquee(from: CGPoint(x: topLeft.minX + 10, y: topLeft.minY + 10),
                through: [CGPoint(x: topLeft.minX + 50, y: topLeft.minY + 50)])
        try check(marqueeSelection == [marqueeAssets[0].id],
                  "A marquee beginning in letterboxing selects the photo once it crosses its displayed pixels")

        let centralStart = CGPoint(x: topLeft.minX + 101, y: topLeft.minY + 101)
        let centralBlankEnd = CGPoint(x: bottomRight.minX + 33, y: bottomRight.minY + 33)
        let lowerPhotoEnd = CGPoint(x: bottomRight.minX + 68, y: bottomRight.minY + 68)
        marquee(from: centralStart, through: [centralBlankEnd])
        try check(marqueeSelection.isEmpty,
                  "A marquee touching four cards but no displayed photos selects none of them")
        marquee(from: centralStart, through: [lowerPhotoEnd])
        try check(marqueeSelection == Set([marqueeAssets[2].id, marqueeAssets[3].id]),
                  "A marquee spanning multiple rows selects only photos whose displayed areas overlap it")
        for modifier: NSEvent.ModifierFlags in [.command, .shift] {
            marquee(from: centralStart, through: [lowerPhotoEnd],
                    initial: [marqueeAssets[0].id], modifiers: modifier)
            try check(marqueeSelection == Set([marqueeAssets[0].id, marqueeAssets[2].id, marqueeAssets[3].id]),
                      "\(modifier): an additive marquee preserves the original selection alongside its actual photo hits")
            marquee(from: centralStart, through: [lowerPhotoEnd, centralBlankEnd],
                    initial: [marqueeAssets[0].id], modifiers: modifier)
            try check(marqueeSelection == [marqueeAssets[0].id],
                      "\(modifier): shrinking an additive marquee drops its temporary hits and preserves the original selection")
        }
        for zoom in [0.5, 1.5] {
            let scale = CGFloat(zoom)
            let origin = ProjectMaterialGridLayout(count: 4, viewportWidth: marqueeScroll.contentView.bounds.width,
                                                  thumbnailSize: 128, zoom: scale).frame(at: 0).origin
            marquee(from: CGPoint(x: origin.x + 10 * scale, y: origin.y + 10 * scale),
                    through: [CGPoint(x: origin.x + 30 * scale, y: origin.y + 100 * scale)], zoom: zoom)
            try check(marqueeSelection.isEmpty, "\(zoom): zoomed portrait letterboxing remains blank for marquee selection")
            marquee(from: CGPoint(x: origin.x + 10 * scale, y: origin.y + 10 * scale),
                    through: [CGPoint(x: origin.x + 50 * scale, y: origin.y + 50 * scale)], zoom: zoom)
            try check(marqueeSelection == [marqueeAssets[0].id],
                      "\(zoom): zoomed displayed photo pixels remain selectable by marquee")
        }

        let third = ProjectAsset(id: UUID(), fileName: "third.png", name: "third.png", position: .zero)
        let previewAssets = assets + [third]
        setGroupRowMode(false)
        let urls = Dictionary(uniqueKeysWithValues: previewAssets.map {
            ($0.id, URL(fileURLWithPath: "/preview-fixture/" + $0.fileName))
        })
        func configurePreview(_ ids: Set<UUID>) {
            selection = ids
            board.configure(assets: previewAssets, selection: ids, thumbnailSize: 128, viewZoom: 1,
                            fitRequest: 0, thumbnails: [:], assetURLs: urls, badges: [:],
                            operations: [], isActive: true)
        }
        configurePreview([second.id])
        var steps: [String] = []
        var firstVisibleIndex = -1
        let opened = board.presentPreview(acquireControl: {
            steps.append("acquire")
            return true
        }, synchronize: {
            steps.append("synchronize")
            firstVisibleIndex = board.preparedPreviewIndex
        }, show: {
            steps.append("show")
        })
        try check(opened && steps == ["acquire", "synchronize", "show"],
                  "Quick Look prepares its data and selected index before exposing its first frame")
        try check(firstVisibleIndex == 1 && board.previewPanel(nil, previewItemAt: 0)?.previewItemURL == urls[second.id],
                  "Opening a non-first photo presents the selected source from the first frame")
        try check(board.numberOfPreviewItems(in: nil) == 1 && board.previewPanel(nil, previewItemAt: 1) == nil,
                  "Quick Look exposes only the current photo so native previous/next buttons are unnecessary")

        var displayedIndex = -1
        board.navigatePreview(with: 125) { displayedIndex = $0 }
        try check(displayedIndex == -1 && board.preparedPreviewIndex == 1 && selection == [second.id],
                  "Quick Look down arrow stays on the current photo when the grid has only one row")
        board.navigatePreview(with: 126) { displayedIndex = $0 }
        try check(displayedIndex == -1 && board.preparedPreviewIndex == 1 && selection == [second.id],
                  "Quick Look up arrow never jumps sideways from the first row")
        board.navigatePreview(with: 123) { displayedIndex = $0 }
        try check(displayedIndex == 0 && selection == [first.id],
                  "Quick Look left arrow selects the previous photo")
        try check(board.numberOfPreviewItems(in: nil) == 1 && board.previewPanel(nil, previewItemAt: 0)?.previewItemURL == urls[first.id],
                  "The single native preview item follows keyboard navigation")
        board.navigatePreview(with: 124) { displayedIndex = $0 }
        try check(displayedIndex == 1 && selection == [second.id],
                  "Quick Look right arrow selects the next photo")

        configurePreview([third.id])
        steps.removeAll()
        _ = board.presentPreview(acquireControl: { true }, synchronize: {
            firstVisibleIndex = board.preparedPreviewIndex
        }, show: { steps.append("show") })
        try check(firstVisibleIndex == 2 && steps == ["show"],
                  "Reopening on another photo cannot reuse the preceding preview index")
        steps.removeAll()
        let rejected = board.presentPreview(acquireControl: { false }, synchronize: {
            steps.append("synchronize")
        }, show: { steps.append("show") })
        try check(!rejected && steps.isEmpty,
                  "A failed controller handoff never exposes stale Quick Look content")

        board.syncSelectionToPreviewIndex(0)
        try check(selection == [first.id] && board.preparedPreviewIndex == 0,
                  "Preview navigation folds the visible photo into the selection")
        board.syncSelectionToPreviewIndex(0)
        try check(selection == [first.id] && board.preparedPreviewIndex == 0,
                  "A repeated identical preview index leaves the selection untouched")
        board.syncSelectionToPreviewIndex(Int.max)
        board.syncSelectionToPreviewIndex(-1)
        try check(selection == [first.id] && board.preparedPreviewIndex == 0,
                  "Stale preview indices such as NSNotFound never disturb the selection")
        try check(moves == 0, "Quick Look navigation never edits photo order or positions")

        let gridAssets = (0..<8).map {
            ProjectAsset(id: UUID(), fileName: "preview-grid-\($0).png", name: "preview-grid-\($0).png",
                         position: CGPoint(x: CGFloat($0) * ProjectMaterialLayout(thumbnailSize: 128).groupColumnStride, y: 0))
        }
        let gridScroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 176))
        let gridBoard = ProjectMaterialDocumentView(frame: .zero)
        gridScroll.documentView = gridBoard
        var gridSelection = Set<UUID>()
        var gridURLs = Dictionary(uniqueKeysWithValues: gridAssets.map {
            ($0.id, URL(fileURLWithPath: "/preview-fixture/" + $0.fileName))
        })
        gridBoard.onSelectionChange = { gridSelection = $0 }
        func configureGrid(_ ids: Set<UUID>) {
            gridSelection = ids
            gridBoard.configure(assets: gridAssets, selection: ids, thumbnailSize: 128, viewZoom: 1,
                                fitRequest: 0, thumbnails: [:], assetURLs: gridURLs, badges: [:],
                                operations: [], isActive: true)
        }
        func prepareGrid(at index: Int) {
            configureGrid([gridAssets[index].id])
            _ = gridBoard.presentPreview(acquireControl: { true }, synchronize: {}, show: {})
        }
        func moveGrid(_ key: UInt16) -> Int? {
            var shown: Int?
            gridBoard.navigatePreview(with: key) { shown = $0 }
            configureGrid(gridSelection)
            return shown
        }
        prepareGrid(at: 1)
        try check(moveGrid(125) == 4 && gridSelection == [gridAssets[4].id],
                  "Down moves to the same column in the next three-column grid row")
        try check(moveGrid(125) == 7 && gridSelection == [gridAssets[7].id],
                  "Down can reach the matching column in a short final row")
        try check(moveGrid(125) == nil && gridBoard.preparedPreviewIndex == 7,
                  "Down at the last row leaves the current preview unchanged")
        try check(moveGrid(126) == 4 && moveGrid(126) == 1 && gridSelection == [gridAssets[1].id],
                  "Up retraces rows in the same grid column")
        try check(moveGrid(126) == nil && gridBoard.preparedPreviewIndex == 1,
                  "Up at the first row never clamps sideways to the first photo")
        prepareGrid(at: 5)
        try check(moveGrid(125) == nil && gridSelection == [gridAssets[5].id],
                  "A missing column in the short final row never selects another column")
        prepareGrid(at: 3)
        try check(moveGrid(123) == 2 && moveGrid(124) == 3,
                  "Left and right retain sequential navigation across a row boundary")

        prepareGrid(at: 1)
        gridScroll.setFrameSize(CGSize(width: 320, height: 176))
        gridScroll.tile()
        gridBoard.updateDocumentSize()
        try check(moveGrid(125) == 3 && gridSelection == [gridAssets[3].id],
                  "Preview navigation follows the new two-column layout after the viewport narrows")
        gridScroll.setFrameSize(CGSize(width: 500, height: 176))
        gridScroll.tile()
        gridBoard.updateDocumentSize()
        gridURLs.removeValue(forKey: gridAssets[0].id)
        gridURLs.removeValue(forKey: gridAssets[4].id)
        prepareGrid(at: 1)
        try check(moveGrid(125) == 5 && gridSelection == [gridAssets[7].id],
                  "Missing source URLs are skipped down the same full-grid column rather than compressing the layout")
        try check(gridBoard.numberOfPreviewItems(in: nil) == 1 &&
                  gridBoard.previewPanel(nil, previewItemAt: 0)?.previewItemURL == gridURLs[gridAssets[7].id],
                  "The sole native preview item tracks the current photo even with gaps in the source list")
        try check(moveGrid(126) == 0 && gridSelection == [gridAssets[1].id],
                  "Up skips an unavailable photo while preserving its original grid column")
        prepareGrid(at: 3)
        try check(moveGrid(124) == 3 && gridSelection == [gridAssets[5].id],
                  "Horizontal navigation skips a photo without a source URL")

        func previewKey(_ key: UInt16, type: NSEvent.EventType = .keyDown,
                        modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                            isARepeat: repeating, keyCode: key)!
        }
        prepareGrid(at: 1)
        var routedIndex: Int?
        let routed = gridBoard.handlePreviewArrowKey(previewKey(125, modifiers: [.function, .numericPad])) {
            routedIndex = $0
        }
        try check(routed && routedIndex == 5 && gridSelection == [gridAssets[7].id],
                  "A native arrow event is consumed and navigates by grid row before Quick Look handles it")
        configureGrid(gridSelection)
        routedIndex = nil
        let repeated = gridBoard.handlePreviewArrowKey(previewKey(126, repeating: true)) { routedIndex = $0 }
        try check(repeated && routedIndex == 0 && gridSelection == [gridAssets[1].id],
                  "Holding an arrow key continues preview navigation")
        configureGrid(gridSelection)
        routedIndex = nil
        try check(gridBoard.handlePreviewArrowKey(previewKey(126)) { routedIndex = $0 } && routedIndex == nil,
                  "A boundary arrow is still consumed so Quick Look cannot perform its own fallback navigation")
        for modifiers: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            let handled = gridBoard.handlePreviewArrowKey(previewKey(125, modifiers: modifiers)) { routedIndex = $0 }
            try check(!handled && routedIndex == nil && gridBoard.preparedPreviewIndex == 0,
                      "\(modifiers): modified arrows are left to their existing system behavior")
        }
        for event in [previewKey(125, type: .keyUp), previewKey(18), previewKey(49)] {
            let handled = gridBoard.handlePreviewArrowKey(event) { routedIndex = $0 }
            try check(!handled && routedIndex == nil && gridBoard.preparedPreviewIndex == 0,
                      "Key-up, number and space events do not enter arrow navigation")
        }
        gridBoard.configure(assets: gridAssets, selection: gridSelection, thumbnailSize: 128, viewZoom: 1,
                            fitRequest: 0, thumbnails: [:], assetURLs: gridURLs, badges: [:],
                            operations: [], isActive: false)
        try check(!gridBoard.handlePreviewArrowKey(previewKey(125)) { routedIndex = $0 } && routedIndex == nil,
                  "An inactive material board never intercepts preview arrow events")

        gridBoard.isGroupRow = true
        gridBoard.configure(assets: [], selection: [], thumbnailSize: 128, viewZoom: 1,
                            fitRequest: 0, thumbnails: [:], assetURLs: [:], badges: [:],
                            operations: [], isActive: true)
        prepareGrid(at: 3)
        let groupPreviewIndex = gridBoard.preparedPreviewIndex
        try check(moveGrid(125) == nil && moveGrid(126) == nil && gridBoard.preparedPreviewIndex == groupPreviewIndex,
                  "A photo group is a single horizontal row, so vertical preview navigation stays put")
        try check(moveGrid(123) == 1 && gridSelection == [gridAssets[2].id],
                  "Grouped photos still support left and right preview navigation")
        return checks
    }
}
