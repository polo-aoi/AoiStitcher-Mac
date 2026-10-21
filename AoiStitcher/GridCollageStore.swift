import Foundation
import Combine
import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum GridCollageEditingError: LocalizedError {
    case busy, noPhoto, stalePhoto
    case cannotReadSource(String), invalidEditedImage, cacheFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "正在处理照片，请稍后重试。"
        case .noPhoto: return "请先选择一张照片。"
        case .stalePhoto: return "该格的照片已经改变，此次编辑未应用。"
        case .cannotReadSource(let name): return "无法读取图片“\(name)”，请确认文件仍然存在。"
        case .invalidEditedImage: return "无法读取编辑结果，原照片保持不变。"
        case .cacheFailed(let reason): return "无法保存编辑结果：\(reason)"
        }
    }
}

/// Result of changing the number of collage cells. Reducing below the number
/// of occupied cells is deliberately a two-step operation so callers can ask
/// for confirmation before any source photo is removed.
nonisolated struct GridCollagePhotoRemoval: Equatable, Identifiable {
    var id: UUID
    var name: String
}

nonisolated enum GridCollageSlotCountChangeResult: Equatable {
    case changed
    case unchanged
    case confirmationRequired(targetCount: Int, photos: [GridCollagePhotoRemoval])
    case rejected(String)
}

nonisolated private struct GridCollageWatermarkPixels {
    var image: CGImage
    var offset: CGSize
    var scale: CGFloat
    var rotation: Double
}

nonisolated private struct GridCollageCachedEdit {
    var imageURL: URL
    var preview: CGImage
    var recipe: CollageEditRecipe
}

@MainActor final class GridCollageStore: ObservableObject {
    @Published private(set) var state: CollageState
    @Published var status: String?
    @Published private(set) var isLoading = false
    @Published var pendingStatus: String?
    private var importGeneration = UUID()
    private let previewMaximum = 1600
    private var preferredTemplateFamily: String?
    private let editingCacheDirectory: URL
    private var cropSession: (itemID: UUID, photoID: UUID)?

