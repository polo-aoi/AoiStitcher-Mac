import Foundation
import CoreGraphics

/// Geometry and ordering only; no NSApplication, windows or views are created.
nonisolated enum ProjectMaterialGridRegressionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
            guard value() else {
                throw NSError(domain: "ProjectMaterialGridRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks += 1
        }

        let sizes: [CGFloat] = [48, 64, 128, 240]
        let widths: [CGFloat] = [1, 80, 220, 260, 480, 800, 1_200]
        for thumbnail in sizes {
            for width in widths {
                let layout = ProjectMaterialGridLayout(count: 35, viewportWidth: width, thumbnailSize: thumbnail)
                try check(layout.columns >= 1 && layout.height.isFinite, "Every viewport has a finite grid")
                let cells = (0..<35).map { layout.frame(at: $0) }
                try check(cells.allSatisfy { $0.minX >= 0 && $0.maxX <= width + 0.0001 },
                          "No cell extends beyond the viewport, even with maximum-size photos")
                try check(zip(cells, cells.dropFirst()).allSatisfy { !$0.intersects($1) },
                          "Adjacent cards never overlap")
            }
        }

        let wide = ProjectMaterialGridLayout(count: 20, viewportWidth: 800, thumbnailSize: 128)
        let narrow = ProjectMaterialGridLayout(count: 20, viewportWidth: 260, thumbnailSize: 128)
        try check(wide.columns > narrow.columns && narrow.height > wide.height,
                  "A narrower divider position adds rows instead of horizontal overflow")
        let largest = ProjectMaterialGridLayout(count: 20, viewportWidth: 220, thumbnailSize: 240)
        try check(largest.columns == 1 && largest.frame(at: 0).maxX <= 220,
                  "A large thumbnail fits a narrow single-column viewport")
        let empty = ProjectMaterialGridLayout(count: 0, viewportWidth: 400, thumbnailSize: 128)
        try check(empty.height == 0 && empty.insertionIndex(at: .zero) == 0,
                  "Empty projects have no fabricated grid content")
        let first = wide.frame(at: 0)
        try check(wide.insertionIndex(at: CGPoint(x: first.minX, y: first.midY)) == 0 &&
                  wide.insertionIndex(at: CGPoint(x: first.maxX, y: first.midY)) == 1,
                  "Dropping on either side of a thumbnail selects its preceding or following slot")
        let nextRow = wide.frame(at: wide.columns)
        try check(wide.insertionIndex(at: CGPoint(x: 0, y: nextRow.midY)) == wide.columns,
                  "The left edge of a later row selects that row's first slot")
        try check(wide.insertionIndex(at: CGPoint(x: 100_000, y: wide.height + 10)) == 20,
                  "Dropping below all rows appends")
        try check(wide.insertionMarker(at: 0).minX >= 0 &&
                  wide.insertionMarker(at: 20).maxX <= wide.viewportWidth,
                  "Insertion feedback remains within the viewport")

        let ids = (0..<6).map { _ in UUID() }
        try check(ProjectMaterialGridLayout.reordered(ids, moving: [ids[5]], insertionIndex: 0)
                    == [ids[5]] + Array(ids.prefix(5)),
                  "The last photo can move before the first")
        try check(ProjectMaterialGridLayout.reordered(ids, moving: [ids[0]], insertionIndex: 6)
                    == Array(ids.dropFirst()) + [ids[0]],
                  "The first photo can move after the last")
        try check(ProjectMaterialGridLayout.reordered(ids, moving: [ids[1], ids[3]], insertionIndex: 6)
                    == [ids[0], ids[2], ids[4], ids[5], ids[1], ids[3]],
                  "A noncontiguous selection moves as a block in original order")
        try check(ProjectMaterialGridLayout.reordered(ids, moving: [ids[1], ids[2]], insertionIndex: 2) == ids,
                  "Dropping within the selected block is a no-op")
        try check(ProjectMaterialGridLayout.reordered(ids, moving: Set(ids), insertionIndex: 6) == ids,
                  "Dragging all photos retains their ordering")
        let filtered = [ids[1], ids[3], ids[5]]
        let reordered = ProjectMaterialGridLayout.reordered(filtered, moving: [ids[5]], insertionIndex: 0)
        try check(reordered == [ids[5], ids[1], ids[3]] && Set(reordered) == Set(filtered),
                  "A filtered drag returns only the visible subset for the store to merge")
        try check(ids.count == 6 && filtered == [ids[1], ids[3], ids[5]],
                  "Reflow and reordering never mutate the input project ordering")
        return checks
    }
}
