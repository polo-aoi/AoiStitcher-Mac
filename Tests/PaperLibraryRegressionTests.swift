import AppKit
import ImageIO

@MainActor enum PaperLibraryRegressionTests {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
            guard condition() else {
                throw NSError(domain: "PaperLibraryRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: description])
            }
            checks += 1
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("paper-library-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let legacyRoot = root.appendingPathComponent("legacy")
        try manager.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacyID = UUID()
        let legacy = Data("""
        [{"id":"\(legacyID.uuidString)","fileName":"temporarily-missing.png","displayName":"旧纸张"}]
        """.utf8)
        let legacyIndex = legacyRoot.appendingPathComponent("index.json")
        try legacy.write(to: legacyIndex)
        let migrated = PaperLibraryStore(directory: legacyRoot)
        try check(migrated.items.first?.id == legacyID && migrated.items.first?.parentID == nil,
                  "Old flat paper libraries retain identities and become root-level items")
        try check(migrated.items.count == 1 && !manager.fileExists(atPath: migrated.url(for: migrated.items[0]).path),
                  "A missing image file never deletes its library record")
        let untouched = try Data(contentsOf: legacyIndex)
        try check(untouched == legacy, "Reading a legacy index does not rewrite it")
        let folder = migrated.createFolder(named: "婚礼", parentID: nil)!
        let child = migrated.createFolder(named: "绿色", parentID: folder)!
        let grandchild = migrated.createFolder(named: "肌理", parentID: child)!
        migrated.moveItem(id: legacyID, to: grandchild)
        let color = migrated.createColor(named: "苔绿", color: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.3, alpha: 1),
                                         parentID: grandchild)!
        let restored = PaperLibraryStore(directory: legacyRoot)
        try check(restored.folders.count == 3 && restored.items.first(where: { $0.id == legacyID })?.parentID == grandchild,
                  "Nested folders and existing image assignments survive reopening")
        try check(restored.items.first(where: { $0.id == color.id })?.color == color.color,
                  "Pure color papers retain their color and identity without an image file")
        restored.moveFolder(id: folder, to: grandchild)
        try check(restored.folders.first(where: { $0.id == folder })?.parentID == nil && restored.message != nil,
                  "A folder cannot move inside its own descendant")
        restored.moveFolder(id: child, to: child)
        try check(restored.folders.first(where: { $0.id == child })?.parentID == folder,
                  "A folder cannot become its own parent")
        restored.removeFolder(id: child)
        try check(restored.folders.map(\.id) == [folder] && restored.items.isEmpty,
                  "Removing a folder also removes all descendant folders and their item records")

        let ordering = PaperLibraryStore(directory: root.appendingPathComponent("ordering"))
        let firstFolder = ordering.createFolder(named: "第一", parentID: nil)!
        let secondFolder = ordering.createFolder(named: "第二", parentID: nil)!
        let thirdFolder = ordering.createFolder(named: "第三", parentID: nil)!
        let nestedFolder = ordering.createFolder(named: "子级", parentID: firstFolder)!
        try check(ordering.moveFolder(id: firstFolder, to: nil, beforeFolderID: thirdFolder)
                  && ordering.folders.filter { $0.parentID == nil }.map(\.id) == [secondFolder, firstFolder, thirdFolder],
                  "Dropping a folder before a sibling persists the requested order")
        try check(!ordering.moveFolder(id: firstFolder, to: nestedFolder)
                  && ordering.folders.first(where: { $0.id == firstFolder })?.parentID == nil,
                  "Dragging a folder into its own descendant is rejected without changing the tree")
        try check(ordering.moveFolder(id: nestedFolder, to: nil, beforeFolderID: firstFolder)
                  && ordering.folders.first(where: { $0.id == nestedFolder })?.parentID == nil
                  && ordering.folders.filter { $0.parentID == nil }.map(\.id)
                    == [secondFolder, nestedFolder, firstFolder, thirdFolder],
                  "Moving a child to the root and before a sibling makes it a peer")
        let firstItem = ordering.createColor(named: "纸一", color: .red, parentID: nil)!
        let secondItem = ordering.createColor(named: "纸二", color: .green, parentID: nil)!
        let thirdItem = ordering.createColor(named: "纸三", color: .blue, parentID: nil)!
        try check(ordering.moveItem(id: firstItem.id, to: nil, beforeItemID: thirdItem.id)
                  && ordering.items.filter { $0.parentID == nil }.map(\.id) == [secondItem.id, firstItem.id, thirdItem.id],
                  "Paper rows can be reordered among siblings")
        try check(ordering.moveItem(id: secondItem.id, to: firstFolder)
                  && ordering.items.first(where: { $0.id == secondItem.id })?.parentID == firstFolder
                  && ordering.moveItem(id: secondItem.id, to: nil, beforeItemID: firstItem.id),
                  "Dragging a paper into a folder and back to a root sibling updates its parent")
        let reopenedOrdering = PaperLibraryStore(directory: ordering.directory)
        try check(reopenedOrdering.folders.filter { $0.parentID == nil }.map(\.id)
                  == ordering.folders.filter { $0.parentID == nil }.map(\.id)
                  && reopenedOrdering.items.map(\.id) == ordering.items.map(\.id),
                  "Folder and paper insertion order survives reopening the library")

        let damagedRoot = root.appendingPathComponent("damaged")
        try manager.createDirectory(at: damagedRoot, withIntermediateDirectories: true)
        let damagedData = Data("this is not a valid index".utf8)
        let damagedIndex = damagedRoot.appendingPathComponent("index.json")
        try damagedData.write(to: damagedIndex)
        let damaged = PaperLibraryStore(directory: damagedRoot)
        try check(damaged.createFolder(named: "不要覆盖", parentID: nil) == nil,
                  "An unreadable index blocks writes that would replace existing library data")
        let preserved = try Data(contentsOf: damagedIndex)
        try check(preserved == damagedData, "Failed library reads and edits preserve the original index bytes")

        let blockedRoot = root.appendingPathComponent("blocked")
        let blocked = PaperLibraryStore(directory: blockedRoot)
        try manager.createDirectory(at: blockedRoot.appendingPathComponent("index.json"), withIntermediateDirectories: true)
        try check(blocked.createFolder(named: "保存失败", parentID: nil) == nil && blocked.folders.isEmpty,
                  "A failed atomic save does not publish unsaved folders")

        let editingRoot = root.appendingPathComponent("editing")
        let editing = PaperLibraryStore(directory: editingRoot)
        let editingFolder = editing.createFolder(named: "颜色", parentID: nil)!
        let editingColor = editing.createColor(named: "绿色", color: .green, parentID: editingFolder)!
        try check(editing.renameItem(id: editingColor.id, to: editingColor.displayName)
                  && editing.renameFolder(id: editingFolder, to: "颜色"),
                  "Saving unchanged valid names reports success")
        try check(!editing.renameItem(id: UUID(), to: "不存在")
                  && !editing.renameFolder(id: editingFolder, to: "  "),
                  "Invalid rename targets and blank names report failure")
        let editedColor = editing.updateColorPaper(id: editingColor.id, name: "蓝色", color: .blue)!
        let reopenedEditing = PaperLibraryStore(directory: editingRoot)
        try check(editedColor.displayName == "蓝色" && editedColor.color == PaperLibraryColor(.blue)
                  && reopenedEditing.items.first == editedColor,
                  "A color paper's name and color are persisted together")
        let editingIndex = editingRoot.appendingPathComponent("index.json")
        try manager.removeItem(at: editingIndex)
        try manager.createDirectory(at: editingIndex, withIntermediateDirectories: true)
        try check(editing.updateColorPaper(id: editingColor.id, name: "红色", color: .red) == nil
                  && editing.items.first == editedColor,
                  "A failed color edit preserves both the saved name and saved color")
        try check(!editing.renameItem(id: editingColor.id, to: "新名称")
                  && !editing.renameFolder(id: editingFolder, to: "新文件夹")
                  && editing.items.first == editedColor && editing.folders.first?.name == "颜色",
                  "Failed renames report failure and do not publish unsaved changes")

        let sourceRoot = root.appendingPathComponent("sources")
        let nested = sourceRoot.appendingPathComponent("绿色/纤维")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<3 {
            for x in 0..<2 { bitmap.setColor(.clear, atX: x, y: y) }
        }
        bitmap.setColor(.green, atX: 0, y: 0)
        bitmap.setColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5), atX: 0, y: 1)
        let imageData = bitmap.representation(using: .png, properties: [:])!
        let original = nested.appendingPathComponent("纹理.png")
        try imageData.write(to: original)
        try imageData.write(to: nested.appendingPathComponent(".隐藏.png"))
        try Data("ignore".utf8).write(to: nested.appendingPathComponent("说明.txt"))
        try manager.createSymbolicLink(at: nested.appendingPathComponent("链接.png"), withDestinationURL: original)
        let imported = PaperLibraryStore(directory: root.appendingPathComponent("imported"))
        imported.importURLs([sourceRoot, original])
        let deadline = Date().addingTimeInterval(10)
        while imported.isImporting && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(!imported.isImporting, "Background paper import completes")
        try check(imported.items.count == 1 && imported.folders.count == 3,
                  "Folder imports retain nesting while skipping hidden files, symlinks, non-images and duplicate input paths")
        let importedItem = imported.items[0]
        let copiedData = try Data(contentsOf: imported.url(for: importedItem))
        let sourceData = try Data(contentsOf: original)
        try check(copiedData == imageData && sourceData == imageData,
                  "Import copies original image bytes without recompression or modifying the source")
        let importedParent = imported.folders.first(where: { $0.id == importedItem.parentID })
        try check(importedParent?.name == "纤维", "Imported papers belong to their original nested folder")

        let crop = bitmap.cgImage!.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 2))!
        let replaced = try await imported.saveCroppedImage(crop, for: importedItem, asNew: false)
        try check(replaced.id == importedItem.id && replaced.displayName == importedItem.displayName
                  && replaced.parentID == importedItem.parentID && replaced.fileName != importedItem.fileName
                  && imported.items.count == 1 && imported.items.first == replaced,
                  "Replacing a paper keeps its identity, name and folder while switching to a new image file")
        let croppedURL = imported.url(for: replaced)
        let croppedSource = CGImageSourceCreateWithURL(croppedURL as CFURL, nil)!
        let croppedImage = CGImageSourceCreateImageAtIndex(croppedSource, 0, nil)!
        try check(CGImageSourceGetType(croppedSource) as String? == "public.png"
                  && croppedImage.width == 1 && croppedImage.height == 2,
                  "A permanent crop is a PNG with the actual cropped pixel dimensions")
        let inputPixels = NSBitmapImageRep(cgImage: crop)
        let savedPixels = NSBitmapImageRep(cgImage: croppedImage)
        try check((0..<2).allSatisfy {
            abs(inputPixels.colorAt(x: 0, y: $0)!.alphaComponent - savedPixels.colorAt(x: 0, y: $0)!.alphaComponent) < 0.01
        } && (0..<2).contains { savedPixels.colorAt(x: 0, y: $0)!.alphaComponent < 0.75 },
                  "PNG crop persistence retains partial transparency instead of flattening the image")
        let originalAfterCrop = try Data(contentsOf: original)
        try check(!manager.fileExists(atPath: imported.url(for: importedItem).path) && originalAfterCrop == sourceData,
                  "A committed crop deletes the old managed copy and never changes the source image")
        try check(!imported.isSavingCrop && !imported.isBusy && imported.message == nil,
                  "Successful crop saves release the busy gate without posting a library alert")

        let newCrop = try await imported.saveCroppedImage(crop, for: replaced, asNew: true)
        let reopenedCrops = PaperLibraryStore(directory: imported.directory)
        try check(newCrop.id != replaced.id && newCrop.displayName == replaced.displayName + " 裁剪"
                  && newCrop.parentID == replaced.parentID && newCrop.fileName != replaced.fileName
                  && reopenedCrops.items.count == 2 && reopenedCrops.items.contains(replaced)
                  && reopenedCrops.items.contains(newCrop) && manager.fileExists(atPath: croppedURL.path),
                  "Saving a crop as a new paper persists it beside the original and keeps the original file")
        for asNew in [false, true] {
            var rejectedStaleCrop = false
            do { _ = try await imported.saveCroppedImage(crop, for: importedItem, asNew: asNew) }
            catch { rejectedStaleCrop = true }
            try check(rejectedStaleCrop && imported.items.count == 2 && imported.items.contains(replaced),
                      "An outdated crop cannot overwrite or duplicate a paper whose image has already changed")
        }

        let cropIndex = imported.directory.appendingPathComponent("index.json")
        let indexBeforeFailure = try Data(contentsOf: cropIndex)
        let pixelsBeforeFailure = try Data(contentsOf: croppedURL)
        try manager.removeItem(at: cropIndex)
        try manager.createDirectory(at: cropIndex, withIntermediateDirectories: true)
        let filesBeforeFailure = try manager.contentsOfDirectory(atPath: imported.directory.path).sorted()
        var rejectedFailedSave = false
        do { _ = try await imported.saveCroppedImage(crop, for: replaced, asNew: false) }
        catch { rejectedFailedSave = true }
        let filesAfterFailure = try manager.contentsOfDirectory(atPath: imported.directory.path).sorted()
        let pixelsAfterFailure = try Data(contentsOf: croppedURL)
        try check(rejectedFailedSave && imported.items.count == 2 && imported.items.contains(replaced)
                  && pixelsAfterFailure == pixelsBeforeFailure && filesAfterFailure == filesBeforeFailure,
                  "An index save failure rolls back the new PNG while keeping the previous record and image bytes")
        try check(!imported.isSavingCrop && !imported.isBusy && imported.message == nil,
                  "A failed crop save releases the busy gate and reports only through its thrown error")
        try manager.removeItem(at: cropIndex)
        try indexBeforeFailure.write(to: cropIndex, options: .atomic)
        imported.removeItem(id: newCrop.id)
        var rejectedRemovedCrop = false
        do { _ = try await imported.saveCroppedImage(crop, for: newCrop, asNew: true) }
        catch { rejectedRemovedCrop = true }
        try check(rejectedRemovedCrop && imported.items == [replaced],
                  "A crop whose source paper was removed cannot recreate that stale item")

        imported.removeFolder(id: imported.folders.first(where: { $0.name == "sources" })!.id)
        try check(manager.fileExists(atPath: original.path) && !manager.fileExists(atPath: croppedURL.path),
                  "Removing an imported folder deletes only managed copies and preserves source images")
        return checks
    }
}
