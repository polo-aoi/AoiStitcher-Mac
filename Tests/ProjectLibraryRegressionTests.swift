import Foundation
import CoreGraphics

@MainActor enum ProjectLibraryRegressionTests {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectLibraryRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: description])
            }
            checks += 1
        }

        // Filtering is scoped to successful exports of the chosen tool. Using one
        // tool must not hide a photo from another tool's unfinished-work list.
        let gridOnly: Set<ProjectOperation> = [.gridCollage]
        let multipleTools: Set<ProjectOperation> = [.gridCollage, .freeCanvas]
        var materialFilter = ProjectMaterialFilter()
        try check(!materialFilter.isActive && materialFilter.includes(operations: []) &&
                  materialFilter.includes(operations: multipleTools),
                  "The default material filter includes both unused and exported photos")
        materialFilter.status = .unused
        try check(materialFilter.includes(operations: []) && !materialFilter.includes(operations: gridOnly),
                  "Unused without a selected tool means no successful export in any tool")
        materialFilter.status = .used
        try check(!materialFilter.includes(operations: []) && materialFilter.includes(operations: gridOnly) &&
                  materialFilter.includes(operations: multipleTools),
                  "Used without a selected tool includes photos exported by one or several tools")
        materialFilter.operation = .freeCanvas
        materialFilter.status = .unused
        try check(materialFilter.isActive && materialFilter.includes(operations: []) &&
                  materialFilter.includes(operations: gridOnly) && !materialFilter.includes(operations: multipleTools),
                  "A standard-collage export remains unused for free canvas until that tool exports it")
        materialFilter.status = .used
        try check(!materialFilter.includes(operations: []) && !materialFilter.includes(operations: gridOnly) &&
                  materialFilter.includes(operations: multipleTools),
                  "Used for free canvas matches that tool even when other export types also exist")
        materialFilter.status = .all
        try check(materialFilter.includes(operations: []) && materialFilter.includes(operations: gridOnly) &&
                  materialFilter.includes(operations: multipleTools),
                  "All statuses include both processed and unprocessed photos for the chosen tool")
        materialFilter.status = .unused
        try check(materialFilter.includes(operations: [.compression]),
                  "Legacy compression exports do not count as successful free-canvas exports")
        materialFilter = ProjectMaterialFilter()
        try check(materialFilter.operation == nil && materialFilter.status == .all && !materialFilter.isActive &&
                  materialFilter.includes(operations: []) && materialFilter.includes(operations: multipleTools),
                  "Clearing the filter resets both tool and status without excluding any photo")

        // A project written before removal existed,
        // including an export from the compression workspace that has since moved out.
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
          }, {
            "id": "30000000-0000-0000-0000-000000000002",
            "operation": "compression",
            "assetIDs": ["20000000-0000-0000-0000-000000000001"],
            "createdAt": 175,
            "outputPath": "/tmp/原有压缩作品.jpg"
          }]
        }
        """#
        let decoder = JSONDecoder()
        var document = try decoder.decode(ProjectDocument.self, from: Data(legacyJSON.utf8))
        let legacyAsset = document.assets[0]
        try check(document.groupThumbnailSize == document.thumbnailSize && document.thumbnailSizesLinked &&
                  document.materialOrder == [legacyAsset.id],
                  "Legacy projects migrate to linked equal thumbnail sizes and retain their material order")
        try check(!legacyAsset.isRemoved, "Old projects open with all original assets visible")
        try check(legacyAsset.position == CGPoint(x: 24, y: 48) && document.activeAssets.count == 1 &&
                  document.exports[0].assetIDs == [legacyAsset.id] && document.viewZoom == nil,
                  "Migration preserves photo placement and existing export associations")
        try check(document.exports[1].operation == .compression &&
                  document.exports[1].assetIDs == [legacyAsset.id] &&
                  document.exports[1].outputPath == "/tmp/原有压缩作品.jpg",
                  "Projects with a legacy compression export remain readable after the workspace moves out")
        try check(ProjectOperation.allCases == [.gridCollage, .freeCanvas, .longStitch],
                  "Current project destinations contain only the three collage tools")

        let labeledJSON = legacyJSON.replacingOccurrences(of: #""name": "原有照片.png","#,
            with: #""name": "原有照片.png", "rating": 5, "colorLabel": "purple","#)
        let labeledDocument = try decoder.decode(ProjectDocument.self, from: Data(labeledJSON.utf8))
        try check(labeledDocument.assets == document.assets,
                  "Legacy star and color labels are ignored without changing asset identity or placement")
        let encodedLegacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(labeledDocument)) as? [String: Any]
        let encodedAsset = (encodedLegacy?["assets"] as? [[String: Any]])?.first
        try check(encodedAsset != nil && encodedAsset?["rating"] == nil && encodedAsset?["colorLabel"] == nil,
                  "Saving a migrated project removes the retired rating and color properties")
        document.assets[0].isRemoved = true
        document.viewZoom = 0.57
        let added = ProjectAsset(id: UUID(), fileName: "added.jpg", name: "新照片.jpg",
                                 position: CGPoint(x: 210, y: 48))
        document.assets.append(added)
        document.exports.append(ProjectExportRecord(id: UUID(), operation: .longStitch,
            assetIDs: [legacyAsset.id, added.id], createdAt: Date(timeIntervalSinceReferenceDate: 300),
            outputPath: "/tmp/longStitch.jpg"))
        let reopened = try decoder.decode(ProjectDocument.self, from: JSONEncoder().encode(document))
        try check(reopened.materialOrder == [legacyAsset.id, added.id] &&
                  reopened.orderedActiveAssets.map(\.id) == [added.id],
                  "Missing material order entries are appended while removed identities keep their slots")
        try check(reopened.assets == document.assets && reopened.viewZoom == 0.57,
                  "Removal state, placement and zoom survive a metadata round trip")
        try check(reopened.activeAssets.map(\.id) == [added.id] && reopened.assets[0].fileName == "original.png",
                  "Removed photos leave the material list while their original identity remains available")
        try check(reopened.exports.map(\.id) == document.exports.map(\.id) &&
                  reopened.exports.map(\.operation) == [.freeCanvas, .compression, .longStitch] &&
                  reopened.exports[0].assetIDs == [legacyAsset.id] &&
                  reopened.exports[1].assetIDs == [legacyAsset.id] &&
                  reopened.exports[1].outputPath == "/tmp/原有压缩作品.jpg" &&
                  reopened.exports[2].assetIDs == [legacyAsset.id, added.id] &&
                  reopened.exports[2].outputPath == "/tmp/longStitch.jpg",
                  "New edits and exports preserve legacy compression history on reopening")

        let layout = ProjectMaterialLayout(thumbnailSize: 128)
        let first = ProjectAsset(id: UUID(), fileName: "one.png", name: "one", position: CGPoint(x: 100, y: 10))
        let second = ProjectAsset(id: UUID(), fileName: "two.png", name: "two", position: CGPoint(x: 300, y: 10))
        let third = ProjectAsset(id: UUID(), fileName: "three.png", name: "three", position: CGPoint(x: 20, y: 220))
        let untouched = ProjectAsset(id: UUID(), fileName: "four.png", name: "four", position: CGPoint(x: 700, y: 450))
        let removed = ProjectAsset(id: UUID(), fileName: "removed.png", name: "removed", position: .zero, isRemoved: true)
        try check(ProjectMaterialLayout(thumbnailSize: 1).thumbnailSize == 48 &&
                  ProjectMaterialLayout(thumbnailSize: 1_000).thumbnailSize == 240,
                  "Thumbnail geometry uses the supported size limits")

        // Exercise real persistence and undo in a disposable project directory, never in the user's library.
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("aoistitcher-library-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let historyRecord = ProjectExportRecord(id: UUID(), operation: .gridCollage, assetIDs: [first.id],
                                               createdAt: Date(), outputPath: "/tmp/previous-export.png")
        let fixture = ProjectDocument(id: UUID(), name: "布局回归", createdAt: Date(), modifiedAt: Date(),
                                      assets: [third, untouched, first, removed, second], exports: [historyRecord],
                                      thumbnailSize: 128, viewZoom: 0.57)
        let projectDirectory = temporaryRoot.appendingPathComponent(fixture.id.uuidString)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let metadata = projectDirectory.appendingPathComponent("project.json")
        try JSONEncoder().encode(fixture).write(to: metadata)
        let library = ProjectLibraryStore(projectsDirectory: temporaryRoot)
        library.openProject(id: fixture.id)
        try check(library.currentProject?.viewZoom == 0.57, "Opening a project preserves its saved viewport zoom")
        try check(library.currentProject?.orderedActiveAssets.map(\.id) == [first.id, second.id, third.id, untouched.id] &&
                  library.currentProject?.materialOrder.first == removed.id,
                  "Migrated grid order follows legacy spatial order and includes removed identities")
        guard let groupID = library.createGroup([first.id, second.id, third.id, removed.id, UUID()]) else {
            throw NSError(domain: "ProjectLibraryRegressionTests", code: 3)
        }
        try check(library.flushPendingSaves(), "Queued grouping writes finish successfully")
        var persisted = try decoder.decode(ProjectDocument.self, from: Data(contentsOf: metadata))
        try check(persisted.groups == [ProjectPhotoGroup(id: groupID, assetIDs: [first.id, second.id, third.id])] &&
                  persisted.assets.allSatisfy { asset in fixture.assets.first(where: { $0.id == asset.id })?.position == asset.position } &&
                  persisted.assets.first(where: { $0.id == untouched.id })?.position == untouched.position &&
                  persisted.assets.first(where: { $0.id == removed.id }) == removed,
                  "Grouping preserves return positions and orders only valid active photos")
        try check(persisted.activeAssets.filter { $0.groupID == nil }.map(\.id) == [untouched.id],
                  "Grouped photos leave ungrouped materials without removing originals")
        try check(library.canUndoEdit && persisted.exports.map(\.id) == [historyRecord.id],
                  "Gathering is undoable and does not mark any new export")
        guard let exportContext = library.captureExport(operation: .freeCanvas,
                                                        sourceURLs: [library.assetURL(first), library.assetURL(second)]) else {
            throw NSError(domain: "ProjectLibraryRegressionTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not capture the source identities for export"])
        }
        try check(library.currentProject?.exports.count == 1,
                  "Preparing an export does not record success before the output has been saved")
        library.recordExport(exportContext, outputURL: URL(fileURLWithPath: "/tmp/new-export.png"))
        library.undoLastEdit()
        try check(library.flushPendingSaves(), "Export and undo writes complete in order")
        persisted = try decoder.decode(ProjectDocument.self, from: Data(contentsOf: metadata))
        try check(persisted.assets == fixture.assets && persisted.exports.count == 2 &&
                  persisted.exports[1].assetIDs == [first.id, second.id] && !library.canUndoEdit,
                  "Undo restores the placement while preserving an export completed after gathering")
        library.createGroup([first.id, second.id, third.id])
        library.setThumbnailSize(48)
        let smallLayout = ProjectMaterialLayout(thumbnailSize: 48)
        try check(library.flushPendingSaves(), "Resizing flushes safely")
        persisted = try decoder.decode(ProjectDocument.self, from: Data(contentsOf: metadata))
        try check(persisted.thumbnailSize == 48 && persisted.viewZoom == 1 &&
                  persisted.assets.allSatisfy { asset in
                      let original = fixture.assets.first(where: { $0.id == asset.id })!
                      return asset.position == smallLayout.rescaledPosition(original.position, from: layout)
                  }, "Thumbnail resizing preserves the relative layout, keeps a fixed gap and resets viewport magnification")
        library.undoLastEdit()
        try check(library.flushPendingSaves(), "Undo after resize flushes safely")
        persisted = try decoder.decode(ProjectDocument.self, from: Data(contentsOf: metadata))
        try check(persisted.assets.allSatisfy { asset in
            guard let original = fixture.assets.first(where: { $0.id == asset.id }) else { return false }
            return asset.position == smallLayout.rescaledPosition(original.position, from: layout)
        } && persisted.exports.count == 2,
        "Undo after resizing restores positions in the current thumbnail geometry and retains exports")
        library.setThumbnailSize(1_000)
        try check(library.currentProject?.thumbnailSize == 240, "The store clamps oversized thumbnails to 240 points")
        library.setThumbnailSize(-1)
        try check(library.flushPendingSaves(), "Rapid size changes retain the final value")
        let validState = try Data(contentsOf: metadata)
        library.setThumbnailSize(.nan)
        library.createGroup([first.id, removed.id])
        _ = library.flushPendingSaves()
        let unchangedState = try Data(contentsOf: metadata)
        try check(library.currentProject?.thumbnailSize == 48 && unchangedState == validState && !library.canUndoEdit,
                  "Invalid sizes and selections with fewer than two active photos leave saved metadata and undo unchanged")
        persisted = try decoder.decode(ProjectDocument.self, from: validState)
        library.closeProject()
        library.openProject(id: fixture.id)
        try check(library.currentProject?.assets == persisted.assets && library.currentProject?.exports.count == 2,
                  "Reopening preserves the resized layout and full export history")

        let firstGroup = library.createGroup([first.id, second.id])!
        let secondGroup = library.createGroup([third.id, untouched.id])!
        library.moveGroup(secondGroup, by: -1)
        library.moveGroupAsset(second.id, in: firstGroup, by: -1)
        try check(library.currentProject?.groups.map(\.id) == [secondGroup, firstGroup] &&
                  library.currentProject?.groups.last?.assetIDs == [second.id, first.id],
                  "Group rows and members can be reordered independently")
        library.closeProject()
        let independentReader = ProjectLibraryStore(projectsDirectory: temporaryRoot)
        independentReader.openProject(id: fixture.id)
        try check(independentReader.currentProject?.groups.map(\.id) == [secondGroup, firstGroup] &&
                  independentReader.currentProject?.groups.last?.assetIDs == [second.id, first.id],
                  "A fresh store sees both saved row and photo ordering after close")
        _ = independentReader.flushPendingSaves()
        library.openProject(id: fixture.id)
        let originalReturnPosition = library.currentProject!.assets.first { $0.id == second.id }!.position
        library.returnAssetsToMaterials([second.id])
        try check(library.currentProject?.groups.last?.assetIDs == [first.id] &&
                  library.currentProject?.assets.first(where: { $0.id == second.id })?.groupID == nil &&
                  library.currentProject?.assets.first(where: { $0.id == second.id })?.position == originalReturnPosition,
                  "Delete in a group returns only the selected photo to its original material position")
        library.returnAssetsToMaterials([first.id])
        try check(library.currentProject?.groups.map(\.id) == [secondGroup], "Empty rows disappear automatically")
        library.undoLastEdit()
        try check(library.currentProject?.groups.last?.assetIDs == [first.id], "Undo restores an emptied row")
        library.addAssets([first.id, second.id], to: secondGroup)
        try check(library.currentProject?.groups.count == 1 && library.currentProject?.groups[0].assetIDs.count == 4,
                  "Adding photos transfers membership without leaving duplicates or empty rows")
        library.setGroupAssetOrder([second.id, untouched.id, first.id, third.id], in: secondGroup)
        try check(library.currentProject?.groups[0].assetIDs == [second.id, untouched.id, first.id, third.id],
                  "A drag can save a complete member permutation atomically")
        library.setGroupAssetOrder([second.id, second.id, first.id, third.id], in: secondGroup)
        try check(library.currentProject?.groups[0].assetIDs == [second.id, untouched.id, first.id, third.id],
                  "Invalid member permutations cannot duplicate or lose photos")
        library.removeAssets([third.id])
        try check(library.currentProject?.groups[0].assetIDs.contains(third.id) == false &&
                  library.currentProject?.assets.first(where: { $0.id == third.id })?.isRemoved == true,
                  "Removing a project photo also removes its group membership")
        library.undoLastEdit()
        library.dissolveGroup(secondGroup)
        try check(library.currentProject?.groups.isEmpty == true &&
                  library.currentProject?.activeAssets.allSatisfy { $0.groupID == nil } == true,
                  "Dissolving returns every member to materials")

        // Two viewing sizes are independent when unlocked; relocking itself never jumps either side.
        library.setThumbnailSizesLinked(false)
        library.setViewZoom(0.73)
        let beforeRightResize = library.currentProject!.assets
        library.setGroupThumbnailSize(176)
        try check(library.currentProject?.thumbnailSize == 48 && library.currentProject?.groupThumbnailSize == 176 &&
                  library.currentProject?.assets == beforeRightResize && library.currentProject?.viewZoom == 0.73,
                  "An unlocked group slider changes neither material geometry nor its viewport zoom")
        library.setThumbnailSize(88)
        try check(library.currentProject?.thumbnailSize == 88 && library.currentProject?.groupThumbnailSize == 176,
                  "An unlocked material slider leaves group thumbnails unchanged")
        library.setThumbnailSizesLinked(true)
        try check(library.currentProject?.thumbnailSize == 88 && library.currentProject?.groupThumbnailSize == 176 &&
                  library.currentProject?.thumbnailSizesLinked == true,
                  "Relocking preserves unequal values until a slider is moved")
        library.setThumbnailSize(88)
        try check(library.currentProject?.groupThumbnailSize == 88,
                  "The first linked left gesture synchronizes the right even when the left value is unchanged")
        library.setThumbnailSizesLinked(false)
        library.setGroupThumbnailSize(160)
        library.setThumbnailSizesLinked(true)
        library.setGroupThumbnailSize(160)
        try check(library.currentProject?.thumbnailSize == 160 && library.currentProject?.groupThumbnailSize == 160,
                  "The first linked right gesture chooses the shared value")
        library.setGroupThumbnailSize(10_000)
        try check(library.currentProject?.thumbnailSize == 240 && library.currentProject?.groupThumbnailSize == 240,
                  "Either linked slider clamps both values to the supported range")
        library.setThumbnailSizesLinked(false)
        library.setThumbnailSize(72)
        library.setGroupThumbnailSize(120)
        library.setGroupThumbnailSize(.nan)
        library.setThumbnailSize(.infinity)
        try check(library.currentProject?.thumbnailSize == 72 && library.currentProject?.groupThumbnailSize == 120,
                  "Nonfinite values cannot corrupt either thumbnail setting")
        try check(library.flushPendingSaves(), "Independent thumbnail settings are saved before reopening")
        let controlsReader = ProjectLibraryStore(projectsDirectory: temporaryRoot)
        controlsReader.openProject(id: fixture.id)
        try check(controlsReader.currentProject?.thumbnailSize == 72 &&
                  controlsReader.currentProject?.groupThumbnailSize == 120 &&
                  controlsReader.currentProject?.thumbnailSizesLinked == false,
                  "A fresh store restores both independent sizes and the lock state")
        _ = controlsReader.flushPendingSaves()

        // Reordering a filtered subset leaves hidden and grouped slots in the project sequence.
        let beforeOrder = library.currentProject!.materialOrder
        library.reorderMaterials([third.id, first.id])
        try check(library.currentProject?.orderedActiveAssets.map(\.id) == [third.id, second.id, first.id, untouched.id] &&
                  library.currentProject?.materialOrder.first == removed.id,
                  "Reordering visible materials preserves hidden and removed material slots")
        let orderedGroup = library.createGroup([first.id, third.id])!
        try check(library.currentProject?.groups.last?.assetIDs == [third.id, first.id],
                  "A new group follows the grid's saved sequence instead of stale legacy coordinates")
        let groupOrder = library.currentProject!.materialOrder
        library.reorderMaterials([untouched.id, second.id])
        try check(library.currentProject?.materialOrder == [removed.id, third.id, untouched.id, first.id, second.id],
                  "Moving remaining materials does not move grouped members' return slots")
        library.reorderMaterials([first.id, second.id])
        library.reorderMaterials([second.id, second.id])
        library.reorderMaterials([UUID(), second.id])
        try check(library.currentProject?.materialOrder == [removed.id, third.id, untouched.id, first.id, second.id],
                  "Grouped, duplicate and unknown IDs cannot corrupt material order")
        library.undoLastEdit()
        try check(library.currentProject?.materialOrder == groupOrder, "Undo restores the last material reordering")
        library.dissolveGroup(orderedGroup)
        try check(library.currentProject?.orderedActiveAssets.map(\.id) == [third.id, second.id, first.id, untouched.id],
                  "Dissolving a group returns photos to their saved grid order")
        library.reorderMaterials(beforeOrder.filter { $0 != removed.id })
        try check(library.currentProject?.materialOrder == beforeOrder, "Material order can be restored without moving legacy positions")

        // Group drops commit relative to the target's current identity. Exercise
        // both directions in an isolated library, including persistence and undo.
        do {
            let reorderRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("aoistitcher-group-order-tests-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: reorderRoot) }
            let reorderAssets = (0..<9).map { index in
                ProjectAsset(id: UUID(), fileName: "group-order-\(index).png", name: "Photo \(index)",
                             position: CGPoint(x: CGFloat(index) * 160 + 24, y: 24))
            }
            let originalGroups = (0..<4).map { index in
                ProjectPhotoGroup(id: UUID(), assetIDs: [reorderAssets[index * 2 + 1].id,
                                                        reorderAssets[index * 2].id])
            }
            let a = originalGroups[0].id, b = originalGroups[1].id
            let c = originalGroups[2].id, d = originalGroups[3].id
            let reorderFixture = ProjectDocument(id: UUID(), name: "组拖动回归", createdAt: Date(), modifiedAt: Date(),
                assets: reorderAssets, exports: [], thumbnailSize: 128, groups: originalGroups,
                materialOrder: reorderAssets.reversed().map(\.id))
            let reorderDirectory = reorderRoot.appendingPathComponent(reorderFixture.id.uuidString)
            try FileManager.default.createDirectory(at: reorderDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(reorderFixture).write(to: reorderDirectory.appendingPathComponent("project.json"))
            let reorderStore = ProjectLibraryStore(projectsDirectory: reorderRoot)
            reorderStore.openProject(id: reorderFixture.id)
            try check(reorderStore.currentProject?.groups == originalGroups && !reorderStore.canUndoEdit,
                      "A four-group fixture opens with independent member and material orders and no undo history")

            let initialModifiedAt = reorderStore.currentProject?.modifiedAt
            try check(!reorderStore.moveGroup(UUID(), relativeTo: b, before: true) &&
                      !reorderStore.moveGroup(a, relativeTo: UUID(), before: false) &&
                      !reorderStore.moveGroup(a, relativeTo: a, before: true),
                      "Unknown source, unknown target and self drops are rejected")
            try check(reorderStore.currentProject?.groups == originalGroups &&
                      reorderStore.currentProject?.modifiedAt == initialModifiedAt && !reorderStore.canUndoEdit,
                      "Rejected group drops do not change the document or create undo entries")
            try check(reorderStore.moveGroup(a, relativeTo: b, before: true) &&
                      reorderStore.moveGroup(d, relativeTo: c, before: false) &&
                      reorderStore.currentProject?.groups == originalGroups && !reorderStore.canUndoEdit &&
                      reorderStore.currentProject?.modifiedAt == initialModifiedAt,
                      "Adjacent drops that preserve the current order succeed without writing or adding undo entries")

            try check(reorderStore.moveGroup(d, relativeTo: a, before: true) &&
                      reorderStore.currentProject?.groups.map(\.id) == [d, a, b, c],
                      "Dropping the last group above the first moves it to the beginning")
            try check(reorderStore.currentProject?.assets == reorderFixture.assets &&
                      reorderStore.currentProject?.materialOrder == reorderFixture.materialOrder &&
                      reorderStore.currentProject?.groups.map(\.assetIDs) == [originalGroups[3].assetIDs,
                          originalGroups[0].assetIDs, originalGroups[1].assetIDs, originalGroups[2].assetIDs],
                      "Group movement preserves member ordering, photo geometry and ungrouped return slots")
            reorderStore.undoLastEdit()
            try check(reorderStore.currentProject?.groups == originalGroups && !reorderStore.canUndoEdit,
                      "One undo restores a last-to-first drop as a single edit")

            try check(reorderStore.moveGroup(a, relativeTo: d, before: false) &&
                      reorderStore.currentProject?.groups.map(\.id) == [b, c, d, a],
                      "Dropping the first group below the last uses the target position after source removal")
            reorderStore.undoLastEdit()
            try check(reorderStore.currentProject?.groups == originalGroups && !reorderStore.canUndoEdit,
                      "One undo restores a first-to-last drop")

            try check(reorderStore.moveGroup(d, relativeTo: b, before: true) &&
                      reorderStore.currentProject?.groups.map(\.id) == [a, d, b, c],
                      "Dropping into a middle boundary inserts immediately above the named target")
            try check(reorderStore.moveGroup(d, relativeTo: b, before: true) &&
                      !reorderStore.moveGroup(d, relativeTo: d, before: false) &&
                      !reorderStore.moveGroup(d, relativeTo: UUID(), before: true) &&
                      reorderStore.currentProject?.groups.map(\.id) == [a, d, b, c],
                      "No-op and stale-target drops preserve an earlier valid move")
            reorderStore.undoLastEdit()
            try check(reorderStore.currentProject?.groups == originalGroups && !reorderStore.canUndoEdit,
                      "Rejected and adjacent no-op drops never hide the last real move behind extra undo steps")

            try check(reorderStore.moveGroup(c, relativeTo: a, before: true) &&
                      reorderStore.moveGroup(b, relativeTo: d, before: false) &&
                      reorderStore.currentProject?.groups.map(\.id) == [c, a, d, b],
                      "Consecutive drops resolve their target against the latest saved group order")
            try check(reorderStore.flushPendingSaves(), "Group drop ordering flushes successfully")
            let reorderReader = ProjectLibraryStore(projectsDirectory: reorderRoot)
            reorderReader.openProject(id: reorderFixture.id)
            try check(reorderReader.currentProject?.groups.map(\.id) == [c, a, d, b] &&
                      reorderReader.currentProject?.assets == reorderFixture.assets &&
                      reorderReader.currentProject?.materialOrder == reorderFixture.materialOrder,
                      "A fresh store restores dragged group order without changing photo membership or material order")
            reorderReader.closeProject()
            reorderStore.undoLastEdit()
            try check(reorderStore.currentProject?.groups.map(\.id) == [c, a, b, d] && reorderStore.canUndoEdit,
                      "Undo after saving restores only the most recent group drop")
            reorderStore.undoLastEdit()
            try check(reorderStore.currentProject?.groups == originalGroups &&
                      reorderStore.currentProject?.assets == reorderFixture.assets &&
                      reorderStore.currentProject?.materialOrder == reorderFixture.materialOrder && !reorderStore.canUndoEdit,
                      "Undoing all group drops restores the initial rows, members and material slots exactly")
            try check(reorderStore.flushPendingSaves(), "Undo of persisted group drops is also saved")
            reorderStore.closeProject()
            reorderStore.openProject(id: reorderFixture.id)
            try check(reorderStore.currentProject?.groups == originalGroups &&
                      reorderStore.currentProject?.materialOrder == reorderFixture.materialOrder,
                      "Reopening after undo restores the original group and material order")
            reorderStore.closeProject()
        }

        // Import completion merges with edits made while background copying is in progress.
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("aoistitcher-import-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: input) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try png.write(to: input)
        library.importURLs([input])
        let preImportOrder = library.currentProject!.materialOrder
        library.reorderMaterials([untouched.id, first.id])
        let importGroup = library.createGroup([first.id, second.id])!
        library.recordExport(exportContext, outputURL: URL(fileURLWithPath: "/tmp/during-import.png"))
        for _ in 0..<200 where library.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        try check(!library.isImporting && library.currentProject?.assets.count == fixture.assets.count + 1 &&
                  library.currentProject?.groups.last?.id == importGroup && library.currentProject?.exports.count == 3,
                  "Import completion retains concurrent group edits and successful export records (assets: \(library.currentProject?.assets.count ?? -1), exports: \(library.currentProject?.exports.count ?? -1), busy: \(library.isImporting), message: \(library.message ?? "none"))")
        library.undoLastEdit()
        try check(library.currentProject?.assets.count == fixture.assets.count + 1 && library.currentProject?.exports.count == 3 &&
                  library.currentProject?.groups.isEmpty == true,
                  "Undo of grouping retains a later imported photo and export")
        library.undoLastEdit()
        try check(library.currentProject?.materialOrder.dropLast() == preImportOrder[...] &&
                  library.currentProject?.materialOrder.last == library.currentProject?.assets.last?.id &&
                  library.currentProject?.materialOrder.count == fixture.assets.count + 1,
                  "Undo of grid order preserves the ID and position in sequence of a later import")
        try check(library.flushPendingSaves(), "All imported metadata is durable before corruption test")
        let orderReader = ProjectLibraryStore(projectsDirectory: temporaryRoot)
        orderReader.openProject(id: fixture.id)
        try check(orderReader.currentProject?.materialOrder == library.currentProject?.materialOrder &&
                  orderReader.currentProject?.orderedActiveAssets.map(\.id) == library.currentProject?.orderedActiveAssets.map(\.id),
                  "Fresh readers recover the persisted adaptive-grid order")
        _ = orderReader.flushPendingSaves()
        let beforeDamage = try Data(contentsOf: metadata)
        let damaged = Data("broken project metadata".utf8)
        try damaged.write(to: metadata)
        library.moveAssets([first.id: CGPoint(x: 11, y: 22)])
        let failedFlush = library.flushPendingSaves()
        let afterFailedSave = try Data(contentsOf: metadata)
        try check(!failedFlush && afterFailedSave == damaged && library.message != nil,
                  "A failed asynchronous save reports failure and preserves damaged metadata")
        library.closeProject()
        try check(library.currentProject != nil, "Closing after a save failure retains unsaved in-memory edits")
        let recoveryReader = ProjectLibraryStore(projectsDirectory: temporaryRoot)
        recoveryReader.openProject(id: fixture.id)
        try check(recoveryReader.currentProject?.assets.first(where: { $0.id == first.id })?.position == CGPoint(x: 11, y: 22),
                  "A new store recovers the latest unsaved snapshot without replacing damaged metadata")
        _ = recoveryReader.flushPendingSaves()
        try beforeDamage.write(to: metadata)
        try check(library.flushPendingSaves(), "Flush retries the latest in-memory snapshot after storage is repaired")

        var migrated = fixture
        let oldGroupID = UUID()
        for index in migrated.assets.indices where [first.id, second.id].contains(migrated.assets[index].id) {
            migrated.assets[index].groupID = oldGroupID
        }
        var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
        oldObject.removeValue(forKey: "groups")
        let oldGroupDocument = try decoder.decode(ProjectDocument.self, from: JSONSerialization.data(withJSONObject: oldObject))
        try check(oldGroupDocument.groups == [ProjectPhotoGroup(id: oldGroupID, assetIDs: [first.id, second.id])],
                  "Legacy on-board group flags migrate to ordered rows without moving photos")

        // These URLs are identifiers only; no files are imported or created.
        let urls = (0..<17).map { URL(fileURLWithPath: "/tmp/project-regression-\($0).png") }
        let legacyDestination = ProjectEditorBridge()
        try check(!legacyDestination.send(operation: .compression, urls: [urls[0]]) && legacyDestination.request == nil,
                  "The legacy compression history type cannot receive new project imports")
        let busy = ProjectEditorBridge()
        busy.update(operation: .freeCanvas, count: 3, signature: "canvas-a", isBusy: true)
        try check(!busy.send(operation: .freeCanvas, urls: Array(urls.prefix(2))) && busy.request == nil,
                  "A busy destination refuses a second import without changing its current draft")
        busy.update(operation: .freeCanvas, count: 3, signature: "canvas-a", isBusy: false)
        try check(busy.send(operation: .freeCanvas, urls: Array(urls.prefix(2))),
                  "The same selection can be sent once the destination is ready")
        let pendingID = try requireRequestID(busy)
        try check(!busy.send(operation: .longStitch, urls: [urls[2]]) && busy.request?.id == pendingID,
                  "A second destination cannot overwrite a request waiting to be consumed")
        busy.consume(id: UUID())
        try check(busy.request?.id == pendingID, "An unrelated consumer cannot discard a pending import")
        busy.consume(id: pendingID)
        try check(busy.send(operation: .longStitch, urls: [urls[2]]),
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
