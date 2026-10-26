import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ProjectOperation: String, Codable, CaseIterable, Identifiable, Sendable {
    case freeCanvas, longStitch, gridCollage, compression

    // Compression remains decodable for saved export history; only current tools appear in menus.
    static var allCases: [ProjectOperation] { [.gridCollage, .freeCanvas, .longStitch] }

    var id: String { rawValue }
    var maximumPhotoCount: Int? { self == .gridCollage ? 16 : nil }
    var title: String {
        switch self {
        case .freeCanvas: return "自由画布"
        case .longStitch: return "长图拼接"
        case .gridCollage: return "标准拼图"
        case .compression: return "图片压缩（已移出）"
        }
    }
    var systemImage: String {
        switch self {
        case .freeCanvas: return "rectangle.on.rectangle"
        case .longStitch: return "rectangle.split.1x2"
        case .gridCollage: return "square.grid.2x2"
        case .compression: return "arrow.down.right.and.arrow.up.left"
        }
    }
}

nonisolated struct ProjectAsset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var fileName: String
    var name: String
    var position: CGPoint
    var groupID: UUID?
    // Retain identity and originals so export history and undo remain valid after removal.
    var isRemoved: Bool = false

    init(id: UUID, fileName: String, name: String, position: CGPoint, groupID: UUID? = nil, isRemoved: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.name = name
        self.position = position
        self.groupID = groupID
        self.isRemoved = isRemoved
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, name, position, groupID, isRemoved
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fileName = try values.decode(String.self, forKey: .fileName)
        name = try values.decode(String.self, forKey: .name)
        position = try values.decode(CGPoint.self, forKey: .position)
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        // Old ratings and color labels are deliberately ignored when reading existing projects.
        isRemoved = try values.decodeIfPresent(Bool.self, forKey: .isRemoved) ?? false
    }
}

/// Shared by drawing, imports and layout edits so a card always has the same footprint.
nonisolated struct ProjectMaterialLayout: Sendable {
    static let thumbnailRange: ClosedRange<Double> = 48...240
    let thumbnailSize: CGFloat
    let gap: CGFloat = 16

    init(thumbnailSize: CGFloat) {
        self.thumbnailSize = thumbnailSize.isFinite
            ? min(CGFloat(Self.thumbnailRange.upperBound), max(CGFloat(Self.thumbnailRange.lowerBound), thumbnailSize))
            : 128
    }

    var cardSize: CGSize { CGSize(width: thumbnailSize + 16, height: thumbnailSize + 40) }
    var columnStride: CGFloat { cardSize.width + gap }
    var rowStride: CGFloat { cardSize.height + gap }

    static func ordered(_ assets: [ProjectAsset]) -> [ProjectAsset] {
        assets.sorted { left, right in
            if left.position.y != right.position.y { return left.position.y < right.position.y }
            if left.position.x != right.position.x { return left.position.x < right.position.x }
            return left.id.uuidString < right.id.uuidString
        }
    }

    func rescaledPosition(_ point: CGPoint, from previous: ProjectMaterialLayout) -> CGPoint {
        CGPoint(x: point.x * columnStride / previous.columnStride,
                y: point.y * rowStride / previous.rowStride)
    }
}

nonisolated struct ProjectExportRecord: Identifiable, Codable, Sendable {
    var id: UUID
    var operation: ProjectOperation
    var assetIDs: [UUID]
    var createdAt: Date
    var outputPath: String
}

nonisolated struct ProjectPhotoGroup: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var assetIDs: [UUID]
}

