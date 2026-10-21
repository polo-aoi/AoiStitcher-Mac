import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

@main struct GridCollageModelTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: " + message) }
            checks += 1
        }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.00001 }
        func verifyTree(_ node: SplitNode) {
            if case .split(_, _, let ratios, let children) = node {
                check(children.count >= 2, "Split nodes contain multiple children")
                check(ratios.count == children.count, "Split ratios match children")
                check(close(ratios.reduce(0,+), 1), "Template ratios sum to one")
                check(ratios.allSatisfy { $0 > 0 }, "Template ratios are positive")
                children.forEach(verifyTree)
            }
        }
        for count in GridCollageTemplates.supportedCounts {
            let templates = GridCollageTemplates.templates(for: count)
            check(templates.count >= (count == 1 ? 1 : 5), "Each image count has enough presets")
            check(Set(templates.map(\.id)).count == templates.count, "Template IDs are unique")
            check(templates.first?.familyID == (count == 1 ? "single" : "balanced"), "Balanced grids are the default for multiple photos")
            for template in templates {
                check(template.rootNode.slotIDs.count == count, "Template slot count matches")
                check(Set(template.rootNode.slotIDs).count == count, "Template has no repeated slots")
                verifyTree(template.rootNode)
                for aspect in CollageAspectRatio.allCases {
                    let bounds = CGRect(origin: .zero, size: aspect.size(forWidth: 1000))
                    let layout = GridCollageLayoutEngine.layout(rootNode: template.rootNode, in: bounds, gap: 0)
                    check(layout.slotRects.count == count, "Every leaf produces one crop rectangle")
                    let area = layout.slotRects.values.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
                    check(abs(area - bounds.width * bounds.height) < 0.01, "Gap-free recursive layout exactly covers the canvas")
                    let slots = Array(layout.slotRects.values)
                    check(slots.allSatisfy { bounds.contains($0) && $0.width > 0 && $0.height > 0 }, "All crop viewports stay inside canvas")
                    for (index, first) in slots.enumerated() {
                        for second in slots.dropFirst(index + 1) {
                            let intersection = first.intersection(second)
                            check(intersection.isNull || intersection.width * intersection.height < 0.01, "Slots do not overlap")
                        }
                    }
                    let gapLayout = GridCollageLayoutEngine.layout(rootNode: template.rootNode, in: bounds, gap: 100_000)
                    check(gapLayout.slotRects.values.allSatisfy { $0.width > 0 && $0.height > 0 }, "Extreme spacing cannot collapse a slot")
                }
            }
        }
        let nested: SplitNode = .split(id: "root", direction: .horizontal, ratios: [0.5, 0.5], children: [
            .split(id: "left", direction: .vertical, ratios: [0.5,0.5], children: [.slot(slotId:"a"), .slot(slotId:"b")]),
            .split(id: "right", direction: .horizontal, ratios: [0.2,0.8], children: [.slot(slotId:"c"), .slot(slotId:"d")])])
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let initial = GridCollageLayoutEngine.layout(rootNode: nested, in: bounds)
        let divider = initial.dividers.first { $0.splitID == "root" }!
        let resized = GridCollageLayoutEngine.resizing(rootNode: nested, divider: divider, delta: -150)
        let after = GridCollageLayoutEngine.layout(rootNode: resized, in: bounds)
        check(close(after.slotRects["a"]!.width, 350) && close(after.slotRects["b"]!.width, 350), "Shared divider resizes every adjacent descendant")
        check(close(after.slotRects["c"]!.width, 130), "Opposite subtree retains its internal ratio")
        let extreme = GridCollageLayoutEngine.resizing(rootNode: nested, divider: divider, delta: 100_000)
        let clamped = GridCollageLayoutEngine.layout(rootNode: extreme, in: bounds)
        check(clamped.slotRects.values.allSatisfy { $0.width >= 99.999 && $0.height >= 99.999 }, "Ancestor divider respects smallest descendant leaf")
        check(GridCollageLayoutEngine.normalizedRatios([.nan, -.infinity], count: 2) == [0.5,0.5], "Malformed ratios normalize safely")
        check(GridCollageLayoutEngine.layout(rootNode: nested, in: .zero).slotRects.isEmpty, "Empty viewport has no invalid geometry")
        let fitted = GridCollageLayoutEngine.fittedRect(aspectRatio: 3/4, in: CGRect(x:0,y:0,width:900,height:500))
        check(close(fitted.width/fitted.height, 3/4) && close(fitted.midX,450) && close(fitted.midY,250), "Canvas fits and centers without distorting ratio")
        let crop = GridCollageLayoutEngine.clampedTransform(CollageImageTransform(scale:9, translateX:100,translateY:-100), imageSize:CGSize(width:800,height:400),viewport:CGSize(width:200,height:200))
        check(crop.scale == 5, "Crop zoom clamps to 1...5")
        let imageRect = GridCollageLayoutEngine.imageRect(imageSize:CGSize(width:800,height:400),viewport:CGRect(x:0,y:0,width:200,height:200),transform:crop)
        check(imageRect.minX <= 0 && imageRect.maxX >= 200 && imageRect.minY <= 0 && imageRect.maxY >= 200, "Crop translation cannot expose blank edges")
        let doubled = GridCollageLayoutEngine.imageRect(imageSize:CGSize(width:800,height:400),viewport:CGRect(x:0,y:0,width:400,height:400),transform:crop)
        check(close(doubled.minX, imageRect.minX*2) && close(doubled.width,imageRect.width*2), "Normalized transforms match across preview and export sizes")
        let image = fixture()
        let store = GridCollageStore(photoCount: 3)
        let urls = (0..<17).map { URL(fileURLWithPath:"/tmp/aoipic-grid-photo-\($0).png") }
        store.addLoadedPreviews([(urls[0],image),(urls[1],image),(urls[2],image)])
        check(store.state.activeTemplateId == "grid-3-balanced", "First import starts with a balanced grid")
        let preferred = GridCollageStore(photoCount: 3)
        preferred.selectTemplate(preferred.availableTemplates.first { $0.familyID == "hero-left" }!)
        preferred.addLoadedPreviews(Array(urls.prefix(6)).map { ($0, image) })
        check(preferred.slotCount == 6 && preferred.state.activeTemplateId == "grid-6-hero-left", "Import growth keeps the user-selected template family")
        preferred.setPhotoCount(8)
        check(preferred.state.activeTemplateId == "grid-8-hero-left", "Manual slot growth retains the selected template family")
        let automatic = GridCollageStore(photoCount: 3)
        automatic.addLoadedPreviews(Array(urls.prefix(6)).map { ($0, image) })
        check(automatic.state.activeTemplateId == "grid-6-balanced", "Large initial imports automatically use balanced grids")
        var style = store.state.style
        style.gap = 40; style.padding = 60; style.borderRadius = 20; style.backgroundColor = .black
        style.backgroundImage = image; style.backgroundImageURL = urls[16]
        store.setStyle(style); store.resetStyleToDefaults()
        check(store.state.style.gap == 8 && store.state.style.padding == 16 && store.state.style.borderRadius == 0 && store.state.style.backgroundColor == .white, "Restore style uses the product defaults")
        check(store.state.style.backgroundImage === image && store.state.style.backgroundImageURL == urls[16] && store.photoCount == 3, "Restore style keeps the background image and all photos")
        check(store.photoCount == 3, "Imports retain all photos")
        let slotCountStore = GridCollageStore(photoCount: 3)
        slotCountStore.addLoadedPreviews(Array(urls.prefix(3)).map { ($0, image) })
        let occupiedReduction = slotCountStore.setSlotCount(2)
        if case .confirmationRequired(let targetCount, let photos) = occupiedReduction {
            check(targetCount == 2 && photos.count == 1 && photos[0].name == urls[2].lastPathComponent,
                  "Reducing occupied trailing cells requests confirmation for the exact photo")
            check(slotCountStore.slotCount == 3 && slotCountStore.photoCount == 3,
                  "A pending reduction leaves layout and photos untouched")
            let confirmed = slotCountStore.setSlotCount(2, confirmingRemovalOf: Set(photos.map(\.id)))
            check(confirmed == .changed && slotCountStore.slotCount == 2 && slotCountStore.photoCount == 2,
                  "Confirmed reduction removes only the trailing occupied cell")
        } else {
            check(false, "Reducing occupied trailing cells requires confirmation")
        }
        slotCountStore.setSlotCount(3)
        check(slotCountStore.slotCount == 3 && slotCountStore.photoCount == 2 && !slotCountStore.orderedSlots.last!.hasImage,
              "Increasing cell count adds a trailing blank cell")
        let blankReduction = slotCountStore.setSlotCount(2)
        check(blankReduction == .changed && slotCountStore.slotCount == 2 && slotCountStore.photoCount == 2,
              "Reducing a trailing blank cell needs no confirmation")
        let staleConfirmation = slotCountStore.setSlotCount(1, confirmingRemovalOf: [UUID()])
        check(staleConfirmation != .changed && slotCountStore.slotCount == 2 && slotCountStore.photoCount == 2,
              "A stale confirmation cannot remove a photo")
        let refusesRemoval = store.setPhotoCount(2)
        if case .confirmationRequired = refusesRemoval {
            check(store.slotCount == 3 && store.photoCount == 3,
                  "Compatibility API requests confirmation instead of silently deleting photos")
        } else {
            check(false, "Compatibility API reports occupied-cell confirmation")
        }
        store.setPhotoCount(6)
        check(store.slotCount == 6 && store.photoCount == 3, "Adding empty slots preserves photos")
        let firstIDs = store.state.rootNode.slotIDs
        store.selectSlot(firstIDs[0])
        store.setScale(2,for:firstIDs[0],viewport:CGSize(width:200,height:200))
        store.setPan(CGPoint(x:0.2,y:0.1),for:firstIDs[0],viewport:CGSize(width:200,height:200))
        let beforeSwap = store.state.slots[firstIDs[0]]!
        store.swapImages(firstIDs[0],firstIDs[1])
        check(store.state.slots[firstIDs[1]]!.imageURL == beforeSwap.imageURL && store.state.slots[firstIDs[1]]!.transform.scale == 2, "Image swaps carry their crop state")
        store.selectTemplate(store.availableTemplates.last!)
        check(store.orderedSlots.compactMap(\.imageURL) == [urls[1],urls[0],urls[2]], "Switching templates preserves photo order")
        store.setAspectRatio(.landscape16x9)
        check(store.state.aspectRatio == .landscape16x9 && store.photoCount == 3, "Changing aspect keeps photos")
        store.clearAll()
        check(store.photoCount == 0 && store.slotCount == 6, "Clear removes photos while keeping layout")
        store.setPhotoCount(3)
        store.addLoadedPreviews([(urls[0],image),(urls[1],image),(urls[2],image)])
        store.removePhoto("slot-2")
        store.addLoadedPreviews([(urls[3],image),(urls[4],image)],into:"slot-2")
        check(store.photoCount == 4 && Set(store.orderedSlots.compactMap(\.imageURL)) == Set([urls[0],urls[2],urls[3],urls[4]]), "Expanding a targeted import preserves existing photos around empty slots")
        let targeted = GridCollageStore(photoCount:3)
        targeted.addLoadedPreviews([(urls[0],image),(urls[1],image),(urls[2],image)])
        targeted.removePhoto("slot-2")
        targeted.addLoadedPreviews([(urls[3],image),(urls[4],image),(urls[5],image)],into:"slot-3")
        check(targeted.photoCount == 4 && Set(targeted.orderedSlots.compactMap(\.imageURL)) == Set([urls[0],urls[3],urls[4],urls[5]]), "Replacing an occupied target while growing retains every new image exactly once")
        let remaining = Array(urls[5...16]).map { ($0,image) }
        store.addLoadedPreviews(remaining)
        check(store.photoCount == 16, "Up to sixteen photos are supported")
        let oldPhotos = store.orderedSlots.compactMap(\.imageURL)
        store.addLoadedPreviews([(urls[0],image)])
        check(store.photoCount == 16 && store.orderedSlots.compactMap(\.imageURL) == oldPhotos, "Overflow import is rejected without replacing photos")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aoipic-grid-tests-" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        let sourceURL = temp.appendingPathComponent("valid.png")
        let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil)
        check(CGImageDestinationFinalize(destination), "Fixture encodes")
        let brokenURL = temp.appendingPathComponent("broken.jpg")
        try Data([0,1,2,3]).write(to:brokenURL)
        let asyncStore = GridCollageStore(photoCount:2)
        asyncStore.importURLs([sourceURL,brokenURL])
        for _ in 0..<1000 where asyncStore.isLoading { try await Task.sleep(for:.milliseconds(5)) }
        check(!asyncStore.isLoading && asyncStore.photoCount == 1, "Async import completes and keeps valid files")
        check(asyncStore.status?.contains("broken.jpg") == true, "Failed imports identify the exact source filename")
        check(asyncStore.orderedSlots.first?.image == nil && asyncStore.orderedSlots.first?.previewImage != nil, "Interactive state stores previews instead of full decoded originals")
        asyncStore.importURLs([sourceURL]); asyncStore.clearAll()
        for _ in 0..<20 { try await Task.sleep(for:.milliseconds(5)) }
        check(asyncStore.photoCount == 0 && !asyncStore.isLoading, "Clear cancels outstanding import results")
        let originalBrokenData = try Data(contentsOf:brokenURL)
        check(originalBrokenData == Data([0,1,2,3]), "Failed imports never alter sources")

        let fullOriginal = fixture(width: 2400, height: 1200)
        let fullURL = temp.appendingPathComponent("full-original.png")
        try writePNG(fullOriginal, to: fullURL)
        let originalBytes = try Data(contentsOf: fullURL)
        let editStore = GridCollageStore(photoCount: 2, editingCacheDirectory: temp.appendingPathComponent("edits"))
        editStore.importURLs([fullURL, sourceURL])
        for _ in 0..<1000 where editStore.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        let untouchedTree = editStore.state.rootNode
        let untouchedSecondID = editStore.state.slots["slot-2"]!.photoID
        let beforeOpening = editStore.state.slots["slot-1"]!
        let initialItem = try await editStore.makeCropItem(for: "slot-1")
        check(initialItem.image.size.width == 2400 && initialItem.croppedImage == nil, "Crop opens full original pixels, not the bounded preview")
        check(editStore.state.slots["slot-1"]!.photoID == beforeOpening.photoID && editStore.state.slots["slot-1"]!.editRecipe == nil, "Opening and cancelling an editor does not modify a slot")
        var editedItem = initialItem
        editedItem.cropInfo = CropInfo(uiCropRect: CGRect(x: 100, y: 80, width: 1800, height: 900), rotation: 90,
                                       imageCenter: CGPoint(x: 1200, y: 600), scale: 1.25)
        editedItem.watermarks = [OverlayWatermark(image: NSImage(cgImage: image, size: CGSize(width: 80, height: 40)),
                                                  offset: CGSize(width: 20, height: -30), scale: 0.8, rotation: 12)]
        editedItem.croppedImage = NSImage(cgImage: fixture(width: 1800, height: 900), size: CGSize(width: 1800, height: 900))
        editStore.applyCrop(editedItem, for: "slot-1")
        for _ in 0..<1000 where editStore.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        let saved = editStore.state.slots["slot-1"]!
        check(saved.imageURL == fullURL && saved.editedImageURL != nil && saved.image == nil, "Editing keeps the source URL and stores the full result on disk")
        check(saved.previewImage!.width == 1600 && saved.previewImage!.height == 800, "Edited interactive images remain bounded previews")
        let editedSource = CGImageSourceCreateWithURL(saved.editedImageURL! as CFURL, nil)!
        let renderedEdit = CGImageSourceCreateImageAtIndex(editedSource, 0, nil)!
        check(renderedEdit.width == 1800 && renderedEdit.height == 900, "Cached result retains full editor output resolution")
        let recipeURL = saved.editedImageURL!.deletingLastPathComponent().appendingPathComponent("recipe.json")
        let recipeOnDisk = try JSONDecoder().decode(CollageEditRecipe.self, from: Data(contentsOf: recipeURL))
        check(recipeOnDisk == saved.editRecipe && recipeOnDisk.watermarks.count == 1, "Crop and watermark instructions are stored alongside the full result")
        check(editStore.state.rootNode == untouchedTree && editStore.state.slots["slot-2"]!.photoID == untouchedSecondID, "Per-slot edits leave layout and neighboring photos untouched")
        let reopened = try await editStore.makeCropItem(for: "slot-1")
        check(reopened.image.size.width == 2400 && reopened.cropInfo == editedItem.cropInfo, "Reopening uses original pixels plus the saved crop recipe")
        check(reopened.watermarks.count == 1 && reopened.watermarks[0].offset == editedItem.watermarks[0].offset && reopened.watermarks[0].rotation == 12 && reopened.watermarks[0].image.size == editedItem.watermarks[0].image.size, "Reopening restores editable watermark pixels and transforms")
        editStore.setScale(3, for: "slot-1", viewport: CGSize(width: 200, height: 200))
        editStore.setFill(.contain, for: "slot-1")
        editStore.setScale(2, for: "slot-1", viewport: CGSize(width: 200, height: 200))
        editStore.resetTransform(for: "slot-1")
        check(editStore.state.slots["slot-1"]!.transform == CollageImageTransform() && editStore.state.slots["slot-1"]!.fill == .contain && editStore.state.slots["slot-1"]!.editRecipe == saved.editRecipe, "Reset view keeps fill mode and image edits")
        editStore.swapImages("slot-1", "slot-2")
        let swapped = editStore.state.slots["slot-2"]!
        check(swapped.photoID == saved.photoID && swapped.editRecipe == saved.editRecipe && swapped.editedImageURL == saved.editedImageURL, "Image swaps carry identity, disk result and editable recipe together")
        let afterSwapItem = try await editStore.makeCropItem(for: "slot-2")
        check(afterSwapItem.url == fullURL && afterSwapItem.cropInfo == editedItem.cropInfo, "The swapped photo reopens the correct source and recipe")
        editStore.replacePhoto(brokenURL, for: "slot-2")
        for _ in 0..<1000 where editStore.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        check(editStore.state.slots["slot-2"]!.photoID == saved.photoID && editStore.state.slots["slot-2"]!.editedImageURL == saved.editedImageURL, "Failed replacement preserves the prior full edit")
        check(editStore.status?.contains("broken.jpg") == true, "Failed replacement identifies the file")
        editStore.replacePhoto(fullURL, for: "slot-2")
        for _ in 0..<1000 where editStore.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        let sameSourceReplacementID = editStore.state.slots["slot-2"]!.photoID
        var staleSameSourceItem = afterSwapItem
        staleSameSourceItem.croppedImage = editedItem.croppedImage
        editStore.applyCrop(staleSameSourceItem, for: "slot-2")
        check(sameSourceReplacementID != saved.photoID && editStore.state.slots["slot-2"]!.photoID == sameSourceReplacementID && editStore.state.slots["slot-2"]!.editedImageURL == nil && !editStore.isLoading, "Session identity rejects stale edits even when replacement uses the exact same source URL")
        editStore.replacePhoto(sourceURL, for: "slot-2")
        for _ in 0..<1000 where editStore.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        let replaced = editStore.state.slots["slot-2"]!
        check(replaced.imageURL == sourceURL && replaced.editedImageURL == nil && replaced.editRecipe == nil && replaced.photoID != saved.photoID && replaced.transform == CollageImageTransform(), "Single replacement clears only that photo's edit and viewport state")
        check(editStore.state.rootNode == untouchedTree && editStore.slotCount == 2 && editStore.photoCount == 2, "Single replacement retains the exact layout and slot count")
        check(FileManager.default.fileExists(atPath: saved.editedImageURL!.path), "Old cached pixels remain available to existing export snapshots")
        let replacementID = replaced.photoID
        editStore.applyCrop(afterSwapItem, for: "slot-2")
        check(editStore.state.slots["slot-2"]!.photoID == replacementID && editStore.state.slots["slot-2"]!.editedImageURL == nil, "A stale editor cannot overwrite a replacement photo")
        let blockedCache = temp.appendingPathComponent("blocked-cache")
        try Data([1]).write(to: blockedCache)
        let failingStore = GridCollageStore(photoCount: 1, editingCacheDirectory: blockedCache)
        failingStore.importURLs([fullURL])
        for _ in 0..<1000 where failingStore.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        let beforeFailedSave = failingStore.state.slots["slot-1"]!
        var failureItem = try await failingStore.makeCropItem(for: "slot-1")
        failureItem.cropInfo = editedItem.cropInfo; failureItem.watermarks = editedItem.watermarks
        failureItem.croppedImage = editedItem.croppedImage
        failingStore.applyCrop(failureItem, for: "slot-1")
        for _ in 0..<1000 where failingStore.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        check(failingStore.state.slots["slot-1"]!.photoID == beforeFailedSave.photoID && failingStore.state.slots["slot-1"]!.editedImageURL == nil && failingStore.status?.contains("无法保存编辑结果") == true, "Cache failures leave the prior photo intact and report the failure")
        let cancelledRead = Task { try await editStore.makeCropItem(for: "slot-2") }
        cancelledRead.cancel()
        do { _ = try await cancelledRead.value; check(false, "A cancelled edit read must not open") }
        catch { check(!editStore.isLoading && editStore.state.slots["slot-2"]!.photoID == replacementID, "Cancelled original reads release loading without modifying photos") }
        failingStore.applyCrop(failureItem, for: "slot-1"); failingStore.clearAll()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
        check(failingStore.photoCount == 0 && !failingStore.isLoading, "Clear invalidates an outstanding edit save")
        let cancelledSaveStore = GridCollageStore(photoCount: 1, editingCacheDirectory: temp.appendingPathComponent("cancelled-edits"))
        cancelledSaveStore.importURLs([fullURL])
        for _ in 0..<1000 where cancelledSaveStore.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        var cancelledSaveItem = try await cancelledSaveStore.makeCropItem(for: "slot-1")
        cancelledSaveItem.croppedImage = editedItem.croppedImage
        cancelledSaveStore.applyCrop(cancelledSaveItem, for: "slot-1")
        cancelledSaveStore.clearAll()
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(5)) }
        check(cancelledSaveStore.photoCount == 0 && cancelledSaveStore.state.slots["slot-1"]!.editedImageURL == nil && !cancelledSaveStore.isLoading, "Late successful disk writes cannot resurrect a photo after clear")
        let finalOriginalBytes = try Data(contentsOf: fullURL)
        check(finalOriginalBytes == originalBytes, "Editing, swapping, replacement and failed saves never alter the original source")
        print("PASS: \(checks) grid collage model checks (1–16 presets, recursive layout, nested divider limits, crop bounds, transforms, safe imports, full-resolution editing, recipe restore, source protection)")
    }
    nonisolated static func fixture(width: Int = 80, height: Int = 40) -> CGImage {
        let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        return context.makeImage()!
    }
    nonisolated static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GridCollageEditingError.invalidEditedImage }
    }
}
