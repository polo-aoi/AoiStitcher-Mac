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
                                  position: CGPoint(x: 148, y: 0))
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

        for point in [CGPoint(x: 150, y: 24), CGPoint(x: 420, y: 24), CGPoint(x: 24, y: 155)] {
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
            for size in [CGSize(width: 64, height: 128), CGSize(width: 128, height: 64)] {
                let image = NSImage(size: size)
                board.configure(assets: assets, selection: Set(assets.map(\.id)), thumbnailSize: 128,
                                viewZoom: 1, fitRequest: 0, thumbnails: [first.id: image], assetURLs: [:],
                                badges: [:], operations: [], isActive: true)
                let margin: CGFloat = groupRow ? 4 : 12
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
        try check(firstVisibleIndex == 1 && board.previewPanel(nil, previewItemAt: 1)?.previewItemURL == urls[second.id],
                  "Opening a non-first photo presents the selected source from the first frame")

        var displayedIndex = -1
        board.navigatePreview(with: 125) { displayedIndex = $0 }
        try check(displayedIndex == 2 && selection == [third.id],
                  "Quick Look down arrow advances one photo and updates the underlying selection")
        board.navigatePreview(with: 126) { displayedIndex = $0 }
        try check(displayedIndex == 1 && selection == [second.id],
                  "Quick Look up arrow goes back one photo without grid-row jumps")
        board.navigatePreview(with: 123) { displayedIndex = $0 }
        try check(displayedIndex == 0 && selection == [first.id],
                  "Quick Look left arrow selects the previous photo")
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
                  "Panel-driven navigation folds the visible photo into the selection")
        board.syncSelectionToPreviewIndex(0)
        try check(selection == [first.id] && board.preparedPreviewIndex == 0,
                  "A repeated identical panel index leaves the selection untouched")
        board.syncSelectionToPreviewIndex(Int.max)
        board.syncSelectionToPreviewIndex(-1)
        try check(selection == [first.id] && board.preparedPreviewIndex == 0,
                  "Stale panel indices such as NSNotFound never disturb the selection")
        try check(moves == 0, "Quick Look navigation never edits photo order or positions")
        return checks
    }
}