    init(photoCount: Int = 3, aspectRatio: CollageAspectRatio = .portrait3x4,
         editingCacheDirectory: URL? = nil) {
        self.editingCacheDirectory = editingCacheDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("aoipic-grid-edits", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let count = min(GridCollageTemplates.maximumPhotoCount, max(1, photoCount))
        let template = GridCollageTemplates.templates(for: count)[0]
        state = CollageState(aspectRatio: aspectRatio, activeTemplateId: template.id, rootNode: template.rootNode,
                             slots: Dictionary(uniqueKeysWithValues: template.rootNode.slotIDs.map { ($0, CollageSlot(id: $0)) }))
    }

    var photoCount: Int { state.slots.values.filter(\.hasImage).count }
    var slotCount: Int { state.rootNode.slotIDs.count }
    var availableTemplates: [CollageTemplate] { GridCollageTemplates.templates(for: slotCount) }
    var orderedSlots: [CollageSlot] { state.orderedSlots }
    var selectedSlot: CollageSlot? { state.selectedSlotId.flatMap { state.slots[$0] } }

    /// Sets the number of layout cells, not the number of imported photos.
    /// Adding cells appends blank cells. Removing cells removes the trailing
    /// cells in template order; if any are occupied, the caller receives the
    /// exact photos that would be discarded and must confirm with their IDs.
    @discardableResult
    func setSlotCount(_ count: Int, confirmingRemovalOf photoIDs: Set<UUID>? = nil) -> GridCollageSlotCountChangeResult {
        guard !isLoading else {
            let message = "照片正在读取，请稍后再更改图片格数量。"
            status = message
            return .rejected(message)
        }
        guard GridCollageTemplates.supportedCounts.contains(count) else {
            let message = "图片格数量需在 1 到 \(GridCollageTemplates.maximumPhotoCount) 之间。"
            status = message
            return .rejected(message)
        }
        guard count != slotCount else { return .unchanged }
        guard let template = preferredTemplate(for: count) else {
            let message = "没有可用的 \(count) 格布局。"
            status = message
            return .rejected(message)
        }

        let oldSlots = orderedSlots
        var sourcesToKeep = oldSlots
        var occupiedToRemove: [CollageSlot] = []
        if count < slotCount {
            let slotsToRemove = slotCount - count
            let removedSlots = Array(oldSlots.suffix(slotsToRemove))
            occupiedToRemove = removedSlots.filter(\.hasImage)
            let requested = Set(occupiedToRemove.map(\.photoID))
            guard requested.isEmpty || photoIDs == requested else {
                let photos = occupiedToRemove.map { GridCollagePhotoRemoval(id: $0.photoID, name: $0.name) }
                status = "减少到 \(count) 个格子将移除 \(photos.count) 张照片，请确认后继续。"
                return .confirmationRequired(targetCount: count, photos: photos)
            }
            guard photoIDs == nil || photoIDs == requested else {
                let message = "图片格状态已变化，请重新调整。"
                status = message
                return .rejected(message)
            }
            sourcesToKeep = Array(oldSlots.prefix(count))
        } else {
            // The current tree's leaf order is stable across template families,
            // so append fresh blank cells without moving any existing contents.
            sourcesToKeep.append(contentsOf: (slotCount..<count).map { index in
                CollageSlot(id: "slot-\(index + 1)")
            })
        }

        guard sourcesToKeep.count == count else {
            let message = "无法安全调整格数，照片和布局均未更改。"
            status = message
            return .rejected(message)
        }
        let selectedIdentity = state.selectedSlotId.flatMap { state.slots[$0]?.photoID }
        var newSlots: [String: CollageSlot] = [:]
        for (index, id) in template.rootNode.slotIDs.enumerated() {
            newSlots[id] = contents(sourcesToKeep[index], withID: id)
        }
        state.rootNode = template.rootNode
        state.activeTemplateId = template.id
        state.slots = newSlots
        state.selectedSlotId = selectedIdentity.flatMap { identity in
            template.rootNode.slotIDs.first { newSlots[$0]?.photoID == identity }
        }
        clampAllTransforms()
        if occupiedToRemove.isEmpty {
            status = count > oldSlots.count ? "已增加图片格" : "已移除空白图片格"
        } else {
            status = "已调整图片格，并移除 \(occupiedToRemove.count) 张已确认的照片"
        }
        return .changed
    }

    /// Kept as a compatibility shim for the earlier UI call site. The value
    /// represents layout cells; occupied cells still require explicit consent.
    @discardableResult
    func setPhotoCount(_ count: Int) -> GridCollageSlotCountChangeResult {
        setSlotCount(count)
    }

    func selectTemplate(_ template: CollageTemplate) {
        guard !isLoading else { status = "照片正在读取，请稍后再切换布局。"; return }
        guard template.slotCount >= photoCount else {
            status = "这个布局只能容纳 \(template.slotCount) 张，现有照片不会被删除。"; return
        }
        preferredTemplateFamily = template.familyID
        applyTemplate(template)
    }

    func setAspectRatio(_ ratio: CollageAspectRatio) { state.aspectRatio = ratio; clampAllTransforms() }
    func setStyle(_ style: CollageStyle) {
        var style = style
        style.gap = finiteClamp(style.gap, 0...100)
        style.padding = finiteClamp(style.padding, 0...150)
        style.borderRadius = finiteClamp(style.borderRadius, 0...150)
        state.style = style
        clampAllTransforms()
    }
    func resetStyleToDefaults() {
        var defaults = CollageStyle()
        defaults.backgroundImage = state.style.backgroundImage
        defaults.backgroundImageURL = state.style.backgroundImageURL
        setStyle(defaults)
        status = "已恢复默认画布样式"
    }
    func resetTransform(for slotID: String) {
        guard !isLoading, var slot = state.slots[slotID] else { return }
        slot.transform = CollageImageTransform()
        state.slots[slotID] = slot
        status = "已重置图片取景"
    }
    func selectSlot(_ id: String?) { state.selectedSlotId = id.flatMap { state.slots[$0] == nil ? nil : $0 } }
    func setScale(_ scale: CGFloat, for id: String, viewport: CGSize) {
        guard var slot = state.slots[id] else { return }
        slot.transform.scale = scale
        clamp(&slot, viewport: viewport)
        state.slots[id] = slot
    }
    func setPan(_ translation: CGPoint, for id: String, viewport: CGSize) {
        guard var slot = state.slots[id] else { return }
        slot.transform.translateX = translation.x; slot.transform.translateY = translation.y
        clamp(&slot, viewport: viewport)
        state.slots[id] = slot
    }
    func setFill(_ fill: CollageImageFill, for id: String) {
        guard var slot = state.slots[id] else { return }
        slot.fill = fill; slot.transform = CollageImageTransform()
        state.slots[id] = slot
    }
    func resizeDivider(_ divider: GridCollageDivider, delta: CGFloat) {
        state.rootNode = GridCollageLayoutEngine.resizing(rootNode: state.rootNode, divider: divider, delta: delta)
        clampAllTransforms()
    }
    func swapImages(_ firstID: String, _ secondID: String) {
        guard !isLoading else { return }
        guard firstID != secondID, let first = state.slots[firstID], let second = state.slots[secondID] else { return }
        state.slots[firstID] = contents(second, withID: firstID)
        state.slots[secondID] = contents(first, withID: secondID)
        clampAllTransforms()
        state.selectedSlotId = secondID
        status = "已交换两张照片"
    }
    func removePhoto(_ id: String) {
        guard !isLoading else { status = "照片正在读取，请稍后再移除照片。"; return }
        guard state.slots[id] != nil else { return }
        state.slots[id] = CollageSlot(id: id)
        status = "已移除照片"
    }
    func clearAll() {
        importGeneration = UUID(); isLoading = false; pendingStatus = nil
        cropSession = nil
        for id in state.rootNode.slotIDs { state.slots[id] = CollageSlot(id: id) }
        state.selectedSlotId = nil; status = "已清空照片"
    }

    func importPhotos(into slotID: String? = nil) {
        guard !isLoading else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.prompt = "导入图片"
        if panel.runModal() == .OK { importURLs(panel.urls, into: slotID) }
    }
    func replacePhoto(for slotID: String) {
        guard !isLoading, state.slots[slotID] != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.prompt = "替换照片"
        if panel.runModal() == .OK, let url = panel.url { replacePhoto(url, for: slotID) }
    }
    func replacePhoto(_ url: URL, for slotID: String) {
        guard state.slots[slotID] != nil else { return }
        importURLs([url], into: slotID)
    }

    /// Reopens the original pixels and the last saved recipe, never the 1,600px
    /// preview or an already-flattened edit. Cancelling this read changes no slot.
    func makeCropItem(for slotID: String) async throws -> StitchItem {
        guard !isLoading else { throw GridCollageEditingError.busy }
        guard let slot = state.slots[slotID], slot.hasImage else { throw GridCollageEditingError.noPhoto }
        let generation = UUID(); importGeneration = generation
        isLoading = true; pendingStatus = "正在读取完整原图…"
        defer {
            if importGeneration == generation { isLoading = false; pendingStatus = nil }
        }
        let sourceURL = originalURL(for: slot)
        let recipe = slot.editRecipe
        let input = try await Task.detached(priority: .userInitiated) {
            let original: CGImage
            if let image = slot.image { original = image }
            else if let image = Self.loadImage(sourceURL, maximum: nil) { original = image }
            else { throw GridCollageEditingError.cannotReadSource(sourceURL.lastPathComponent) }
            let watermarks = try (recipe?.watermarks ?? []).map { saved -> GridCollageWatermarkPixels in
                guard let image = Self.loadImage(saved.imageURL, maximum: nil) else {
                    throw GridCollageEditingError.cannotReadSource(saved.imageURL.lastPathComponent)
                }
                return GridCollageWatermarkPixels(image: image, offset: saved.offset,
                                                  scale: saved.scale, rotation: saved.rotation)
            }
            return (original, watermarks)
        }.value
        try Task.checkCancellation()
        guard importGeneration == generation, state.slots[slotID]?.photoID == slot.photoID else {
            throw GridCollageEditingError.stalePhoto
        }
        var item = StitchItem(url: sourceURL,
                              image: NSImage(cgImage: input.0, size: CGSize(width: input.0.width, height: input.0.height)))
        if let crop = recipe?.crop {
            item.cropInfo = CropInfo(uiCropRect: crop.rect, rotation: crop.rotation,
                                     imageCenter: crop.imageCenter, scale: crop.scale)
        }
        item.watermarks = input.1.map { saved in
            OverlayWatermark(image: NSImage(cgImage: saved.image, size: CGSize(width: saved.image.width, height: saved.image.height)),
                             offset: saved.offset, scale: saved.scale, rotation: saved.rotation)
        }
        cropSession = (item.id, slot.photoID)
        return item
    }

    /// Saves full-resolution pixels and edit instructions before publishing any
    /// change. A failed/cancelled save leaves the prior edit and source intact.
    func applyCrop(_ item: StitchItem, for slotID: String) {
        guard !isLoading, let slot = state.slots[slotID], slot.hasImage else { return }
        guard originalURL(for: slot) == item.url, cropSession?.itemID == item.id,
              cropSession?.photoID == slot.photoID else {
            status = GridCollageEditingError.stalePhoto.localizedDescription; return
        }
        guard let image = item.croppedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            status = GridCollageEditingError.invalidEditedImage.localizedDescription; return
        }
        var watermarks: [GridCollageWatermarkPixels] = []
        for watermark in item.watermarks {
            guard let pixels = watermark.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                status = GridCollageEditingError.invalidEditedImage.localizedDescription; return
            }
            watermarks.append(GridCollageWatermarkPixels(image: pixels, offset: watermark.offset,
                                                        scale: watermark.scale, rotation: watermark.rotation))
        }
        let crop = item.cropInfo.map {
            CollageCropRecipe(rect: $0.uiCropRect, rotation: $0.rotation, imageCenter: $0.imageCenter, scale: $0.scale)
        }
        let directory = editingCacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let generation = UUID(); importGeneration = generation
        isLoading = true; pendingStatus = "正在保存图片编辑…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.cacheEdit(image: image, crop: crop, watermarks: watermarks, in: directory) }
            }.value
            guard let self, self.importGeneration == generation,
                  self.state.slots[slotID]?.photoID == slot.photoID else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            self.isLoading = false; self.pendingStatus = nil
            switch result {
            case .success(let edit):
                var updated = slot
                updated.image = slot.imageURL == nil ? slot.image : nil
                updated.previewImage = edit.preview
                updated.editedImageURL = edit.imageURL; updated.editRecipe = edit.recipe
                updated.transform = CollageImageTransform()
                self.state.slots[slotID] = updated
                self.state.selectedSlotId = slotID
                self.status = "已保存照片编辑"
            case .failure(let error):
                self.status = GridCollageEditingError.cacheFailed(error.localizedDescription).localizedDescription
            }
        }
    }

    func importURLs(_ urls: [URL], into slotID: String? = nil) {
        guard !isLoading, !urls.isEmpty else { return }
        let existing = photoCount
        let replacing = slotID.flatMap { state.slots[$0] }?.hasImage == true ? 1 : 0
        guard existing - replacing + urls.count <= GridCollageTemplates.maximumPhotoCount else {
            status = "一次拼图最多 \(GridCollageTemplates.maximumPhotoCount) 张。此次未导入，原有照片保持不变。"; return
        }
        let generation = UUID(); importGeneration = generation
        isLoading = true; pendingStatus = "正在读取 \(urls.count) 张照片…"
        let maximum = previewMaximum
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                urls.map { url in (url, Self.loadPreview(url, maximum: maximum)) }
            }.value
            guard let self, self.importGeneration == generation else { return }
            self.isLoading = false; self.pendingStatus = nil
            let successes = loaded.compactMap { url, image in image.map { (url, $0) } }
            self.addLoadedPreviews(successes, into: slotID)
            let failures = loaded.filter { $0.1 == nil }.map { $0.0.lastPathComponent }
            if !failures.isEmpty {
                self.status = "已导入 \(successes.count) 张；读取失败：\(failures.joined(separator: "、"))"
            } else { self.status = "已导入 \(successes.count) 张照片" }
        }
    }
    func importDroppedURLs(_ urls: [URL], into slotID: String? = nil) { importURLs(urls, into: slotID) }
    func importBackgroundImage() {
        guard !isLoading else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "选择背景图片"
        if panel.runModal() == .OK, let url = panel.url { setBackgroundImage(url) }
    }
    func setBackgroundImage(_ url: URL) {
        guard !isLoading else { return }
        let generation = UUID(); importGeneration = generation
        isLoading = true; pendingStatus = "正在读取背景…"
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { Self.loadPreview(url, maximum: 1600) }.value
            guard let self, self.importGeneration == generation else { return }
            self.isLoading = false; self.pendingStatus = nil
            guard let image else { self.status = "无法读取背景：\(url.lastPathComponent)"; return }
            self.state.style.backgroundImage = image; self.state.style.backgroundImageURL = url
            self.status = "已设置背景图片"
        }
    }
    func clearBackgroundImage() { state.style.backgroundImage = nil; state.style.backgroundImageURL = nil }

    /// Useful for non-file inputs and model tests; decoded previews are bounded
    /// while original URLs remain available for full-resolution export.
    func addLoadedPreviews(_ images: [(URL, CGImage)], into slotID: String? = nil) {
        guard !images.isEmpty else { return }
        let replacing = slotID.flatMap { state.slots[$0] }?.hasImage == true ? 1 : 0
        guard photoCount - replacing + images.count <= GridCollageTemplates.maximumPhotoCount else {
            status = "超过最多 \(GridCollageTemplates.maximumPhotoCount) 张的限制，未导入。"; return
        }
        let required = photoCount - replacing + images.count
        if required > slotCount, let template = preferredTemplate(for: required) {
            let oldSlots = orderedSlots
            applyTemplate(template)
            // Expanding after a targeted import must preserve holes and the
            // targeted identity; compacting first could overwrite another photo.
            for (index, old) in oldSlots.enumerated() {
                let id = state.rootNode.slotIDs[index]
                state.slots[id] = contents(old, withID: id)
            }
        }
        var available = state.rootNode.slotIDs.filter { state.slots[$0]?.hasImage != true }
        if let slotID, state.slots[slotID] != nil { available.removeAll { $0 == slotID }; available.insert(slotID, at: 0) }
        for ((url, image), id) in zip(images, available) {
            var slot = CollageSlot(id: id)
            slot.imageURL = url; slot.previewImage = image
            state.slots[id] = slot
        }
        if let first = available.first { state.selectedSlotId = first }
    }

    private func preferredTemplate(for count: Int) -> CollageTemplate? {
        let templates = GridCollageTemplates.templates(for: count)
        return templates.first { $0.familyID == preferredTemplateFamily } ?? templates.first
    }

    private func originalURL(for slot: CollageSlot) -> URL {
        slot.imageURL ?? URL(fileURLWithPath: "/aoipic-memory/\(slot.photoID.uuidString)")
    }

    nonisolated private static func cacheEdit(image: CGImage, crop: CollageCropRecipe?,
                                              watermarks: [GridCollageWatermarkPixels], in directory: URL) throws -> GridCollageCachedEdit {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let imageURL = directory.appendingPathComponent("edited.png")
            try writePNG(image, to: imageURL)
            var savedWatermarks: [CollageWatermarkRecipe] = []
            for (index, watermark) in watermarks.enumerated() {
                let url = directory.appendingPathComponent("watermark-\(index + 1).png")
                try writePNG(watermark.image, to: url)
                savedWatermarks.append(CollageWatermarkRecipe(imageURL: url, offset: watermark.offset,
                                                              scale: watermark.scale, rotation: watermark.rotation))
            }
            let recipe = CollageEditRecipe(crop: crop, watermarks: savedWatermarks)
            try JSONEncoder().encode(recipe).write(to: directory.appendingPathComponent("recipe.json"), options: .withoutOverwriting)
            guard let preview = loadImage(imageURL, maximum: 1600) else { throw GridCollageEditingError.invalidEditedImage }
            return GridCollageCachedEdit(imageURL: imageURL, preview: preview, recipe: recipe)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw GridCollageEditingError.invalidEditedImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GridCollageEditingError.invalidEditedImage }
        try (data as Data).write(to: url, options: .withoutOverwriting)
    }

    private func applyTemplate(_ template: CollageTemplate) {
        let images = orderedSlots.filter(\.hasImage)
        var slots: [String: CollageSlot] = [:]
        for (index, id) in template.rootNode.slotIDs.enumerated() {
            slots[id] = index < images.count ? contents(images[index], withID: id) : CollageSlot(id: id)
        }
        state.rootNode = template.rootNode; state.activeTemplateId = template.id; state.slots = slots
        state.selectedSlotId = nil
        clampAllTransforms()
    }
    private func contents(_ slot: CollageSlot, withID id: String) -> CollageSlot { var result = slot; result.id = id; return result }
    private func clamp(_ slot: inout CollageSlot, viewport: CGSize) {
        guard let imageSize = slot.imageSize else { return }
        slot.transform = GridCollageLayoutEngine.clampedTransform(slot.transform, imageSize: imageSize,
                                                                  viewport: viewport, fill: slot.fill)
    }
    private func clampAllTransforms() {
        let layout = GridCollageLayoutEngine.layout(state: state, in: CGRect(origin: .zero, size: state.logicalSize))
        for (id, rect) in layout.slotRects {
            if var slot = state.slots[id] { clamp(&slot, viewport: rect.size); state.slots[id] = slot }
        }
    }
    private func finiteClamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : range.lowerBound))
    }
    nonisolated private static func loadPreview(_ url: URL, maximum: Int) -> CGImage? {
        loadImage(url, maximum: maximum)
    }
    nonisolated private static func loadImage(_ url: URL, maximum: Int?) -> CGImage? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 160_000_000 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximum ?? max(width.intValue, height.intValue),
                                      kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
