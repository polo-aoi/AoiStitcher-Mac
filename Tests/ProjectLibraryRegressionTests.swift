import Foundation
import CoreGraphics

@MainActor enum ProjectLibraryRegressionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectLibraryRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: description])
            }
            checks += 1
        }

        // A project written before ratings, color labels and removal existed.
        // Keep the fixture independent of the new encoder so omitted fields stay omitted.
        let legacyJSON = #"""
        {
          "id": "10000000-0000-0000-0000-000000000001",
          "name": "原有项目",
          "createdAt": 100,
          "modifiedAt": 200,
          "thumbnailSize": 128,
          "assets": [{
            "id": "20000000-0000-0000-0000-000000000001",
            "fileName": "original.png",
            "name": "原有照片.png",
            "position": [24, 48]
          }],
          "exports": [{
            "id": "30000000-0000-0000-0000-000000000001",
            "operation": "freeCanvas",
            "assetIDs": ["20000000-0000-0000-0000-000000000001"],
            "createdAt": 150,
            "outputPath": "/tmp/原有作品.png"
          }]
        }
        """#
        let decoder = JSONDecoder()
        var document = try decoder.decode(ProjectDocument.self, from: Data(legacyJSON.utf8))
        let legacyAsset = document.assets[0]
        try check(legacyAsset.rating == 0 && legacyAsset.colorLabel == .none && !legacyAsset.isRemoved,
                  "Old projects open with neutral labels and all original assets visible")
        try check(legacyAsset.position == CGPoint(x: 24, y: 48) && document.activeAssets.count == 1 &&
                  document.exports[0].assetIDs == [legacyAsset.id] && document.viewZoom == nil,
                  "Migration preserves photo placement and existing export associations")

        document.assets[0].rating = 5
        document.assets[0].colorLabel = .purple
        document.assets[0].isRemoved = true
        document.viewZoom = 0.57
        let added = ProjectAsset(id: UUID(), fileName: "added.jpg", name: "新照片.jpg",
                                 position: CGPoint(x: 210, y: 48), rating: 2, colorLabel: .red)
        document.assets.append(added)
        for operation in [ProjectOperation.compression] {
            document.exports.append(ProjectExportRecord(id: UUID(), operation: operation,
                assetIDs: [legacyAsset.id, added.id], createdAt: Date(timeIntervalSinceReferenceDate: 300),
                outputPath: "/tmp/\(operation.rawValue).jpg"))
        }
        let reopened = try decoder.decode(ProjectDocument.self, from: JSONEncoder().encode(document))
        try check(reopened.assets == document.assets && reopened.viewZoom == 0.57,
                  "Ratings, colors, removal state, placement and zoom survive a metadata round trip")
        try check(reopened.activeAssets.map(\.id) == [added.id] && reopened.assets[0].fileName == "original.png",
                  "Removed photos leave the material list while their original identity remains available")
        try check(reopened.exports.map(\.id) == document.exports.map(\.id) &&
                  reopened.exports.map(\.operation) == [.freeCanvas, .compression] &&
                  reopened.exports[0].assetIDs == [legacyAsset.id] &&
                  reopened.exports[1].assetIDs == [legacyAsset.id, added.id] &&
                  reopened.exports[1].outputPath == "/tmp/compression.jpg",
                  "Removal and new operation types preserve historical exports on reopening")

        // These URLs are identifiers only; no files are imported or created.
        let urls = (0..<17).map { URL(fileURLWithPath: "/tmp/project-regression-\($0).png") }
        let busy = ProjectEditorBridge()
        busy.update(operation: .freeCanvas, count: 3, signature: "canvas-a", isBusy: true)
        try check(!busy.send(operation: .freeCanvas, urls: Array(urls.prefix(2))) && busy.request == nil,
                  "A busy destination refuses a second import without changing its current draft")
        busy.update(operation: .freeCanvas, count: 3, signature: "canvas-a", isBusy: false)
        try check(busy.send(operation: .freeCanvas, urls: Array(urls.prefix(2))),
                  "The same selection can be sent once the destination is ready")
        let pendingID = try requireRequestID(busy)
        try check(!busy.send(operation: .compression, urls: [urls[2]]) && busy.request?.id == pendingID,
                  "A second destination cannot overwrite a request waiting to be consumed")
        busy.consume(id: UUID())
        try check(busy.request?.id == pendingID, "An unrelated consumer cannot discard a pending import")
        busy.consume(id: pendingID)
        try check(busy.send(operation: .compression, urls: [urls[2]]),
                  "Consuming the matching request permits the next operation")

        let grid = ProjectEditorBridge()
        grid.update(operation: .gridCollage, count: 15, signature: "grid-15", isBusy: false)
        try check(!grid.send(operation: .gridCollage, urls: Array(urls.prefix(2)), mode: .append) && grid.request == nil,
                  "Appending checks existing photos against the standard collage capacity")
        try check(grid.send(operation: .gridCollage, urls: [urls[0]], mode: .append),
                  "Appending exactly up to the standard collage capacity is allowed")
        grid.consume(id: try requireRequestID(grid))
        try check(grid.send(operation: .gridCollage, urls: Array(urls.prefix(16)), mode: .replace) &&
                  grid.request?.mode == .replace && grid.request?.urls.count == 16,
                  "Replacing a full collage validates only the incoming group and preserves replacement intent")
        grid.consume(id: try requireRequestID(grid))
        try check(!grid.send(operation: .gridCollage, urls: urls, mode: .replace) && grid.request == nil,
                  "Replacement still rejects a group larger than the collage capacity")

        let exported = ProjectEditorBridge()
        exported.update(operation: .freeCanvas, count: 3, signature: "composition-a", isBusy: false)
        exported.update(operation: .longStitch, count: 3, signature: "composition-a", isBusy: false)
        try check(exported.status(for: .freeCanvas).hasUnexportedChanges,
                  "A new composition starts with unexported content")
        exported.didExport(operation: .freeCanvas, signature: "composition-a")
        try check(!exported.status(for: .freeCanvas).hasUnexportedChanges &&
                  exported.status(for: .longStitch).hasUnexportedChanges,
                  "Successful export marks only the destination that produced that output")
        // View-only navigation reports the unchanged output signature.
        exported.update(operation: .freeCanvas, count: 3, signature: "composition-a", isBusy: false)
        try check(!exported.status(for: .freeCanvas).hasUnexportedChanges,
                  "Viewing the same exported composition does not create an unexported-content warning")
        exported.update(operation: .freeCanvas, count: 3, signature: "composition-b", isBusy: false)
        try check(exported.status(for: .freeCanvas).hasUnexportedChanges,
                  "Editing an exported composition restores the unexported-content warning")

        let delayedExport = ProjectEditorBridge()
        delayedExport.update(operation: .freeCanvas, count: 3, signature: "snapshot-before-edit", isBusy: true)
        delayedExport.update(operation: .freeCanvas, count: 3, signature: "snapshot-after-edit", isBusy: true)
        delayedExport.didExport(operation: .freeCanvas, signature: "snapshot-before-edit")
        try check(delayedExport.status(for: .freeCanvas).hasUnexportedChanges &&
                  delayedExport.status(for: .freeCanvas).isBusy,
                  "Finishing an older export does not mark newer edits clean or clear another busy operation")
        delayedExport.update(operation: .freeCanvas, count: 3, signature: "snapshot-after-edit", isBusy: false)
        delayedExport.didExport(operation: .freeCanvas, signature: "snapshot-after-edit")
        try check(!delayedExport.status(for: .freeCanvas).hasUnexportedChanges,
                  "Exporting the current snapshot finally clears its warning")
        return checks
    }

    private static func requireRequestID(_ bridge: ProjectEditorBridge) throws -> UUID {
        guard let id = bridge.request?.id else {
            throw NSError(domain: "ProjectLibraryRegressionTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Expected an accepted import request"])
        }
        return id
    }
}