nonisolated struct ProjectDocument: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var assets: [ProjectAsset]
    var exports: [ProjectExportRecord]
    var thumbnailSize: Double
    var groupThumbnailSize: Double
    var thumbnailSizesLinked: Bool
    // Separate from thumbnail geometry so browsing never changes saved asset positions.
    var viewZoom: Double? = nil
    var groups: [ProjectPhotoGroup]
    // Includes grouped and removed identities so returning photos keeps their material order.
    var materialOrder: [UUID]

    var activeAssets: [ProjectAsset] { assets.filter { !$0.isRemoved } }
    var orderedActiveAssets: [ProjectAsset] {
        let byID = Dictionary(uniqueKeysWithValues: assets.filter { !$0.isRemoved }.map { ($0.id, $0) })
        return materialOrder.compactMap { byID[$0] }
    }

    init(id: UUID, name: String, createdAt: Date, modifiedAt: Date, assets: [ProjectAsset],
         exports: [ProjectExportRecord], thumbnailSize: Double, viewZoom: Double? = nil,
         groups: [ProjectPhotoGroup]? = nil, groupThumbnailSize: Double? = nil,
         thumbnailSizesLinked: Bool = true, materialOrder: [UUID]? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.assets = assets
        self.exports = exports
        self.thumbnailSize = thumbnailSize
        self.groupThumbnailSize = groupThumbnailSize ?? thumbnailSize
        self.thumbnailSizesLinked = thumbnailSizesLinked
        self.viewZoom = viewZoom
        self.groups = groups ?? Self.migratedGroups(assets)
        self.materialOrder = materialOrder ?? ProjectMaterialLayout.ordered(assets).map(\.id)
        synchronizeGroups()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, modifiedAt, assets, exports, thumbnailSize, viewZoom, groups
        case groupThumbnailSize, thumbnailSizesLinked, materialOrder
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        assets = try values.decode([ProjectAsset].self, forKey: .assets)
        exports = try values.decode([ProjectExportRecord].self, forKey: .exports)
        thumbnailSize = try values.decode(Double.self, forKey: .thumbnailSize)
        groupThumbnailSize = try values.decodeIfPresent(Double.self, forKey: .groupThumbnailSize) ?? thumbnailSize
        thumbnailSizesLinked = try values.decodeIfPresent(Bool.self, forKey: .thumbnailSizesLinked) ?? true
        viewZoom = try values.decodeIfPresent(Double.self, forKey: .viewZoom)
        groups = try values.decodeIfPresent([ProjectPhotoGroup].self, forKey: .groups) ?? Self.migratedGroups(assets)
        materialOrder = try values.decodeIfPresent([UUID].self, forKey: .materialOrder)
            ?? ProjectMaterialLayout.ordered(assets).map(\.id)
        synchronizeGroups()
    }

    private static func migratedGroups(_ assets: [ProjectAsset]) -> [ProjectPhotoGroup] {
        var result: [ProjectPhotoGroup] = []
        var indices: [UUID: Int] = [:]
        for asset in ProjectMaterialLayout.ordered(assets) where !asset.isRemoved {
            guard let groupID = asset.groupID else { continue }
            if let index = indices[groupID] {
                result[index].assetIDs.append(asset.id)
            } else {
                indices[groupID] = result.count
                result.append(ProjectPhotoGroup(id: groupID, assetIDs: [asset.id]))
            }
        }
        return result
    }

    /// Membership is stored once in row order; asset flags remain compatible with older projects.
    mutating func synchronizeGroups() {
        let activeIDs = Set(assets.lazy.filter { !$0.isRemoved }.map(\.id))
        var membership: [UUID: UUID] = [:]
        var seenGroups: Set<UUID> = []
        groups = groups.compactMap { group in
            guard seenGroups.insert(group.id).inserted else { return nil }
            let ids = group.assetIDs.filter { id in
                guard activeIDs.contains(id), membership[id] == nil else { return false }
                membership[id] = group.id
                return true
            }
            return ids.isEmpty ? nil : ProjectPhotoGroup(id: group.id, assetIDs: ids)
        }
        for index in assets.indices { assets[index].groupID = membership[assets[index].id] }
        synchronizeMaterialOrder()
    }

    mutating func synchronizeMaterialOrder() {
        let validIDs = Set(assets.map(\.id))
        var seen: Set<UUID> = []
        materialOrder = materialOrder.filter { validIDs.contains($0) && seen.insert($0).inserted }
        for asset in assets where seen.insert(asset.id).inserted { materialOrder.append(asset.id) }
    }
}

nonisolated private struct ProjectEditSnapshot: Sendable {
    var assets: [ProjectAsset]
    var groups: [ProjectPhotoGroup]
    var materialOrder: [UUID]
}

/// Serial writes preserve edit order without encoding or disk access on the interaction thread.
nonisolated private final class ProjectMetadataWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aoistitcher.project-metadata", qos: .utility)
    private var failures: [UUID: String] = [:] // Accessed only on queue.

    func enqueue(_ document: ProjectDocument, at url: URL, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                try Self.write(document, at: url)
                self.failures[document.id] = nil
                completion(nil)
            } catch {
                var message = error.localizedDescription
                do {
                    let recoveryURL = url.deletingLastPathComponent().appendingPathComponent("project.unsaved.json")
                    try JSONEncoder().encode(document).write(to: recoveryURL, options: .atomic)
                    message += " 最新修改已另存至 project.unsaved.json。"
                } catch {
                    message += " 备份也未能写入：\(error.localizedDescription)"
                }
                self.failures[document.id] = message
                completion(message)
            }
        }
    }

    func flush() -> [String] { queue.sync { Array(failures.values) } }
    func failedProjectIDs() -> [UUID] { queue.sync { Array(failures.keys) } }

    static func write(_ document: ProjectDocument, at url: URL) throws {
        // A damaged file is never silently replaced by an older in-memory snapshot.
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
            try ProjectLibraryStore.validate(previous, expectedID: document.id)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("project.unsaved.json"))
    }
}

nonisolated struct ProjectSummary: Identifiable, Sendable {
    var id: UUID
    var name: String
    var modifiedAt: Date
    var assetCount: Int
}

/// Captured with the editor's export snapshot, before the save panel or rendering starts.
nonisolated struct ProjectExportContext: Sendable {
    let projectID: UUID
    let operation: ProjectOperation
    let assetIDs: [UUID]
}

nonisolated private enum ProjectLibraryError: LocalizedError {
    case invalidMetadata
    case notAnImage

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "项目资料格式有误，已保留原文件。"
        case .notAnImage: return "无法读取图片。"
        }
    }
}

