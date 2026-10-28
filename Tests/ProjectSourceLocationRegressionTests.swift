import Foundation

/// Uses disposable source folders and metadata; never launches Finder or touches the user's library.
@MainActor enum ProjectSourceLocationRegressionTests {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectSourceLocationRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("aoi-source-locations-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let source = root.appendingPathComponent("婚礼原片", isDirectory: true)
        let nested = source.appendingPathComponent("第二天", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let firstPhoto = nested.appendingPathComponent("first.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try png.write(to: firstPhoto)

        let library = ProjectLibraryStore(projectsDirectory: projects)
        try check(library.createProject(importing: [source]), "A folder creates a project from its original location")
        try await waitForImport(in: library)
        guard let project = library.currentProject, let imported = project.assets.first else {
            throw failure("The folder import did not create its photo asset")
        }
        let projectDirectory = projects.appendingPathComponent(project.id.uuidString, isDirectory: true)
        let firstLocations = try library.sourceDirectoriesForProject(id: project.id)
        try check(project.name == source.lastPathComponent && project.sourceDirectoryPaths == [canonicalPath(source)],
                  "A folder import remembers the selected top-level folder even when every photo is in a subfolder")
        try check(firstLocations.map(canonicalPath) == [canonicalPath(source)],
                  "Finder targets the selected source folder rather than its photo subfolder or internal metadata")
        try check(imported.isReference && canonicalPath(library.assetURL(imported)) == canonicalPath(firstPhoto),
                  "An imported asset reads the original at its unchanged path")
        let originalBytes = try Data(contentsOf: firstPhoto)
        try check(originalBytes == png, "Importing leaves the original file byte-for-byte unchanged")
        try check(!manager.fileExists(atPath: projectDirectory.appendingPathComponent("Originals").path),
                  "A new reference-only project does not create an Originals folder")
        try check(library.flushPendingSaves(), "The imported folder location is saved successfully")

        library.closeProject()
        let reader = ProjectLibraryStore(projectsDirectory: projects)
        reader.openProject(id: project.id)
        let reopenedLocations = try reader.sourceDirectoriesForProject(id: project.id)
        try check(reader.currentProject?.sourceDirectoryPaths == [canonicalPath(source)] &&
                  reopenedLocations.map(canonicalPath) == [canonicalPath(source)],
                  "A fresh store retains the original folder for the home context menu")

        guard let cover = reader.projects.first(where: { $0.id == project.id })?.coverAssets.first else {
            throw failure("The imported project has no cover asset")
        }
        let coverImage = await reader.requestCoverThumbnail(projectID: project.id, asset: cover)
        try check(coverImage != nil, "The home cover can still be generated from the source photo")
        let visibleProjectFiles = try manager.contentsOfDirectory(at: projectDirectory, includingPropertiesForKeys: nil)
        try check(!visibleProjectFiles.contains { $0.pathExtension.lowercased() == "png" },
                  "Cover previews never appear as loose image files beside project.json")
        let cache = projectDirectory.appendingPathComponent(".thumbnails/v2", isDirectory: true)
        let cachedFiles = try manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        try check(cachedFiles.contains { $0.pathExtension == "png" },
                  "The home cover is stored with the hidden disposable thumbnail cache")

        let additional = root.appendingPathComponent("其他原片", isDirectory: true)
        try manager.createDirectory(at: additional, withIntermediateDirectories: true)
        let secondPhoto = additional.appendingPathComponent("second.png")
        try png.write(to: secondPhoto)
        reader.importURLs([secondPhoto])
        try await waitForImport(in: reader)
        let multipleLocations = try reader.sourceDirectoriesForProject(id: project.id)
        try check(multipleLocations.map(canonicalPath) == [canonicalPath(source), canonicalPath(additional)],
                  "A later single-file import adds its parent folder in stable import order")
        try check(reader.currentProject?.assets.count == 2 && reader.currentProject?.assets.allSatisfy(\.isReference) == true,
                  "Appending from another folder keeps every asset as a reference")

        let cancelledFolder = root.appendingPathComponent("取消导入", isDirectory: true)
        try manager.createDirectory(at: cancelledFolder, withIntermediateDirectories: true)
        let cancelledPhoto = cancelledFolder.appendingPathComponent(secondPhoto.lastPathComponent)
        try png.write(to: cancelledPhoto)
        reader.importURLs([cancelledPhoto])
        try await waitForDuplicate(in: reader)
        reader.cancelDuplicateImport()
        let afterCancellation = try reader.sourceDirectoriesForProject(id: project.id)
        try check(afterCancellation.map(canonicalPath) == multipleLocations.map(canonicalPath),
                  "Cancelling a duplicate import does not register an unrelated source folder")

        let movedSource = root.appendingPathComponent("原片新位置", isDirectory: true)
        try manager.moveItem(at: source, to: movedSource)
        let beforeRepair = try reader.sourceDirectoriesForProject(id: project.id)
        try check(beforeRepair.map(canonicalPath) == [canonicalPath(additional)],
                  "Missing source directories are omitted instead of exposing an internal project folder")
        let repaired = reader.repairProject(id: project.id, locatingIn: movedSource)
        let repairedLocations = try reader.sourceDirectoriesForProject(id: project.id)
        try check(repaired == 1 && Set(repairedLocations.map(canonicalPath)) == Set([canonicalPath(additional), canonicalPath(movedSource)]),
                  "Repair reconnects the photo and makes Finder show the chosen new source folder")
        let repairedPhoto = movedSource.appendingPathComponent("第二天/first.png")
        let repairedBytes = try Data(contentsOf: repairedPhoto)
        let secondBytes = try Data(contentsOf: secondPhoto)
        try check(repairedBytes == png && secondBytes == png,
                  "Repair and further imports preserve every original photo")
        reader.closeProject()
        let repairedReader = ProjectLibraryStore(projectsDirectory: projects)
        repairedReader.openProject(id: project.id)
        let savedRepairLocations = try repairedReader.sourceDirectoriesForProject(id: project.id)
        try check(Set(savedRepairLocations.map(canonicalPath)) == Set(repairedLocations.map(canonicalPath)),
                  "The repaired source folder survives closing and reopening the project")

        // Omit the new field explicitly to exercise old copy-mode metadata.
        let legacySource = root.appendingPathComponent("旧项目原片", isDirectory: true)
        try manager.createDirectory(at: legacySource, withIntermediateDirectories: true)
        let legacyPhoto = legacySource.appendingPathComponent("legacy.png")
        try png.write(to: legacyPhoto)
        let legacyID = UUID()
        let legacyDirectory = projects.appendingPathComponent(legacyID.uuidString, isDirectory: true)
        let originals = legacyDirectory.appendingPathComponent("Originals", isDirectory: true)
        try manager.createDirectory(at: originals, withIntermediateDirectories: true)
        let storedCopy = originals.appendingPathComponent("legacy-copy.png")
        try png.write(to: storedCopy)
        let internalCopy = originals.appendingPathComponent("internal.png")
        try png.write(to: internalCopy)
        let legacyAsset = ProjectAsset(id: UUID(), fileName: storedCopy.lastPathComponent, name: legacyPhoto.lastPathComponent,
                                       sourcePath: legacyPhoto.path, position: CGPoint(x: 20, y: 40))
        let internalAsset = ProjectAsset(id: UUID(), fileName: internalCopy.lastPathComponent, name: "internal.png",
                                         sourcePath: internalCopy.path, position: CGPoint(x: 200, y: 40))
        let noSourceAsset = ProjectAsset(id: UUID(), fileName: "unknown.png", name: "unknown.png",
                                         position: CGPoint(x: 400, y: 40))
        let history = ProjectExportRecord(id: UUID(), operation: .freeCanvas, assetIDs: [legacyAsset.id],
                                          createdAt: Date(), outputPath: root.appendingPathComponent("export.png").path)
        let legacyDocument = ProjectDocument(id: legacyID, name: "旧复制项目", createdAt: Date(), modifiedAt: Date(),
                                             assets: [legacyAsset, internalAsset, noSourceAsset], exports: [history], thumbnailSize: 128)
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyDocument)) as! [String: Any]
        legacyObject.removeValue(forKey: "sourceDirectoryPaths")
        let legacyMetadata = legacyDirectory.appendingPathComponent("project.json")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacyMetadata)
        let decodedLegacy = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: legacyMetadata))
        try check(decodedLegacy.sourceDirectoryPaths.isEmpty,
                  "Old project metadata without source directories remains readable")
        let legacyLibrary = ProjectLibraryStore(projectsDirectory: projects)
        legacyLibrary.openProject(id: legacyID)
        let legacyLocations = try legacyLibrary.sourceDirectoriesForProject(id: legacyID)
        try check(legacyLocations.map(canonicalPath) == [canonicalPath(legacySource)],
                  "Old projects recover their source folder while excluding copies inside the internal project library")
        try check(canonicalPath(legacyLibrary.assetURL(legacyAsset)) == canonicalPath(storedCopy),
                  "Existing copy-mode projects can still read their stored photos before replacement")

        let replacementFolder = root.appendingPathComponent("替换原片", isDirectory: true)
        try manager.createDirectory(at: replacementFolder, withIntermediateDirectories: true)
        let replacement = replacementFolder.appendingPathComponent(legacyPhoto.lastPathComponent)
        let replacementBytes = png + Data("replacement-source".utf8)
        try replacementBytes.write(to: replacement)
        legacyLibrary.importURLs([replacement])
        try await waitForDuplicate(in: legacyLibrary)
        legacyLibrary.resolveDuplicateImport(.overwrite)
        try await waitForImport(in: legacyLibrary)
        guard let updated = legacyLibrary.currentProject?.assets.first(where: { $0.id == legacyAsset.id }) else {
            throw failure("The legacy asset disappeared during replacement")
        }
        try check(updated.isReference && canonicalPath(legacyLibrary.assetURL(updated)) == canonicalPath(replacement),
                  "Replacing a legacy copy reconnects it to the incoming original without making a new copy")
        try check(updated.id == legacyAsset.id && updated.fileName == legacyAsset.fileName &&
                  updated.position == legacyAsset.position && legacyLibrary.currentProject?.exports.first?.id == history.id,
                  "Converting a legacy asset retains its identity, placement and export history")
        let retainedCopyBytes = try Data(contentsOf: storedCopy)
        let retainedLegacySourceBytes = try Data(contentsOf: legacyPhoto)
        let retainedReplacementBytes = try Data(contentsOf: replacement)
        try check(retainedCopyBytes == png && retainedLegacySourceBytes == png && retainedReplacementBytes == replacementBytes,
                  "Replacing a legacy asset leaves the old copy and both source files unchanged")
        try check(legacyLibrary.flushPendingSaves(), "The legacy asset's reference conversion is saved successfully")
        legacyLibrary.closeProject()
        let legacyReader = ProjectLibraryStore(projectsDirectory: projects)
        legacyReader.openProject(id: legacyID)
        try check(legacyReader.currentProject?.assets.first?.isReference == true &&
                  legacyReader.currentProject?.assets.first?.sourcePath == canonicalPath(replacement),
                  "A reopened legacy project continues reading the replacement from its original location")

        let empty = ProjectLibraryStore(projectsDirectory: projects)
        try check(empty.createProject(name: "空项目"), "An empty project can be created without an original folder")
        let emptyID = empty.currentProject!.id
        let emptyLocations = try empty.sourceDirectoriesForProject(id: emptyID)
        try check(emptyLocations.isEmpty, "An empty project never falls back to revealing its internal metadata directory")
        empty.revealProjectInFinder(id: emptyID)
        try check(empty.message == "项目尚未导入照片，暂无原始位置可显示。",
                  "Revealing an empty project explains that no photos have been imported")

        try manager.moveItem(at: movedSource, to: root.appendingPathComponent("原片再次移走", isDirectory: true))
        try manager.moveItem(at: additional, to: root.appendingPathComponent("其他原片已移走", isDirectory: true))
        guard try repairedReader.sourceDirectoriesForProject(id: project.id).isEmpty else {
            throw failure("The missing-reference fixture must have no Finder targets")
        }
        repairedReader.revealProjectInFinder(id: project.id)
        try check(repairedReader.message == "找不到项目的原始照片位置，请使用「修复项目」重新连接。",
                  "Missing reference folders direct the user to repair rather than launching Finder")

        let orphanID = UUID()
        let orphanDirectory = projects.appendingPathComponent(orphanID.uuidString, isDirectory: true)
        let orphanOriginals = orphanDirectory.appendingPathComponent("Originals", isDirectory: true)
        try manager.createDirectory(at: orphanOriginals, withIntermediateDirectories: true)
        let orphanCopy = orphanOriginals.appendingPathComponent(noSourceAsset.fileName)
        try png.write(to: orphanCopy)
        let orphanDocument = ProjectDocument(id: orphanID, name: "未记录来源的旧复制项目", createdAt: Date(), modifiedAt: Date(),
                                             assets: [noSourceAsset], exports: [], thumbnailSize: 128)
        try JSONEncoder().encode(orphanDocument).write(to: orphanDirectory.appendingPathComponent("project.json"))
        let orphanLibrary = ProjectLibraryStore(projectsDirectory: projects)
        orphanLibrary.openProject(id: orphanID)
        guard try orphanLibrary.sourceDirectoriesForProject(id: orphanID).isEmpty else {
            throw failure("The old-copy fixture must have no Finder targets")
        }
        orphanLibrary.revealProjectInFinder(id: orphanID)
        let readableCopy = try Data(contentsOf: orphanLibrary.assetURL(noSourceAsset))
        try check(orphanLibrary.message == "找不到项目记录的原始照片位置。请重新导入原照片，并选择「替换项目素材」重新连接。" &&
                  readableCopy == png,
                  "An old copy with no recorded source stays readable and explains how to reconnect by replacing project materials")
        return checks
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ProjectSourceLocationRegressionTests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func waitForImport(in library: ProjectLibraryStore) async throws {
        for _ in 0..<200 where library.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        guard !library.isImporting, library.duplicateImportRequest == nil else {
            throw failure("Timed out importing source photos: \(library.message ?? "no message")")
        }
    }

    private static func waitForDuplicate(in library: ProjectLibraryStore) async throws {
        for _ in 0..<200 where library.duplicateImportRequest == nil && library.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard library.duplicateImportRequest != nil else {
            throw failure("The duplicate import did not request a replacement decision")
        }
    }
}
