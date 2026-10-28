import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads generated originals and disposable caches; never opens a window or the user's library.
@MainActor enum ProjectThumbnailCacheRegressionTests {
    private final class WeakLibrary {
        weak var value: ProjectLibraryStore?
        init(_ value: ProjectLibraryStore) { self.value = value }
    }

    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectThumbnailCacheRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aoi-thumbnail-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.png")
        let cache = root.appendingPathComponent("previews", isDirectory: true)
        let id = UUID()
        try writeOriginal(to: original, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let originalBytes = try Data(contentsOf: original)

        let initial = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                     assetID: id, contentRevision: nil)
        try check(initial?.source == .original, "The first preview is decoded from the original")
        try check(initial?.image.width == 192 && initial?.image.height == 96,
                  "Large originals produce a 192-pixel preview while keeping aspect ratio")
        try check(initial.map { isColor($0.image, red: true) } == true,
                  "The decoded preview contains the original's image pixels")
        let bytesAfterPreview = try Data(contentsOf: original)
        try check(bytesAfterPreview == originalBytes, "Generating a preview never changes the original")
        var originalReads = 0
        let cached = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                    assetID: id, contentRevision: nil) { _ in
            originalReads += 1
            return nil
        }
        try check(cached?.source == .disk && originalReads == 0,
                  "Opening the same image again loads the small file without decoding the original")
        try check(cached.map { isColor($0.image, red: true) } == true,
                  "The persistent cache keeps real preview pixels")

        let cacheFiles = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        try check(cacheFiles.count == 1, "A preview is stored in one reusable cache file")
        try Data("not-an-image".utf8).write(to: cacheFiles[0])
        let recovered = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                       assetID: id, contentRevision: nil)
        try check(recovered?.source == .original && recovered.map { isColor($0.image, red: true) } == true,
                  "A corrupted disposable preview is rebuilt from the original")

        let medium = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                    assetID: id, contentRevision: nil, maximumPixelSize: 256)
        try check(medium?.source == .original && medium?.image.width == 384 && medium?.image.height == 192,
                  "A Retina request generates a sharper 384-pixel tier without reusing the 192-pixel file")
        let large = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                   assetID: id, contentRevision: nil, maximumPixelSize: 480)
        try check(large?.source == .original && large?.image.width == 512 && large?.image.height == 256,
                  "Large thumbnails have enough pixels for a 240-point Retina display")
        for request in [193, 300, 384] {
            let reused = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                        assetID: id, contentRevision: nil,
                                                        maximumPixelSize: request) { _ in
                originalReads += 1
                return nil
            }
            try check(reused?.source == .disk && reused?.image.width == 384 && originalReads == 0,
                      "Nearby \(request)-pixel requests reuse one decoded disk tier")
        }
        let capped = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                    assetID: id, contentRevision: nil, maximumPixelSize: 8_000)
        try check(capped?.source == .disk && capped?.image.width == 512,
                  "Oversized browsing requests remain capped at 512 pixels")
        let tierFiles = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        try check(tierFiles.count == 3, "Slider changes create only the three reusable cache tiers")

        let landscapeOriginal = root.appendingPathComponent("landscape.png")
        let portraitOriginal = root.appendingPathComponent("portrait.png")
        let rotatedOriginal = root.appendingPathComponent("rotated.tiff")
        let smallOriginal = root.appendingPathComponent("small.png")
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        try writeOriginal(to: landscapeOriginal, color: red, width: 3240, height: 2160)
        try writeOriginal(to: portraitOriginal, color: red, width: 2160, height: 3240)
        try writeOriginal(to: rotatedOriginal, color: red, width: 3240, height: 2160,
                          orientation: 6, fileType: .tiff)
        try writeOriginal(to: smallOriginal, color: red, width: 640, height: 480)
        let detailID = UUID()
        let landscape = ProjectThumbnailDiskCache.load(sourceURL: landscapeOriginal, cacheDirectory: cache,
                                                        assetID: detailID, contentRevision: nil, resolution: .detail1080)
        try check(landscape?.image.width == 1620 && landscape?.image.height == 1080,
                  "The detail tier uses a 1080-pixel short edge for 3:2 landscape photos")
        let portrait = ProjectThumbnailDiskCache.load(sourceURL: portraitOriginal, cacheDirectory: cache,
                                                       assetID: UUID(), contentRevision: nil, resolution: .detail1080)
        try check(portrait?.image.width == 1080 && portrait?.image.height == 1620,
                  "Portrait detail previews retain the same 1080-pixel short edge")
        let rotated = ProjectThumbnailDiskCache.load(sourceURL: rotatedOriginal, cacheDirectory: cache,
                                                      assetID: UUID(), contentRevision: nil, resolution: .detail1080)
        try check(rotated?.image.width == 1080 && rotated?.image.height == 1620,
                  "Detail previews apply image orientation while preserving the short-edge target")
        let small = ProjectThumbnailDiskCache.load(sourceURL: smallOriginal, cacheDirectory: cache,
                                                    assetID: UUID(), contentRevision: nil, resolution: .detail1080)
        try check(small?.image.width == 640 && small?.image.height == 480,
                  "Small originals remain at their native dimensions instead of being upscaled")
        let detailDisk = ProjectThumbnailDiskCache.load(sourceURL: landscapeOriginal, cacheDirectory: cache,
                                                         assetID: detailID, contentRevision: nil,
                                                         resolution: .detail1080) { _ in
            originalReads += 1
            return nil
        }
        try check(detailDisk?.source == .disk && detailDisk?.image.width == 1620 && originalReads == 0,
                  "Reopening a detailed preview reuses its independent 1080short disk cache")
        let detailReplacement = ProjectThumbnailDiskCache.load(sourceURL: landscapeOriginal, cacheDirectory: cache,
                                                                assetID: detailID, contentRevision: UUID(),
                                                                resolution: .detail1080)
        try check(detailReplacement?.source == .original,
                  "A replacement revision also invalidates the short-edge detail cache")

        // A replacement may preserve the name, size, and timestamp. The explicit
        // revision must invalidate it even when filesystem metadata is unchanged.
        let revision = UUID()
        let replacement = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                         assetID: id, contentRevision: revision)
        try check(replacement?.source == .original,
                  "A new content revision bypasses the prior preview even with unchanged file metadata")
        let sameRevision = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                          assetID: id, contentRevision: revision)
        try check(sameRevision?.source == .disk, "Repeated reads of the replacement reuse its new cache")
        let revisedLarge = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                          assetID: id, contentRevision: revision, maximumPixelSize: 480)
        try check(revisedLarge?.source == .original && revisedLarge?.image.width == 512,
                  "Replacing an image invalidates high-resolution tiers as well as the small preview")
        try writeOriginal(to: original, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567)], ofItemAtPath: original.path)
        let externalChange = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: cache,
                                                           assetID: id, contentRevision: revision)
        try check(externalChange?.source == .original && externalChange.map { isColor($0.image, red: false) } == true,
                  "Changes to the original's metadata invalidate the old disk preview")

        let blockedCache = root.appendingPathComponent("file-instead-of-cache-directory")
        try Data().write(to: blockedCache)
        let withoutDisk = ProjectThumbnailDiskCache.load(sourceURL: original, cacheDirectory: blockedCache,
                                                         assetID: id, contentRevision: revision)
        try check(withoutDisk?.source == .original && withoutDisk?.image.width == 192,
                  "A cache write failure does not prevent displaying the decoded image")

        let asset = ProjectAsset(id: UUID(), fileName: "image.png", name: "image.png", position: .zero)
        let smallAsset = ProjectAsset(id: UUID(), fileName: "small.png", name: "small.png", position: CGPoint(x: 200, y: 0))
        let detailAsset = ProjectAsset(id: UUID(), fileName: "detail.png", name: "detail.png", position: CGPoint(x: 400, y: 0))
        let project = ProjectDocument(id: UUID(), name: "Previews", createdAt: Date(), modifiedAt: Date(),
                                      assets: [asset, smallAsset, detailAsset], exports: [], thumbnailSize: 128)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projects.appendingPathComponent(project.id.uuidString)
        let originals = projectDirectory.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try originalBytes.write(to: originals.appendingPathComponent(asset.fileName))
        try FileManager.default.copyItem(at: smallOriginal, to: originals.appendingPathComponent(smallAsset.fileName))
        try FileManager.default.copyItem(at: landscapeOriginal, to: originals.appendingPathComponent(detailAsset.fileName))
        try JSONEncoder().encode(project).write(to: projectDirectory.appendingPathComponent("project.json"))

        let controlledQueue = OperationQueue()
        controlledQueue.isSuspended = true
        defer { controlledQueue.isSuspended = false }
        let queuedLibrary = ProjectLibraryStore(projectsDirectory: projects, thumbnailQueue: controlledQueue)
        queuedLibrary.openProject(id: project.id)
        let firstOwner = UUID(), secondOwner = UUID()
        queuedLibrary.updateThumbnailDemand(owner: firstOwner, assetIDs: [asset.id])
        _ = queuedLibrary.thumbnail(for: asset, priority: .veryLow, owner: firstOwner)
        guard let prefetched = controlledQueue.operations.first else {
            throw NSError(domain: "ProjectThumbnailCacheRegressionTests", code: 6)
        }
        try check(prefetched.queuePriority == .veryLow, "Adjacent offscreen images enter the queue at low priority")
        queuedLibrary.updateThumbnailDemand(owner: secondOwner, assetIDs: [asset.id])
        _ = queuedLibrary.thumbnail(for: asset, owner: secondOwner)
        try check(controlledQueue.operationCount == 1 && prefetched.queuePriority == .normal,
                  "A prefetched image becoming visible promotes its existing task without duplicate decoding")
        queuedLibrary.releaseThumbnailDemand(owner: firstOwner)
        try check(!prefetched.isCancelled, "A row disappearing does not cancel a preview another view still needs")
        queuedLibrary.updateThumbnailDemand(owner: secondOwner, assetIDs: [])
        try check(prefetched.isCancelled, "Scrolling away cancels queued work no remaining view needs")
        queuedLibrary.updateThumbnailDemand(owner: secondOwner, assetIDs: [asset.id])
        _ = queuedLibrary.thumbnail(for: asset, owner: secondOwner)
        let renewed = controlledQueue.operations.first { !$0.isCancelled }
        try check(renewed != nil && renewed !== prefetched,
                  "Returning to a cancelled preview creates a fresh task instead of leaving the cell empty")
        queuedLibrary.releaseThumbnailDemand(owner: secondOwner)
        try check(renewed?.isCancelled == true, "Releasing the last view cancels its pending work")
        _ = queuedLibrary.thumbnail(for: asset)
        let unscoped = controlledQueue.operations.first { !$0.isCancelled }
        queuedLibrary.updateThumbnailDemand(owner: firstOwner, assetIDs: [])
        try check(unscoped != nil && unscoped?.isCancelled == false,
                  "Viewport cleanup preserves requests made outside the scrolling view lifecycle")
        controlledQueue.isSuspended = false
        _ = try await waitForPreview(in: queuedLibrary, asset: asset)
        // Remove the preceding test's disposable cache so cache-only reads below
        // can prove that they never queue work themselves.
        try FileManager.default.removeItem(at: projectDirectory.appendingPathComponent(".thumbnails"))

        let library = ProjectLibraryStore(projectsDirectory: projects)
        library.openProject(id: project.id)
        try check(library.cachedThumbnail(for: asset, maximumPixelSize: 480) == nil,
                  "A cache-only read reports a miss without starting a preview")
        try await Task.sleep(for: .milliseconds(60))
        try check(!FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent(".thumbnails").path),
                  "Scrolling can inspect the memory cache without queuing disk reads or decodes")
        let memoryImage = try await waitForPreview(in: library, asset: asset)
        try check(memoryImage.size.width == 192 && memoryImage.size.height == 96,
                  "The library uses the small preview for its first visible request")
        for size in [48, 64, 128, 192] {
            try check(library.thumbnail(for: asset, maximumPixelSize: size) === memoryImage,
                      "A \(size)-pixel request reuses the small tier without another task")
        }
        try check(library.isThumbnail(memoryImage, sufficientForDisplayPixelSize: 128),
                  "A small grid cell is satisfied by the 192-pixel browsing tier")
        try check(!library.isThumbnail(memoryImage, sufficientForDisplayPixelSize: 256),
                  "A default Retina grid cell requests a sharper preview")
        try check(library.displayThumbnail(for: asset, pixelSize: 256) === memoryImage,
                  "The old thumbnail remains visible while its sharper replacement is loading")
        let mediumImage = try await waitForPreview(in: library, asset: asset, maximumPixelSize: 256)
        try check(mediumImage !== memoryImage && mediumImage.size.width == 384,
                  "The library upgrades a visible Retina thumbnail to the next tier")
        try check(library.isThumbnail(mediumImage, sufficientForDisplayPixelSize: 256) &&
                  library.displayThumbnail(for: asset, pixelSize: 256) === mediumImage,
                  "A 128-point Retina cell is complete at 384 pixels, without a needless 1080 detail decode")
        try check(library.thumbnail(for: asset, maximumPixelSize: 480) === mediumImage,
                  "Enlarging an already loaded thumbnail never returns an empty placeholder")
        let largeImage = try await waitForPreview(in: library, asset: asset, maximumPixelSize: 480)
        try check(largeImage.size.width == 512 && largeImage.size.height == 256,
                  "The library supplies a 512-pixel preview for the largest Retina thumbnail")
        try check(library.cachedThumbnail(for: asset, maximumPixelSize: 192) === largeImage &&
                  library.thumbnail(for: asset, maximumPixelSize: 128) === largeImage,
                  "Small or late requests never downgrade a high-resolution preview")
        try check(!library.isDetailedThumbnail(largeImage),
                  "A 512-pixel browsing tier does not masquerade as a completed detail preview")
        try check(!library.isThumbnail(largeImage, sufficientForDisplayPixelSize: 480),
                  "A 240-point Retina cell includes a clarity margin beyond the 512-pixel tier")
        try check(library.displayThumbnail(for: asset, pixelSize: 480) === largeImage,
                  "The largest Retina grid cell keeps its existing thumbnail while requesting detail")
        let detailImage = try await waitForDetailedPreview(in: library, asset: asset)
        try check(detailImage.size == CGSize(width: 1600, height: 800),
                  "A source below the detail short-edge target is kept at its original size")
        try check(library.cachedThumbnail(for: asset) === detailImage &&
                  library.thumbnail(for: asset, maximumPixelSize: 480) === detailImage,
                  "The completed detail tier outranks every browsing resolution in memory")
        try check(library.isThumbnail(detailImage, sufficientForDisplayPixelSize: 480),
                  "The detail tier satisfies the largest grid display demand")
        let landscapeImage = try await waitForDetailedPreview(in: library, asset: detailAsset)
        try check(landscapeImage.size == CGSize(width: 1620, height: 1080) && library.isDetailedThumbnail(landscapeImage),
                  "The library's detail API returns 1620×1080 for a landscape photograph")
        let smallImage = try await waitForDetailedPreview(in: library, asset: smallAsset)
        try check(smallImage.size == CGSize(width: 640, height: 480) && library.isDetailedThumbnail(smallImage),
                  "A 640-pixel original is explicitly marked complete, avoiding repeated upgrade attempts")
        try check(library.detailedThumbnail(for: smallAsset) === smallImage,
                  "Repeated detail requests reuse the completed small original")
        try check(library.isThumbnail(smallImage, sufficientForDisplayPixelSize: 480),
                  "A small original's completion metadata prevents repeated display upgrades")

        var temporaryOwner: ProjectLibraryStore? = ProjectLibraryStore(projectsDirectory: projects)
        temporaryOwner!.openProject(id: project.id)
        let retainedDetail = try await waitForDetailedPreview(in: temporaryOwner!, asset: smallAsset)
        let weakOwner = WeakLibrary(temporaryOwner!)
        temporaryOwner = nil
        try check(weakOwner.value == nil && library.isDetailedThumbnail(retainedDetail) &&
                  library.isThumbnail(retainedDetail, sufficientForDisplayPixelSize: 480),
                  "Resolution metadata survives the owning memory cache's destruction while a view retains the image")
        library.closeProject()
        library.openProject(id: project.id)
        try check(library.thumbnail(for: asset) === detailImage,
                  "Returning to a project keeps its sharpest in-memory preview ready immediately")
        library.moveAssets([asset.id: CGPoint(x: 250, y: 180)])
        try check(library.canUndoEdit && library.currentProject?.assets.first?.position == CGPoint(x: 250, y: 180),
                  "A layout edit before replacement creates independent undo history")

        let incomingDirectory = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
        let incoming = incomingDirectory.appendingPathComponent(asset.name)
        try FileManager.default.copyItem(at: original, to: incoming)
        library.importURLs([incoming])
        for _ in 0..<100 where library.duplicateImportRequest == nil && library.isImporting {
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(library.duplicateImportRequest != nil, "A same-name import reaches the duplicate decision")
        library.resolveDuplicateImport(.overwrite)
        for _ in 0..<100 where library.isImporting {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let replacedAsset = library.currentProject?.assets.first else {
            throw NSError(domain: "ProjectThumbnailCacheRegressionTests", code: 4)
        }
        try check(replacedAsset.id == asset.id && replacedAsset.fileName == asset.fileName && replacedAsset.contentRevision != nil,
                  "Replacing a source preserves asset identity and cache key but changes preview identity")
        try check(replacedAsset.isReference && library.assetURL(replacedAsset).resolvingSymlinksInPath() == incoming.resolvingSymlinksInPath(),
                  "Replacing an old copied photo switches it to the incoming original's location")
        let retainedCopyBytes = try Data(contentsOf: originals.appendingPathComponent(asset.fileName))
        try check(retainedCopyBytes == originalBytes,
                  "Replacing an old copied photo leaves its stored copy unchanged")
        let replacedImage = try await waitForPreview(in: library, asset: replacedAsset)
        var proposedRect = CGRect(origin: .zero, size: replacedImage.size)
        let replacedPixels = replacedImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        try check(replacedImage !== memoryImage && replacedPixels.map { isColor($0, red: false) } == true,
                  "Overwriting replaces the cached red preview with the new blue image")
        library.undoLastEdit()
        guard let undoneAsset = library.currentProject?.assets.first else {
            throw NSError(domain: "ProjectThumbnailCacheRegressionTests", code: 5)
        }
        try check(undoneAsset.position == asset.position && undoneAsset.contentRevision == replacedAsset.contentRevision,
                  "Undo restores the old layout without reviving the prior image's content revision")
        try check(undoneAsset.name == replacedAsset.name && undoneAsset.fileName == replacedAsset.fileName &&
                  undoneAsset.sourcePath == replacedAsset.sourcePath && undoneAsset.sourceFileSize == replacedAsset.sourceFileSize &&
                  undoneAsset.isReference,
                  "Undo preserves the replacement original's file identity and source metadata")
        try check(library.thumbnail(for: undoneAsset) === replacedImage,
                  "Undo keeps the blue replacement preview ready instead of resurrecting the cached red image")
        try check(library.flushPendingSaves(), "The replacement's preview identity is saved with the project")
        let replacementReader = ProjectLibraryStore(projectsDirectory: projects)
        replacementReader.openProject(id: project.id)
        try check(replacementReader.currentProject?.assets.first?.contentRevision == replacedAsset.contentRevision &&
                  replacementReader.currentProject?.assets.first?.isReference == true,
                  "A reopened project keeps the replacement preview identity")

        let legacyJSON = #"{"id":"00000000-0000-0000-0000-000000000001","fileName":"old.png","name":"old.png","position":[0,0]}"#
        let legacy = try JSONDecoder().decode(ProjectAsset.self, from: Data(legacyJSON.utf8))
        try check(legacy.contentRevision == nil, "Old project files without a content revision remain readable")
        var revised = legacy
        revised.contentRevision = UUID()
        let reopened = try JSONDecoder().decode(ProjectAsset.self, from: JSONEncoder().encode(revised))
        try check(reopened.contentRevision == revised.contentRevision,
                  "Replacement identities persist across reopening the project")
        return checks
    }

    private static func waitForPreview(in library: ProjectLibraryStore, asset: ProjectAsset,
                                       maximumPixelSize: Int = 192) async throws -> NSImage {
        let target = ProjectThumbnailDiskCache.pixelSize(for: maximumPixelSize)
        for _ in 0..<100 {
            if let image = library.thumbnail(for: asset, maximumPixelSize: maximumPixelSize),
               max(image.size.width, image.size.height) >= CGFloat(target) { return image }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ProjectThumbnailCacheRegressionTests", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the thumbnail queue"])
    }

    private static func waitForDetailedPreview(in library: ProjectLibraryStore, asset: ProjectAsset) async throws -> NSImage {
        for _ in 0..<150 {
            if let image = library.detailedThumbnail(for: asset), library.isDetailedThumbnail(image) { return image }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ProjectThumbnailCacheRegressionTests", code: 7,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the 1080 short-edge detail preview"])
    }

    private static func writeOriginal(to url: URL, color: CGColor, width: Int = 1600, height: Int = 800,
                                      orientation: Int? = nil, fileType: UTType = .png) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, fileType.identifier as CFString, 1, nil)!
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ProjectThumbnailCacheRegressionTests", code: 3)
        }
    }

    private static func isColor(_ image: CGImage, red: Bool) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return red ? bytes[0] > 240 && bytes[2] < 10 : bytes[2] > 240 && bytes[0] < 10
    }
}