nonisolated private struct ProjectImportResult: Sendable {
    var assets: [ProjectAsset]
    var failures: [String]
    var failureCount = 0

    mutating func recordFailure(_ description: String) {
        failureCount += 1
        if failures.count < 8 { failures.append(description) }
    }

    var failureDescription: String {
        failures.joined(separator: "、") + (failureCount > failures.count ? "等，共 \(failureCount) 项" : "")
    }
}

nonisolated private struct ProjectImportRequest: Sendable {
    let projectID: UUID
    let urls: [URL]
    let point: CGPoint?
    let securityScopes: [URL]
    let viewportWidth: CGFloat
    let viewZoom: CGFloat
}

/// Thumbnail arrivals refresh only views that display previews, not every mounted editor.
@MainActor final class ProjectThumbnailUpdates: ObservableObject {
    func invalidate() { objectWillChange.send() }
}

@MainActor final class ProjectLibraryStore: ObservableObject {
    nonisolated static let projectsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("aoipic/Projects", isDirectory: true)
    }()

    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var currentProject: ProjectDocument?
    @Published private(set) var isImporting = false
    @Published var message: String?
    let thumbnailUpdates = ProjectThumbnailUpdates()

    // Updated by the material board; these are viewport measurements, not project edits.
    var boardViewportWidth: CGFloat = 800
    var boardViewZoom: CGFloat = 1

    private let directory: URL
    private var editHistory: [UUID: [ProjectEditSnapshot]] = [:]
    private var documents: [UUID: ProjectDocument] = [:]
    private let metadataWriter = ProjectMetadataWriter()
    private var saveObservers: Set<AnyCancellable> = []
    private let thumbnails = NSCache<NSString, NSImage>()
    private let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.aoistitcher.project-thumbnails"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var thumbnailRequests: Set<String> = []
    private var failedThumbnails: Set<String> = []
    private var thumbnailNotificationScheduled = false
    private var importQueue: [ProjectImportRequest] = []

    var canUndoEdit: Bool {
        guard let id = currentProject?.id else { return false }
        return !(editHistory[id]?.isEmpty ?? true)
    }

    init(projectsDirectory: URL = ProjectLibraryStore.projectsDirectory) {
        directory = projectsDirectory
        thumbnails.countLimit = 2_000
        thumbnails.totalCostLimit = 128 * 1024 * 1024
        refreshProjects()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.willCloseNotification))
            .sink { [weak self] _ in _ = self?.flushPendingSaves() }
            .store(in: &saveObservers)
    }

    deinit {
        _ = metadataWriter.flush()
        thumbnailQueue.cancelAllOperations()
        for request in importQueue {
            request.securityScopes.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    func refreshProjects() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entries = try FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles])
            var summaries: [ProjectSummary] = []
            var failures = 0
            for entry in entries {
                guard let id = UUID(uuidString: entry.lastPathComponent),
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                do { summaries.append(summary(try readDocument(id: id))) }
                catch { failures += 1 }
            }
            projects = summaries.sorted { $0.modifiedAt > $1.modifiedAt }
            if failures > 0 { message = "有 \(failures) 个项目资料无法读取，原文件已保留在项目目录中。" }
        } catch {
            message = "读取项目列表失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func createProject(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let document = ProjectDocument(id: UUID(), name: trimmed.isEmpty ? "未命名项目" : trimmed,
                                       createdAt: now, modifiedAt: now, assets: [], exports: [], thumbnailSize: 128)
        do {
            try FileManager.default.createDirectory(at: assetDirectory(projectID: document.id), withIntermediateDirectories: true)
            try Self.validate(document, expectedID: document.id)
            try ProjectMetadataWriter.write(document, at: metadataURL(id: document.id))
            documents[document.id] = document
            currentProject = document
            boardViewZoom = 1
            updateSummary(document)
            return true
        } catch {
            message = "新建项目失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func createProject(importing urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else {
            message = "请拖入图片或包含图片的文件夹。"
            return false
        }
        let first = files[0]
        let namingScope = first.startAccessingSecurityScopedResource()
        defer { if namingScope { first.stopAccessingSecurityScopedResource() } }
        let isDirectory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let name: String
        if files.count == 1 && isDirectory {
            name = first.lastPathComponent
        } else if files.allSatisfy({ $0.deletingLastPathComponent() == first.deletingLastPathComponent() }) {
            name = first.deletingLastPathComponent().lastPathComponent
        } else {
            name = "未命名项目"
        }
        guard createProject(name: name) else { return false }
        importURLs(files)
        return true
    }

    func openProject(id: UUID) {
        do {
            var document = try readDocument(id: id)
            document.modifiedAt = Date()
            do { try saveDocument(document) }
            catch { message = "项目已打开，但最近打开时间未能保存：\(error.localizedDescription)" }
            currentProject = document
            boardViewZoom = CGFloat(document.viewZoom ?? 1)
            failedThumbnails.removeAll()
            updateSummary(document)
        } catch {
            message = "打开项目失败：\(error.localizedDescription)"
        }
    }

    func closeProject() {
        guard flushPendingSaves() else { return }
        currentProject = nil
    }

    @discardableResult
    func flushPendingSaves() -> Bool {
        for id in metadataWriter.failedProjectIDs() {
            if let document = documents[id] { try? saveDocument(document) }
        }
        let failures = metadataWriter.flush()
        guard failures.isEmpty else {
            message = "项目尚未保存成功，当前修改仍保留在内存中：\(failures.joined(separator: "；"))"
            return false
        }
        return true
    }

    func importPanel() {
        guard currentProject != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "导入素材"
        panel.message = "选择图片或文件夹（包含子文件夹）。原图会复制到当前项目，之后移动原文件也不会影响项目素材。"
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    func importURLs(_ urls: [URL], at point: CGPoint? = nil) {
        guard let projectID = currentProject?.id, !urls.isEmpty else { return }
        let safePoint = point.flatMap { point in
            point.x.isFinite && point.y.isFinite ? CGPoint(x: max(0, point.x), y: max(0, point.y)) : nil
        }
        let securityScopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        importQueue.append(ProjectImportRequest(projectID: projectID, urls: urls, point: safePoint,
                                                securityScopes: securityScopes,
                                                viewportWidth: boardViewportWidth, viewZoom: boardViewZoom))
        startNextImportIfNeeded()
    }

    private func startNextImportIfNeeded() {
        guard !isImporting, !importQueue.isEmpty else { return }
        let request = importQueue.removeFirst()
        let projectID = request.projectID
        let destination = assetDirectory(projectID: projectID)
        let protectedDirectories = [Self.projectsDirectory, directory]
        isImporting = true
        // Keep the project store alive if its window closes during background copying.
        Task { [self] in
            let result = await Task.detached(priority: .userInitiated) {
                defer { request.securityScopes.forEach { $0.stopAccessingSecurityScopedResource() } }
                return Self.copyImages(request.urls, to: destination, excluding: protectedDirectories)
            }.value
            do {
                // Load the project that initiated this import, even if the user has since opened another.
                var document = try self.readDocument(id: projectID)
                if !result.assets.isEmpty {
                    let cardHeight = ProjectMaterialLayout(thumbnailSize: CGFloat(document.thumbnailSize)).cardSize.height
                    let start = request.point
                        ?? CGPoint(x: 24, y: document.activeAssets.isEmpty ? 24 : (document.activeAssets.map(\.position.y).max() ?? 24) + cardHeight + 24)
                    // A homepage drop can start before its board has been laid out. Use the live
                    // viewport after scanning when this project is still on screen.
                    let isCurrentProject = self.currentProject?.id == projectID
                    let viewportWidth = isCurrentProject ? self.boardViewportWidth : request.viewportWidth
                    let viewZoom = isCurrentProject ? self.boardViewZoom : request.viewZoom
                    let layout = self.assetLayout(thumbnailSize: document.thumbnailSize, viewportWidth: viewportWidth,
                                                  zoom: viewZoom, startX: start.x)
                    for (index, var asset) in result.assets.enumerated() {
                        asset.position = CGPoint(x: start.x + CGFloat(index % layout.columns) * layout.columnStride,
                                                 y: start.y + CGFloat(index / layout.columns) * layout.rowStride)
                        document.assets.append(asset)
                        document.materialOrder.append(asset.id)
                    }
                    document.modifiedAt = Date()
                    try self.saveDocument(document)
                    if self.currentProject?.id == projectID { self.currentProject = document }
                    self.updateSummary(document)
                }
                if result.failureCount > 0 {
                    self.message = "已导入 \(result.assets.count) 张；\(result.failureDescription)"
                } else if result.assets.isEmpty {
                    self.message = "未找到可导入的图片。请选择图片或包含图片的文件夹。"
                }
            } catch {
                // Copied originals remain recoverable if the metadata write fails.
                self.message = "保存导入资料失败：\(error.localizedDescription) 已复制的原图仍保留在项目目录中。"
            }
            self.isImporting = false
            self.startNextImportIfNeeded()
        }
    }

    func assetURL(_ asset: ProjectAsset) -> URL {
        guard let projectID = currentProject?.id else {
            return directory.appendingPathComponent(asset.fileName)
        }
        return assetDirectory(projectID: projectID).appendingPathComponent(asset.fileName)
    }

    func thumbnail(for asset: ProjectAsset, maximumPixelSize: Int = 256) -> NSImage? {
        guard let projectID = currentProject?.id else { return nil }
        let pixelSize = maximumPixelSize <= 64 ? 64 : (maximumPixelSize <= 128 ? 128 : 256)
        let key = "\(projectID.uuidString)/\(asset.id.uuidString)/\(pixelSize)"
        if let cached = thumbnails.object(forKey: key as NSString) { return cached }
        guard !failedThumbnails.contains(key), thumbnailRequests.insert(key).inserted else { return nil }
        let url = assetURL(asset)
        thumbnailQueue.addOperation { [weak self] in
            let image = Self.readThumbnail(url, maximum: pixelSize)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.thumbnailRequests.remove(key)
                guard let image else {
                    self.failedThumbnails.insert(key)
                    return
                }
                let preview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                self.thumbnails.setObject(preview, forKey: key as NSString, cost: image.bytesPerRow * image.height)
                self.scheduleThumbnailNotification()
            }
        }
        return nil
    }

    private func scheduleThumbnailNotification() {
        guard !thumbnailNotificationScheduled else { return }
        thumbnailNotificationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.thumbnailNotificationScheduled = false
            self.thumbnailUpdates.invalidate()
        }
    }

    private func editDocument(_ change: (inout ProjectDocument) -> Void) {
        guard var document = documentForEditing() else { return }
        var previous = ProjectEditSnapshot(assets: document.assets, groups: document.groups,
                                           materialOrder: document.materialOrder)
        change(&document)
        document.synchronizeGroups()
        guard document.assets != previous.assets || document.groups != previous.groups
                || document.materialOrder != previous.materialOrder,
              commitCurrent(document) else { return }
        previous.assets = zip(previous.assets, document.assets).compactMap { old, new in old == new ? nil : old }
        editHistory[document.id, default: []].append(previous)
        if editHistory[document.id, default: []].count > 50 { editHistory[document.id]?.removeFirst() }
    }

    func moveAssets(_ positions: [UUID: CGPoint]) {
        guard !positions.isEmpty else { return }
        editDocument { document in
            for index in document.assets.indices {
                let asset = document.assets[index]
                guard !asset.isRemoved, asset.groupID == nil,
                      let point = positions[asset.id], point.x.isFinite, point.y.isFinite else { continue }
                document.assets[index].position = CGPoint(x: max(0, point.x), y: max(0, point.y))
            }
        }
    }

    /// Reorder only the displayed subset. Filtered, grouped and removed slots retain their place.
    func reorderMaterials(_ orderedVisibleIDs: [UUID]) {
        guard !orderedVisibleIDs.isEmpty else { return }
        editDocument { document in
            let requested = Set(orderedVisibleIDs)
            let eligible = Set(document.activeAssets.filter { $0.groupID == nil }.map(\.id))
            guard requested.count == orderedVisibleIDs.count, requested.isSubset(of: eligible) else { return }
            var replacement = orderedVisibleIDs.makeIterator()
            document.materialOrder = document.materialOrder.map { id in
                requested.contains(id) ? replacement.next()! : id
            }
        }
    }

    @discardableResult
    func createGroup(_ ids: Set<UUID>) -> UUID? {
        guard let document = currentProject else { return nil }
        let chosen = document.orderedActiveAssets.filter { ids.contains($0.id) }
        guard chosen.count >= 2 else { return nil }
        let groupID = UUID()
        let memberIDs = chosen.map(\.id)
        let membership = Set(memberIDs)
        editDocument { document in
            for index in document.groups.indices { document.groups[index].assetIDs.removeAll { membership.contains($0) } }
            document.groups.append(ProjectPhotoGroup(id: groupID, assetIDs: memberIDs))
        }
        return currentProject?.groups.contains(where: { $0.id == groupID }) == true ? groupID : nil
    }

    func gatherAssets(_ ids: Set<UUID>, at point: CGPoint) {
        createGroup(ids)
    }

    func ungroupAssets(_ ids: Set<UUID>) {
        guard let document = currentProject else { return }
        let groupIDs = Set(document.activeAssets.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !groupIDs.isEmpty else { return }
        editDocument { $0.groups.removeAll { groupIDs.contains($0.id) } }
    }

    func returnAssetsToMaterials(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        editDocument { document in
            for index in document.groups.indices { document.groups[index].assetIDs.removeAll { ids.contains($0) } }
        }
    }

    func dissolveGroup(_ id: UUID) {
        editDocument { $0.groups.removeAll { $0.id == id } }
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        editDocument { document in
            guard let index = document.groups.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard document.groups.indices.contains(target), target != index else { return }
            let group = document.groups.remove(at: index)
            document.groups.insert(group, at: target)
        }
    }

    func moveGroupAsset(_ assetID: UUID, in groupID: UUID, by offset: Int) {
        guard let group = currentProject?.groups.first(where: { $0.id == groupID }),
              let index = group.assetIDs.firstIndex(of: assetID) else { return }
        var ids = group.assetIDs
        let target = index + offset
        guard ids.indices.contains(target), target != index else { return }
        ids.remove(at: index)
        ids.insert(assetID, at: target)
        setGroupAssetOrder(ids, in: groupID)
    }

    func setGroupAssetOrder(_ ids: [UUID], in groupID: UUID) {
        editDocument { document in
            guard let index = document.groups.firstIndex(where: { $0.id == groupID }),
                  Set(ids) == Set(document.groups[index].assetIDs), ids.count == document.groups[index].assetIDs.count else { return }
            document.groups[index].assetIDs = ids
        }
    }

    func addAssets(_ ids: Set<UUID>, to groupID: UUID) {
        editDocument { document in
            guard let target = document.groups.firstIndex(where: { $0.id == groupID }) else { return }
            let existing = Set(document.groups[target].assetIDs)
            let additions = document.orderedActiveAssets.filter { ids.contains($0.id) && !existing.contains($0.id) }.map(\.id)
            guard !additions.isEmpty else { return }
            let moving = Set(additions)
            for index in document.groups.indices { document.groups[index].assetIDs.removeAll { moving.contains($0) } }
            document.groups[target].assetIDs.append(contentsOf: additions)
        }
    }

    func removeAssets(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        editDocument { document in
            for index in document.assets.indices where ids.contains(document.assets[index].id) {
                document.assets[index].isRemoved = true
            }
        }
    }

    func undoLastEdit() {
        guard var document = documentForEditing(), let previous = editHistory[document.id]?.last else { return }
        let byID = Dictionary(uniqueKeysWithValues: previous.assets.map { ($0.id, $0) })
        for index in document.assets.indices {
            if let asset = byID[document.assets[index].id] { document.assets[index] = asset }
        }
        document.groups = previous.groups
        let previousIDs = Set(previous.materialOrder)
        document.materialOrder = previous.materialOrder + document.materialOrder.filter { !previousIDs.contains($0) }
        document.synchronizeGroups()
        guard commitCurrent(document) else { return }
        editHistory[document.id]?.removeLast()
    }

    func arrangeAssets(viewportWidth: CGFloat, zoom: CGFloat) {
        guard let document = currentProject else { return }
        let layout = assetLayout(thumbnailSize: document.thumbnailSize, viewportWidth: viewportWidth, zoom: zoom, startX: 24)
        let ordered = document.orderedActiveAssets.filter { $0.groupID == nil }
        let positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, asset in
            (asset.id, CGPoint(x: 24 + CGFloat(index % layout.columns) * layout.columnStride,
                               y: 24 + CGFloat(index / layout.columns) * layout.rowStride))
        })
        moveAssets(positions)
    }

    private func assetLayout(thumbnailSize: Double, viewportWidth: CGFloat, zoom: CGFloat, startX: CGFloat)
        -> (columns: Int, columnStride: CGFloat, rowStride: CGFloat) {
        let layout = ProjectMaterialLayout(thumbnailSize: CGFloat(thumbnailSize))
        let safeWidth = viewportWidth.isFinite ? max(1, viewportWidth) : 800
        let safeZoom = zoom.isFinite ? min(2, max(0.02, zoom)) : 1
        // The board adds 24 screen points on each side, outside the scaled logical coordinates.
        let availableWidth = max(layout.cardSize.width, (safeWidth - 48) / safeZoom - startX)
        // A pathological screen measurement should never overflow the integer conversion.
        let columns = max(1, Int(min(10_000, floor((availableWidth + layout.gap) / layout.columnStride))))
        return (columns, layout.columnStride, layout.rowStride)
    }

    func setViewZoom(_ value: Double) {
        guard value.isFinite, var document = documentForEditing() else { return }
        let clamped = min(2, max(0.02, value))
        boardViewZoom = CGFloat(clamped)
        guard document.viewZoom != clamped else { return }
        document.viewZoom = clamped
        _ = commitCurrent(document)
    }

    func setThumbnailSize(_ size: Double) {
        setThumbnailSize(size, forGroup: false)
    }

    func setGroupThumbnailSize(_ size: Double) {
        setThumbnailSize(size, forGroup: true)
    }

    func setThumbnailSizesLinked(_ linked: Bool) {
        guard var document = documentForEditing(), document.thumbnailSizesLinked != linked else { return }
        // Relocking preserves both current values; the next slider gesture chooses the shared size.
        document.thumbnailSizesLinked = linked
        _ = commitCurrent(document)
    }

    private func setThumbnailSize(_ size: Double, forGroup: Bool) {
        guard size.isFinite, var document = documentForEditing() else { return }
        let clamped = min(ProjectMaterialLayout.thumbnailRange.upperBound,
                          max(ProjectMaterialLayout.thumbnailRange.lowerBound, size))
        let updatesMaterials = !forGroup || document.thumbnailSizesLinked
        let updatesGroups = forGroup || document.thumbnailSizesLinked
        let leftSize = updatesMaterials ? clamped : document.thumbnailSize
        let rightSize = updatesGroups ? clamped : document.groupThumbnailSize
        let leftSizeChanged = document.thumbnailSize != leftSize
        guard leftSizeChanged || document.groupThumbnailSize != rightSize
                || (updatesMaterials && (document.viewZoom ?? 1) != 1) else { return }
        let previousLayout = ProjectMaterialLayout(thumbnailSize: CGFloat(document.thumbnailSize))
        let layout = ProjectMaterialLayout(thumbnailSize: CGFloat(leftSize))
        if leftSizeChanged {
            for index in document.assets.indices {
                document.assets[index].position = layout.rescaledPosition(document.assets[index].position, from: previousLayout)
            }
        }
        document.thumbnailSize = leftSize
        document.groupThumbnailSize = rightSize
        if updatesMaterials { document.viewZoom = 1 }
        guard commitCurrent(document) else { return }
        if updatesMaterials { boardViewZoom = 1 }
        // Undo restores edits in today's card geometry, even after the thumbnail slider changes.
        if leftSizeChanged, let history = editHistory[document.id] {
            editHistory[document.id] = history.map { snapshot in
                var snapshot = snapshot
                snapshot.assets = snapshot.assets.map { asset in
                    var asset = asset
                    asset.position = layout.rescaledPosition(asset.position, from: previousLayout)
                    return asset
                }
                return snapshot
            }
        }
    }

    func captureExport(operation: ProjectOperation, sourceURLs: [URL]) -> ProjectExportContext? {
        guard let document = currentProject else { return nil }
        var byPath: [String: UUID] = [:]
        for asset in document.assets {
            byPath[assetURL(asset).standardizedFileURL.resolvingSymlinksInPath().path] = asset.id
        }
        var seen: Set<UUID> = []
        let ids = sourceURLs.compactMap { url -> UUID? in
            guard let id = byPath[url.standardizedFileURL.resolvingSymlinksInPath().path], seen.insert(id).inserted else { return nil }
            return id
        }
        guard !ids.isEmpty else { return nil }
        return ProjectExportContext(projectID: document.id, operation: operation, assetIDs: ids)
    }

    func recordExport(_ context: ProjectExportContext, outputURL: URL) {
        do {
            var document = try readDocument(id: context.projectID)
            let validIDs = Set(document.assets.map(\.id))
            let ids = context.assetIDs.filter { validIDs.contains($0) }
            guard !ids.isEmpty else { return }
            document.exports.append(ProjectExportRecord(id: UUID(), operation: context.operation, assetIDs: ids,
                                                         createdAt: Date(), outputPath: outputURL.path))
            document.modifiedAt = Date()
            try saveDocument(document)
            if currentProject?.id == document.id { currentProject = document }
            updateSummary(document)
        } catch {
            message = "图片已导出，但用途记录保存失败：\(error.localizedDescription)"
        }
    }

    func exports(for assetID: UUID) -> [ProjectExportRecord] {
        (currentProject?.exports ?? []).filter { $0.assetIDs.contains(assetID) }.sorted { $0.createdAt > $1.createdAt }
    }

    private func commitCurrent(_ updated: ProjectDocument) -> Bool {
        var document = updated
        document.modifiedAt = Date()
        do {
            try saveDocument(document)
            currentProject = document
            updateSummary(document)
            return true
        } catch {
            message = "保存项目失败：\(error.localizedDescription)"
            return false
        }
    }

    private func documentForEditing() -> ProjectDocument? {
        currentProject
    }

    private func summary(_ document: ProjectDocument) -> ProjectSummary {
        ProjectSummary(id: document.id, name: document.name, modifiedAt: document.modifiedAt, assetCount: document.activeAssets.count)
    }

    private func updateSummary(_ document: ProjectDocument) {
        projects.removeAll { $0.id == document.id }
        projects.append(summary(document))
        projects.sort { $0.modifiedAt > $1.modifiedAt }
    }

    private func projectDirectory(id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func assetDirectory(projectID: UUID) -> URL {
        projectDirectory(id: projectID).appendingPathComponent("Originals", isDirectory: true)
    }
    private func metadataURL(id: UUID) -> URL {
        projectDirectory(id: id).appendingPathComponent("project.json")
    }

    private func readDocument(id: UUID) throws -> ProjectDocument {
        if let document = documents[id] { return document }
        let url = metadataURL(id: id)
        let recoveryURL = url.deletingLastPathComponent().appendingPathComponent("project.unsaved.json")
        let primary = Result { () throws -> ProjectDocument in
            let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
            try Self.validate(document, expectedID: id)
            return document
        }
        if FileManager.default.fileExists(atPath: recoveryURL.path),
           let recovery = try? JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: recoveryURL)),
           (try? Self.validate(recovery, expectedID: id)) != nil,
           (try? primary.get()).map({ recovery.modifiedAt > $0.modifiedAt }) ?? true {
            documents[id] = recovery
            message = "已恢复「\(recovery.name)」上次未保存的修改。原项目资料仍保留，请检查存储位置是否可写。"
            return recovery
        }
        let document = try primary.get()
        documents[id] = document
        return document
    }

    private func saveDocument(_ document: ProjectDocument) throws {
        try Self.validate(document, expectedID: document.id)
        documents[document.id] = document
        let url = metadataURL(id: document.id)
        metadataWriter.enqueue(document, at: url) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.message = "保存项目失败，当前修改仍保留在内存中：\(error)"
            }
        }
    }

    nonisolated fileprivate static func validate(_ document: ProjectDocument, expectedID: UUID) throws {
        let assetIDs = Set(document.assets.map(\.id))
        let groupedIDs = document.groups.flatMap(\.assetIDs)
        guard document.id == expectedID,
              document.thumbnailSize.isFinite, ProjectMaterialLayout.thumbnailRange.contains(document.thumbnailSize),
              document.groupThumbnailSize.isFinite, ProjectMaterialLayout.thumbnailRange.contains(document.groupThumbnailSize),
              document.viewZoom.map({ $0.isFinite && (0.02...2).contains($0) }) ?? true,
              assetIDs.count == document.assets.count,
              document.materialOrder.count == assetIDs.count, Set(document.materialOrder) == assetIDs,
              Set(document.assets.map(\.fileName)).count == document.assets.count,
              Set(document.exports.map(\.id)).count == document.exports.count,
              Set(document.groups.map(\.id)).count == document.groups.count,
              Set(groupedIDs).count == groupedIDs.count,
              document.groups.allSatisfy({ !$0.assetIDs.isEmpty && $0.assetIDs.allSatisfy { assetIDs.contains($0) } }),
              document.assets.allSatisfy({ asset in
                  !asset.fileName.isEmpty && asset.fileName != "." && asset.fileName != ".." &&
                  !asset.fileName.contains("/") && !asset.fileName.contains("\\") &&
                  asset.position.x.isFinite && asset.position.y.isFinite && asset.position.x >= 0 && asset.position.y >= 0
              }),
              document.exports.allSatisfy({ record in
                  !record.assetIDs.isEmpty && record.assetIDs.allSatisfy { assetIDs.contains($0) }
              }) else { throw ProjectLibraryError.invalidMetadata }
    }

    nonisolated private static func copyImages(_ urls: [URL], to directory: URL, excluding protectedDirectories: [URL]) -> ProjectImportResult {
        var result = ProjectImportResult(assets: [], failures: [])
        let manager = FileManager.default
        let protectedPaths = protectedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                .isHiddenKey, .isPackageKey, .contentTypeKey]
        var imageURLs: [URL] = []
        var seenFiles: Set<String> = []
        var scannedDirectories: [String: Int] = [:]

        func collectImages(at url: URL, isRoot: Bool) -> Int {
            guard url.isFileURL else {
                if isRoot { result.recordFailure("\(url.lastPathComponent)：不是本地文件") }
                return 0
            }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !protectedPaths.contains(where: { canonical.path == $0 || canonical.path.hasPrefix($0 + "/") }) else {
                if isRoot { result.recordFailure("\(url.lastPathComponent)：不能导入应用的项目资料目录") }
                return 0
            }
            do {
                let values = try url.resourceValues(forKeys: resourceKeys)
                guard values.isHidden != true, !url.lastPathComponent.hasPrefix(".") else { return 0 }
                guard values.isSymbolicLink != true else {
                    if isRoot { result.recordFailure("\(url.lastPathComponent)：请导入原文件，而非符号链接") }
                    return 0
                }
                if values.isDirectory == true {
                    guard values.isPackage != true else {
                        if isRoot { result.recordFailure("\(url.lastPathComponent)：不导入应用或资料包") }
                        return 0
                    }
                    if let count = scannedDirectories[canonical.path] { return count }
                    // Reserve before descending, even though symbolic links are skipped.
                    scannedDirectories[canonical.path] = 0
                    let children = try manager.contentsOfDirectory(at: url,
                                                                    includingPropertiesForKeys: Array(resourceKeys),
                                                                    options: [.skipsHiddenFiles])
                        .sorted { left, right in
                            let order = left.lastPathComponent.localizedStandardCompare(right.lastPathComponent)
                            return order == .orderedSame ? left.path < right.path : order == .orderedAscending
                        }
                    let failureCount = result.failureCount
                    let count = children.reduce(0) { $0 + collectImages(at: $1, isRoot: false) }
                    scannedDirectories[canonical.path] = count
                    if isRoot && count == 0 && result.failureCount == failureCount {
                        result.recordFailure("\(url.lastPathComponent)：文件夹中没有可导入的图片")
                    }
                    return count
                }
                guard values.isRegularFile == true else { return 0 }
                let recognizedImage: Bool
                if values.contentType?.conforms(to: .image) == true {
                    recognizedImage = true
                } else if let source = CGImageSourceCreateWithURL(url as CFURL,
                                                                  [kCGImageSourceShouldCache: false] as CFDictionary),
                          let type = CGImageSourceGetType(source) {
                    recognizedImage = UTType(type as String)?.conforms(to: .image) == true
                } else {
                    recognizedImage = false
                }
                guard recognizedImage else {
                    if isRoot { result.recordFailure("\(url.lastPathComponent)：不是支持的图片") }
                    return 0
                }
                if seenFiles.insert(canonical.path).inserted { imageURLs.append(url) }
                return 1
            } catch {
                result.recordFailure("\(url.lastPathComponent)：无法读取")
                return 0
            }
        }

        for url in urls { _ = collectImages(at: url, isRoot: true) }
        guard !imageURLs.isEmpty else { return result }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch {
            result.recordFailure("无法创建项目素材目录：\(error.localizedDescription)")
            return result
        }
        for url in imageURLs {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL, readThumbnail(url, maximum: 64) != nil else { throw ProjectLibraryError.notAnImage }
                let id = UUID()
                let extensionPart = String(url.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(16))
                let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
                let fileName = id.uuidString + suffix
                try FileManager.default.copyItem(at: url.resolvingSymlinksInPath(),
                                                 to: directory.appendingPathComponent(fileName))
                result.assets.append(ProjectAsset(id: id, fileName: fileName, name: url.lastPathComponent, position: .zero))
            } catch { result.recordFailure("\(url.lastPathComponent)：无法导入") }
        }
        return result
    }

    nonisolated private static func readThumbnail(_ url: URL, maximum: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximum,
                                      kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
