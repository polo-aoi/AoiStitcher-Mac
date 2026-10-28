import AppKit
import Combine
import SwiftUI

/// Exercises several real board representables in the same SwiftUI lazy list.
/// The hosting view is never attached to a window or displayed on screen.
@MainActor enum ProjectPhotoGroupLayoutRegressionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectPhotoGroupLayoutRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        let model = GroupLayoutFixtureModel()
        let host = NSHostingView(rootView: GroupLayoutFixture(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 1100)

        func settle() {
            // SwiftUI commits representable creation and changes on the next
            // run-loop pass; no application event loop or window is started.
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            host.layoutSubtreeIfNeeded()
        }
        func rows() -> [ProjectPhotoGroupContainerView] {
            descendants(of: host, matching: ProjectPhotoGroupContainerView.self)
                .sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
        }
        func verifyRows(_ label: String) throws {
            settle()
            let currentRows = rows()
            try check(currentRows.compactMap(\.groupID) == model.order,
                      "\(label): all four rows remain present in displayed order")
            let expectedHeight = model.thumbnailSize + 24
            var previousBottom: CGFloat?
            for (index, row) in currentRows.enumerated() {
                let frame = row.convert(row.bounds, to: host)
                try check(abs(frame.height - expectedHeight) < 0.5 && frame.width > 400,
                          "\(label): row \(index) keeps its own full-width frame")
                if let previousBottom {
                    try check(frame.minY >= previousBottom + 3.5,
                              "\(label): row \(index) does not overlap the previous row")
                }
                previousBottom = frame.maxY
                try check(row.visibleRect == row.bounds,
                          "\(label): row \(index) cannot paint over neighboring rows; visible \(row.visibleRect), bounds \(row.bounds)")
                let handle = row.handleView
                try check(handle.visibleRect == handle.bounds,
                          "\(label): row \(index)'s handle cannot paint across the list; visible \(handle.visibleRect), bounds \(handle.bounds)")
                let handlePoint = CGPoint(x: 20, y: expectedHeight / 2)
                let handleTarget = row.hitTest(row.convert(handlePoint, to: row.superview))
                try check(handleTarget === handle,
                          "\(label): row \(index)'s selection strip remains independently clickable")
                guard let board = row.scrollView.documentView as? ProjectMaterialDocumentView else {
                    throw NSError(domain: "ProjectPhotoGroupLayoutRegressionTests", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing real photo document"])
                }
                let photoPoint = board.convert(CGPoint(x: 24, y: 24), to: row.superview)
                try check(row.hitTest(photoPoint) === board,
                          "\(label): row \(index)'s photo remains independently clickable")
                click(handle, at: handlePoint)
                try check(model.chosenGroupID == row.groupID,
                          "\(label): clicking row \(index)'s handle selects that group")
                settle()
                click(board, at: CGPoint(x: 24, y: 24))
                try check(model.selection == [model.assets[model.order[index]]![0].id],
                          "\(label): clicking a photo in row \(index) selects only that photo")
            }
        }

        try verifyRows("Initial four-row list")
        model.thumbnailSize = 72
        try verifyRows("Smaller thumbnails")
        model.thumbnailSize = 184
        try verifyRows("Larger thumbnails")
        model.order = [model.order[3], model.order[0], model.order[2], model.order[1]]
        try verifyRows("Reordered groups")
        return checks
    }

    private static func descendants<T: NSView>(of root: NSView, matching type: T.Type) -> [T] {
        root.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: child, matching: type)
        }
    }

    private static func click(_ view: NSView, at point: CGPoint) {
        let location = view.convert(point, to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                     modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                                   modifierFlags: [], timestamp: 0.1, windowNumber: 0,
                                   context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }
}

@MainActor private final class GroupLayoutFixtureModel: ObservableObject {
    @Published var order: [UUID]
    @Published var thumbnailSize: CGFloat = 120
    @Published var selection: Set<UUID> = []
    @Published var chosenGroupID: UUID?
    let assets: [UUID: [ProjectAsset]]

    init() {
        let ids = (0..<4).map { _ in UUID() }
        order = ids
        assets = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, (0..<2).map { index in
                ProjectAsset(id: UUID(), fileName: "photo-\(index).png", name: "photo-\(index).png",
                             position: .zero, groupID: id)
            })
        })
    }

    func positionedAssets(in id: UUID) -> [ProjectAsset] {
        (assets[id] ?? []).enumerated().map { index, asset in
            var positioned = asset
            positioned.position = CGPoint(x: CGFloat(index) * (thumbnailSize + 20), y: 0)
            return positioned
        }
    }
}

@MainActor private struct GroupLayoutFixture: View {
    @ObservedObject var model: GroupLayoutFixtureModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.order, id: \.self) { id in
                    ProjectMaterialBoard(
                        assets: model.positionedAssets(in: id), selection: $model.selection,
                        thumbnailSize: model.thumbnailSize, viewZoom: .constant(1),
                        fitRequest: 0, thumbnails: [:], badges: [:],
                        onMove: { _ in }, onImport: { _, _ in }, onActivate: { _ in },
                        isGroupRow: true,
                        onGroupChoose: {
                            model.chosenGroupID = id
                            model.selection = Set(model.assets[id, default: []].map(\.id))
                        },
                        isGroupSelected: model.chosenGroupID == id,
                        groupDragID: id
                    )
                    .frame(height: model.thumbnailSize + 24)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay { Rectangle().strokeBorder(Color.gray).allowsHitTesting(false) }
                    .id(id)
                }
            }
            .padding(4)
            .projectOverlayScrollbars()
        }
    }
}
