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
    /// The original source is retained for duplicate detection. These are optional so
    /// projects written before duplicate protection remain fully readable.
    var sourcePath: String?
    var sourceFileSize: UInt64?
    /// Changes only when the original is replaced, so browsing can retain a
    /// decoded preview without confusing a replacement with the old image.
    var contentRevision: UUID?
    var position: CGPoint
    var groupID: UUID?
    // Retain identity and originals so export history and undo remain valid after removal.
    var isRemoved: Bool = false
    /// Reference assets read the untouched original at `sourcePath` directly;
    /// legacy copy assets keep reading the duplicate stored in the project's
    /// Originals folder. Defaults to false so old projects decode unchanged.
    var isReference: Bool = false

    init(id: UUID, fileName: String, name: String, sourcePath: String? = nil,
         sourceFileSize: UInt64? = nil, contentRevision: UUID? = nil,
         position: CGPoint, groupID: UUID? = nil, isRemoved: Bool = false,
         isReference: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.name = name
        self.sourcePath = sourcePath
        self.sourceFileSize = sourceFileSize
        self.contentRevision = contentRevision
        self.position = position
        self.groupID = groupID
        self.isRemoved = isRemoved
        self.isReference = isReference
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, name, sourcePath, sourceFileSize, contentRevision, position, groupID, isRemoved, isReference
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fileName = try values.decode(String.self, forKey: .fileName)
        name = try values.decode(String.self, forKey: .name)
        sourcePath = try values.decodeIfPresent(String.self, forKey: .sourcePath)
        sourceFileSize = try values.decodeIfPresent(UInt64.self, forKey: .sourceFileSize)
        contentRevision = try values.decodeIfPresent(UUID.self, forKey: .contentRevision)
        position = try values.decode(CGPoint.self, forKey: .position)
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        // Old ratings and color labels are deliberately ignored when reading existing projects.
        isRemoved = try values.decodeIfPresent(Bool.self, forKey: .isRemoved) ?? false
        isReference = try values.decodeIfPresent(Bool.self, forKey: .isReference) ?? false
    }
}

/// Shared by drawing, imports and layout edits so a card always has the same footprint.
nonisolated struct ProjectMaterialLayout: Sendable {
    static let thumbnailRange: ClosedRange<Double> = 48...240
    static let cardInset: CGFloat = 3
    static let groupGap: CGFloat = 2
    static let groupMargin: CGFloat = 4
    let thumbnailSize: CGFloat
    let gap: CGFloat = 6

    init(thumbnailSize: CGFloat) {
        self.thumbnailSize = thumbnailSize.isFinite
            ? min(CGFloat(Self.thumbnailRange.upperBound), max(CGFloat(Self.thumbnailRange.lowerBound), thumbnailSize))
            : 128
    }

    var cardSize: CGSize {
        CGSize(width: thumbnailSize + 2 * Self.cardInset, height: thumbnailSize + 2 * Self.cardInset)
    }
    var columnStride: CGFloat { cardSize.width + gap }
    var rowStride: CGFloat { cardSize.height + gap }
    var groupColumnStride: CGFloat { cardSize.width + Self.groupGap }
    var groupRowHeight: CGFloat { cardSize.height + 2 * Self.groupMargin }

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
    // Preserve the folder selected at import, even when its photos live in subfolders.
    var sourceDirectoryPaths: [String]

    var activeAssets: [ProjectAsset] { assets.filter { !$0.isRemoved } }
    var orderedActiveAssets: [ProjectAsset] {
        let byID = Dictionary(uniqueKeysWithValues: assets.filter { !$0.isRemoved }.map { ($0.id, $0) })
        return materialOrder.compactMap { byID[$0] }
    }

    init(id: UUID, name: String, createdAt: Date, modifiedAt: Date, assets: [ProjectAsset],
         exports: [ProjectExportRecord], thumbnailSize: Double, viewZoom: Double? = nil,
         groups: [ProjectPhotoGroup]? = nil, groupThumbnailSize: Double? = nil,
         thumbnailSizesLinked: Bool = true, materialOrder: [UUID]? = nil,
         sourceDirectoryPaths: [String] = []) {
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
        self.sourceDirectoryPaths = sourceDirectoryPaths
        synchronizeGroups()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, modifiedAt, assets, exports, thumbnailSize, viewZoom, groups
        case groupThumbnailSize, thumbnailSizesLinked, materialOrder, sourceDirectoryPaths
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
        sourceDirectoryPaths = try values.decodeIfPresent([String].self, forKey: .sourceDirectoryPaths) ?? []
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

nonisolated struct ProjectSummaryCoverAsset: Sendable {
    let id: UUID
    let fileName: String
    let contentRevision: UUID?
    let sourcePath: String?
    let isReference: Bool
}

nonisolated struct ProjectSummary: Identifiable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var assetCount: Int
    /// First few active assets, in material order, used for the home cover.
    var coverAssets: [ProjectSummaryCoverAsset]
    /// Active photos whose source file can no longer be found on disk.
    var missingCount: Int
}

/// The choices shown when an import contains files already represented by the project.
nonisolated enum ProjectDuplicateResolution: String, CaseIterable, Sendable {
    case skip
    case overwrite
    case keepBoth

    var title: String {
        switch self {
        case .skip: return "跳过重复文件"
        case .overwrite: return "替换项目素材"
        case .keepBoth: return "保留两者（自动重命名）"
        }
    }
}

nonisolated struct ProjectDuplicateItem: Identifiable, Sendable {
    var id: UUID { incomingID }
    let incomingID: UUID
    let incomingName: String
    let incomingPath: String
    let existingName: String
    let reasons: [String]
}

/// Published by the store while a batch import is waiting for a duplicate decision.
nonisolated struct ProjectDuplicateImportPrompt: Identifiable, Sendable {
    let id: UUID
    let duplicates: [ProjectDuplicateItem]
    let totalFiles: Int
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
    var overwritten: [ProjectAsset] = []
    var sourceDirectoryPaths: [String] = []
    var failures: [String]
    var failureCount = 0
    var skippedDuplicates = 0

    mutating func recordFailure(_ description: String) {
        failureCount += 1
        if failures.count < 8 { failures.append(description) }
    }

    var failureDescription: String {
        failures.joined(separator: "、") + (failureCount > failures.count ? "等，共 \(failureCount) 项" : "")
    }
}

nonisolated private struct ProjectImportScan: Sendable {
    var imageURLs: [URL]
    var failures: [String]
    var failureCount = 0

    mutating func recordFailure(_ description: String) {
        failureCount += 1
        if failures.count < 8 { failures.append(description) }
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

nonisolated private struct PendingDuplicateImport: Sendable {
    let request: ProjectImportRequest
    let promptID: UUID
    var duplicates: [ProjectDuplicateItem]
    let totalFiles: Int
    var decisions: [String: ProjectDuplicateResolution] = [:]
}

/// Metadata follows a live image independently of the library cache. Weak,
/// identity-based keys retain neither previews nor their owning project stores.
@MainActor private enum ProjectThumbnailMetadata {
    private static let resolutions = NSMapTable<NSImage, NSNumber>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    static func register(_ image: NSImage, resolution: ProjectThumbnailResolution) {
        resolutions.setObject(NSNumber(value: resolution.rawValue), forKey: image)
    }

    static func resolution(of image: NSImage) -> ProjectThumbnailResolution? {
        guard let value = resolutions.object(forKey: image) else { return nil }
        return ProjectThumbnailResolution(rawValue: value.intValue)
    }
}

/// Thumbnail arrivals refresh only views that display previews, not every mounted editor.
@MainActor final class ProjectThumbnailUpdates: ObservableObject {
    let completed = PassthroughSubject<Set<UUID>, Never>()

    func invalidate(_ ids: Set<UUID> = []) {
        completed.send(ids)
        objectWillChange.send()
    }
}

@MainActor final class ProjectLibraryStore: ObservableObject {
    /// The pre-root-config location inside Application Support. Kept only as the
    /// one-time migration source for projects created before the configurable root.
    nonisolated static let legacyProjectsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("aoipic/Projects", isDirectory: true)
    }()

    /// The active project root, read from user preferences so project metadata
    /// and caches live in a backup-friendly location (default
    /// `~/Pictures/AoiStitcher 项目/`).
    nonisolated static func configuredProjectsDirectory(in defaults: UserDefaults = .standard) -> URL {
        AppPreferences.projectRootURL(in: defaults)
    }

    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var currentProject: ProjectDocument?
    @Published private(set) var isImporting = false
    @Published var message: String?
    @Published var duplicateImportRequest: ProjectDuplicateImportPrompt?
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
    private let thumbnailQueue: OperationQueue
    private static func makeThumbnailQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "com.aoistitcher.project-thumbnails"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount <= 4
            || ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 2
        return queue
    }
    private struct ThumbnailRequest {
        let id: UUID
        let projectID: UUID
        let assetID: UUID
        let operation: Operation
        var hasUnscopedDemand: Bool
    }
    private struct ThumbnailDemand {
        let projectID: UUID
        let assetIDs: Set<UUID>
    }
    private var thumbnailRequests: [String: ThumbnailRequest] = [:]
    private var thumbnailDemandOwners: [UUID: ThumbnailDemand] = [:]
    private var failedThumbnails: Set<String> = []
    private var thumbnailNotificationScheduled = false
    private var completedThumbnailIDs: Set<UUID> = []
    private var importQueue: [ProjectImportRequest] = []
    private var pendingDuplicateImport: PendingDuplicateImport?

    var canUndoEdit: Bool {
        guard let id = currentProject?.id else { return false }
        return !(editHistory[id]?.isEmpty ?? true)
    }

    init(projectsDirectory: URL = ProjectLibraryStore.configuredProjectsDirectory(), thumbnailQueue: OperationQueue? = nil) {
        directory = projectsDirectory
        self.thumbnailQueue = thumbnailQueue ?? Self.makeThumbnailQueue()
        thumbnails.countLimit = 2_000
        thumbnails.totalCostLimit = 64 * 1024 * 1024
        refreshProjects()
        // Only migrate from the legacy Application Support location when running
        // against the configured production root. Tests pass a disposable
        // directory and must never touch the user's real library.
        if projectsDirectory == Self.configuredProjectsDirectory() {
            migrateLegacyProjectsIfNeeded()
        }
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
            projects = summaries.sorted(by: Self.newestProjectFirst)
            if failures > 0 { message = "有 \(failures) 个项目资料无法读取，原文件已保留在项目目录中。" }
        } catch {
            message = "读取项目列表失败：\(error.localizedDescription)"
        }
    }

    /// One-time relocation of projects from the old Application Support location
    /// into the configured visible root. Each project folder keeps its UUID name
    /// so the catalog logic and existing assets are untouched. Idempotent: a
    /// project already present in the new root is left alone.
    private func migrateLegacyProjectsIfNeeded() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: Self.legacyProjectsDirectory.path) else { return }
        guard let entries = try? fileManager.contentsOfDirectory(at: Self.legacyProjectsDirectory,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles]) else { return }
        var moved = 0
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            // Only move folders that actually contain a project document.
            let metadata = entry.appendingPathComponent("project.json")
            guard fileManager.fileExists(atPath: metadata.path) else { continue }
            let destination = directory.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) { continue }
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try fileManager.moveItem(at: entry, to: destination)
                moved += 1
            } catch {
                message = "迁移项目「\(entry.lastPathComponent)」失败：\(error.localizedDescription) 原项目仍保留在 \(Self.legacyProjectsDirectory.path)。"
            }
        }
        if moved > 0 {
            refreshProjects()
            message = "已将 \(moved) 个项目迁移到新的存储位置：\(directory.path)"
        }
        // Remove the now-empty legacy directory so future launches skip the scan.
        if moved > 0,
           let remaining = try? fileManager.contentsOfDirectory(at: Self.legacyProjectsDirectory,
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles]),
           remaining.isEmpty {
            try? fileManager.removeItem(at: Self.legacyProjectsDirectory)
        }
    }

    @discardableResult
    func createProject(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let document = ProjectDocument(id: UUID(), name: trimmed.isEmpty ? "未命名项目" : trimmed,
                                       createdAt: now, modifiedAt: now, assets: [], exports: [], thumbnailSize: 128)
        do {
            try FileManager.default.createDirectory(at: projectDirectory(id: document.id), withIntermediateDirectories: true)
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
            let document = try readDocument(id: id)
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

    /// Locate source folders independently of Finder so missing originals never
    /// redirect the user to internal metadata or thumbnail caches.
    func sourceDirectoriesForProject(id: UUID) throws -> [URL] {
        let document = try readDocument(id: id)
        let manager = FileManager.default
        let protected = [directory, Self.legacyProjectsDirectory].map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        func sourceURL(_ path: String) -> URL? {
            guard (path as NSString).isAbsolutePath else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard !protected.contains(where: { Self.isWithinDirectory(url, directory: $0) }) else { return nil }
            return url
        }
        func exists(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let assets = document.activeAssets.isEmpty ? document.assets : document.activeAssets
        let sources = assets.compactMap { $0.sourcePath.flatMap(sourceURL) }
        var folders: [URL] = []
        func append(_ folder: URL) {
            guard exists(folder), !folders.contains(where: { Self.isWithinDirectory(folder, directory: $0) }) else { return }
            folders.removeAll { Self.isWithinDirectory($0, directory: folder) }
            folders.append(folder)
        }
        for path in document.sourceDirectoryPaths {
            guard let folder = sourceURL(path),
                  sources.contains(where: { Self.isWithinDirectory($0, directory: folder) }) else { continue }
            append(folder)
        }
        // Older projects stored only photo paths, not the selected import folder.
        for source in sources {
            guard let parent = sourceURL(source.deletingLastPathComponent().path) else { continue }
            append(parent)
        }
        return folders
    }

    /// Reveals the original import folders, including when the project is closed.
    func revealProjectInFinder(id: UUID) {
        do {
            let folders = try sourceDirectoriesForProject(id: id)
            guard !folders.isEmpty else {
                let document = try readDocument(id: id)
                if document.assets.isEmpty {
                    message = "项目尚未导入照片，暂无原始位置可显示。"
                } else if document.activeAssets.contains(where: { asset in
                    asset.isReference && asset.sourcePath.map { !FileManager.default.fileExists(atPath: $0) } == true
                }) {
                    message = "找不到项目的原始照片位置，请使用「修复项目」重新连接。"
                } else {
                    message = "找不到项目记录的原始照片位置。请重新导入原照片，并选择「替换项目素材」重新连接。"
                }
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting(folders)
        } catch {
            message = "读取项目原始位置失败：\(error.localizedDescription)"
        }
    }

    /// Renames a project without touching its folder (folders are UUID-named for
    /// stability). Updates the document, persists it, and refreshes the summary.
    func renameProject(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            var document = try readDocument(id: id)
            guard document.name != trimmed else { return }
            document.name = trimmed
            document.modifiedAt = Date()
            try saveDocument(document)
            if currentProject?.id == id { currentProject = document }
            updateSummary(document)
        } catch {
            message = "重命名项目失败：\(error.localizedDescription)"
        }
    }

    /// Moves a project folder to the Trash after flushing any pending edits.
    /// The original imported photos (for copy-mode projects) are removed with
    /// the folder; referenced originals on disk are never touched.
    func deleteProject(id: UUID) {
        if currentProject?.id == id {
            guard flushPendingSaves() else {
                message = "项目仍有未保存的修改，无法删除。请稍后再试。"
                return
            }
            currentProject = nil
        }
        let url = projectDirectory(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            documents.removeValue(forKey: id)
            projects.removeAll { $0.id == id }
            return
        }
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            message = "删除项目失败：\(error.localizedDescription) 可手动删除 \(url.path)。"
            return
        }
        documents.removeValue(forKey: id)
        projects.removeAll { $0.id == id }
    }

    /// Re-links reference assets whose source file is missing by searching the
    /// chosen folder (including subfolders) for files with the same name.
    /// Returns the number of photos re-linked.
    @discardableResult
    func repairProject(id: UUID, locatingIn folder: URL) -> Int {
        var document: ProjectDocument
        do { document = try readDocument(id: id) } catch {
            message = "读取项目失败，无法修复：\(error.localizedDescription)"
            return 0
        }
        let manager = FileManager.default
        var nameIndex: [String: URL] = [:]
        if let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let key = url.lastPathComponent.lowercased()
                if nameIndex[key] == nil { nameIndex[key] = url }
            }
        }
        var repaired = 0
        for index in document.assets.indices {
            let asset = document.assets[index]
            guard asset.isReference, let sourcePath = asset.sourcePath,
                  !manager.fileExists(atPath: sourcePath) else { continue }
            let originalName = (sourcePath as NSString).lastPathComponent
            if let found = nameIndex[originalName.lowercased()] {
                document.assets[index].sourcePath = found.path
                document.assets[index].sourceFileSize = Self.fileSize(of: found)
                document.assets[index].contentRevision = UUID()
                repaired += 1
            }
        }
        guard repaired > 0 else {
            message = "在所选文件夹里没有找到缺失的照片，请确认它们现在所在的位置。"
            return 0
        }
        let repairedDirectory = Self.canonicalPath(folder)
        if !document.sourceDirectoryPaths.contains(repairedDirectory) {
            document.sourceDirectoryPaths.append(repairedDirectory)
        }
        document.modifiedAt = Date()
        do {
            try saveDocument(document)
            if currentProject?.id == id { currentProject = document }
            updateSummary(document)
            message = "已重新连接 \(repaired) 张照片的源文件。"
        } catch {
            message = "保存修复结果失败：\(error.localizedDescription)"
            return 0
        }
        return repaired
    }

    /// Synchronous cover thumbnail lookup for the home grid. Returns a cached
    /// preview only; misses are filled by `requestCoverThumbnail`.
    func cachedCoverThumbnail(projectID: UUID, asset: ProjectSummaryCoverAsset) -> NSImage? {
        thumbnails.object(forKey: coverCacheKey(projectID: projectID, assetID: asset.id) as NSString)
    }

    /// Loads a cover thumbnail off the main thread, independent of the currently
    /// open project. Reuses the disk cache so an unopened project still shows its
    /// first photos without a full open cycle.
    func requestCoverThumbnail(projectID: UUID, asset: ProjectSummaryCoverAsset) async -> NSImage? {
        if let cached = cachedCoverThumbnail(projectID: projectID, asset: asset) { return cached }
        let projectDir = directory.appendingPathComponent(projectID.uuidString, isDirectory: true)
        let sourceURL: URL
        if asset.isReference, let sourcePath = asset.sourcePath {
            sourceURL = URL(fileURLWithPath: sourcePath)
        } else {
            sourceURL = projectDir.appendingPathComponent("Originals", isDirectory: true)
                .appendingPathComponent(asset.fileName)
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let cacheDirectory = projectDir.appendingPathComponent(".thumbnails/v2", isDirectory: true)
        let contentRevision = asset.contentRevision
        let result = await Task.detached(priority: .utility) {
            ProjectThumbnailDiskCache.load(sourceURL: sourceURL, cacheDirectory: cacheDirectory,
                                           assetID: asset.id, contentRevision: contentRevision,
                                           maximumPixelSize: 256)
        }.value
        guard let cgImage = result?.image else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnails.setObject(image, forKey: coverCacheKey(projectID: projectID, assetID: asset.id) as NSString)
        return image
    }

    private func coverCacheKey(projectID: UUID, assetID: UUID) -> String {
        "cover/\(projectID.uuidString)/\(assetID.uuidString)"
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
        panel.message = "选择图片或文件夹（包含子文件夹）。项目只记录照片位置，不复制原图；移动原文件后可用「修复项目」重新连接。"
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

    /// Completes the currently paused duplicate prompt. The UI intentionally calls this
    /// only after the user has chosen one of the three visible actions.
    func resolveDuplicateImport(_ resolution: ProjectDuplicateResolution, applyToAll: Bool = true) {
        guard var pending = pendingDuplicateImport, let current = pending.duplicates.first else { return }
        if !applyToAll {
            pending.decisions[current.incomingPath] = resolution
            pending.duplicates.removeFirst()
            if !pending.duplicates.isEmpty {
                    let promptID = pending.promptID
                pendingDuplicateImport = pending
                    duplicateImportRequest = ProjectDuplicateImportPrompt(id: promptID,
                                                                       duplicates: pending.duplicates,
                                                                       totalFiles: pending.totalFiles)
                return
            }
        } else {
            for duplicate in pending.duplicates {
                pending.decisions[duplicate.incomingPath] = resolution
            }
            pending.duplicates.removeAll()
        }
        pendingDuplicateImport = nil
        duplicateImportRequest = nil
        isImporting = true
        performImport(pending.request, duplicateResolution: applyToAll ? resolution : nil,
                      duplicateDecisions: pending.decisions)
    }

    func cancelDuplicateImport() {
        guard let pending = pendingDuplicateImport else { return }
        pendingDuplicateImport = nil
        duplicateImportRequest = nil
        pending.request.securityScopes.forEach { $0.stopAccessingSecurityScopedResource() }
        message = "已取消导入，原有素材未改变。"
        startNextImportIfNeeded()
    }

    private func startNextImportIfNeeded() {
        guard !isImporting, pendingDuplicateImport == nil, !importQueue.isEmpty else { return }
        let request = importQueue.removeFirst()
        let projectID = request.projectID
        let protectedDirectories = [directory, Self.legacyProjectsDirectory]
        isImporting = true
        // Resolve duplicates before changing the project's source references.
        Task { [self] in
            let scan = await Task.detached(priority: .userInitiated) {
                Self.scanImages(request.urls, excluding: protectedDirectories)
            }.value
            do {
                // Load the project that initiated this import, even if the user has since opened another.
                let document = try self.readDocument(id: projectID)
                let duplicateItems = Self.duplicateItems(in: scan.imageURLs, document: document)
                if !duplicateItems.isEmpty {
                    let promptID = UUID()
                    self.pendingDuplicateImport = PendingDuplicateImport(request: request,
                                                                         promptID: promptID,
                                                                         duplicates: duplicateItems,
                                                                         totalFiles: scan.imageURLs.count)
                    self.duplicateImportRequest = ProjectDuplicateImportPrompt(id: promptID,
                                                                               duplicates: duplicateItems,
                                                                               totalFiles: scan.imageURLs.count)
                    self.isImporting = false
                    return
                }
                self.performImport(request, duplicateResolution: nil, duplicateDecisions: nil)
            } catch {
                request.securityScopes.forEach { $0.stopAccessingSecurityScopedResource() }
                self.message = "读取导入项目资料失败：\(error.localizedDescription)"
                self.isImporting = false
                self.startNextImportIfNeeded()
            }
        }
    }

    private func performImport(_ request: ProjectImportRequest,
                               duplicateResolution: ProjectDuplicateResolution?,
                               duplicateDecisions: [String: ProjectDuplicateResolution]?) {
        let projectID = request.projectID
        let protectedDirectories = [directory, Self.legacyProjectsDirectory]
        let existingAssets = (try? readDocument(id: projectID).assets) ?? []
        Task { [self] in
            let result = await Task.detached(priority: .userInitiated) {
                defer { request.securityScopes.forEach { $0.stopAccessingSecurityScopedResource() } }
                return Self.referenceImages(request.urls, excluding: protectedDirectories,
                                            existingAssets: existingAssets,
                                            duplicateResolution: duplicateResolution,
                                            duplicateDecisions: duplicateDecisions)
            }.value
            do {
                var document = try self.readDocument(id: projectID)
                if !result.assets.isEmpty || !result.overwritten.isEmpty {
                    let cardHeight = ProjectMaterialLayout(thumbnailSize: CGFloat(document.thumbnailSize)).cardSize.height
                    let start = request.point
                        ?? CGPoint(x: 24, y: document.activeAssets.isEmpty ? 24 : (document.activeAssets.map(\.position.y).max() ?? 24) + cardHeight + 24)
                    let isCurrentProject = self.currentProject?.id == projectID
                    let viewportWidth = isCurrentProject ? self.boardViewportWidth : request.viewportWidth
                    let viewZoom = isCurrentProject ? self.boardViewZoom : request.viewZoom
                    let layout = self.assetLayout(thumbnailSize: document.thumbnailSize, viewportWidth: viewportWidth,
                                                  zoom: viewZoom, startX: start.x)
                    for updated in result.overwritten {
                        if let index = document.assets.firstIndex(where: { $0.id == updated.id }) {
                            document.assets[index] = updated
                        }
                    }
                    for (index, var asset) in result.assets.enumerated() {
                        asset.position = CGPoint(x: start.x + CGFloat(index % layout.columns) * layout.columnStride,
                                                 y: start.y + CGFloat(index / layout.columns) * layout.rowStride)
                        document.assets.append(asset)
                        document.materialOrder.append(asset.id)
                    }
                    for path in result.sourceDirectoryPaths where !document.sourceDirectoryPaths.contains(path) {
                        document.sourceDirectoryPaths.append(path)
                    }
                    document.modifiedAt = Date()
                    try self.saveDocument(document)
                    if self.currentProject?.id == projectID { self.currentProject = document }
                    self.updateSummary(document)
                }
                let importedCount = result.assets.count + result.overwritten.count
                if result.failureCount > 0 {
                    self.message = "已处理 \(importedCount) 张（覆盖 \(result.overwritten.count) 张）；\(result.failureDescription)"
                } else if importedCount == 0 && result.skippedDuplicates > 0 {
                    self.message = "已跳过 \(result.skippedDuplicates) 个重复文件，原有素材未改变。"
                } else if importedCount == 0 {
                    self.message = "未找到可导入的图片。请选择图片或包含图片的文件夹。"
                } else if result.skippedDuplicates > 0 {
                    self.message = "已处理 \(importedCount) 张（新增 \(result.assets.count) 张，覆盖 \(result.overwritten.count) 张），跳过 \(result.skippedDuplicates) 个重复文件。"
                }
            } catch {
                self.message = "保存导入资料失败：\(error.localizedDescription)"
            }
            self.isImporting = false
            self.startNextImportIfNeeded()
        }
    }

    func assetURL(_ asset: ProjectAsset) -> URL {
        // Reference assets read the untouched original directly; legacy copy
        // assets keep reading the duplicate stored inside the project folder.
        if asset.isReference, let sourcePath = asset.sourcePath {
            return URL(fileURLWithPath: sourcePath)
        }
        guard let projectID = currentProject?.id else {
            return directory.appendingPathComponent(asset.fileName)
        }
        return assetDirectory(projectID: projectID).appendingPathComponent(asset.fileName)
    }

    /// Return any already-decoded preview without scheduling disk work. Keep the
    /// highest cached tier when a view shrinks, so late low-resolution completions
    /// cannot replace a sharper image already on screen.
    func cachedThumbnail(for asset: ProjectAsset,
                         maximumPixelSize: Int = ProjectThumbnailDiskCache.maximumPixelSize) -> NSImage? {
        guard let projectID = currentProject?.id else { return nil }
        return cachedThumbnailEntry(for: asset, projectID: projectID)?.image
    }

    func isDetailedThumbnail(_ image: NSImage) -> Bool {
        ProjectThumbnailMetadata.resolution(of: image) == .detail1080
    }

    func isThumbnail(_ image: NSImage, sufficientForDisplayPixelSize pixelSize: Int) -> Bool {
        guard let resolution = ProjectThumbnailMetadata.resolution(of: image) else { return false }
        return resolution.rawValue >= ProjectThumbnailResolution.display(pixelSize: pixelSize).rawValue
    }

    private func thumbnailKey(for asset: ProjectAsset, projectID: UUID, resolution: ProjectThumbnailResolution) -> String {
        "\(projectID.uuidString)/\(asset.id.uuidString)/\(asset.fileName)/\(asset.contentRevision?.uuidString ?? "original")/\(resolution.cacheKey)"
    }

    private func cachedThumbnailEntry(for asset: ProjectAsset, projectID: UUID)
        -> (image: NSImage, resolution: ProjectThumbnailResolution)? {
        for resolution in ProjectThumbnailResolution.allCases.reversed() {
            let key = thumbnailKey(for: asset, projectID: projectID, resolution: resolution)
            if let image = thumbnails.object(forKey: key as NSString) { return (image, resolution) }
        }
        return nil
    }

    /// Independent material/group views share queued images, while fast scrolling
    /// can discard work that none of the mounted views still needs.
    func updateThumbnailDemand(owner: UUID, assetIDs: Set<UUID>) {
        guard let projectID = currentProject?.id else { releaseThumbnailDemand(owner: owner); return }
        thumbnailDemandOwners[owner] = ThumbnailDemand(projectID: projectID, assetIDs: assetIDs)
        cancelObsoleteThumbnailRequests()
    }

    func releaseThumbnailDemand(owner: UUID) {
        thumbnailDemandOwners.removeValue(forKey: owner)
        cancelObsoleteThumbnailRequests()
    }

    private func cancelObsoleteThumbnailRequests() {
        var needed: [UUID: Set<UUID>] = [:]
        for demand in thumbnailDemandOwners.values {
            needed[demand.projectID, default: []].formUnion(demand.assetIDs)
        }
        for (key, request) in thumbnailRequests where !request.hasUnscopedDemand
            && !request.operation.isExecuting && !request.operation.isFinished
            && !(needed[request.projectID]?.contains(request.assetID) ?? false) {
            request.operation.cancel()
            thumbnailRequests.removeValue(forKey: key)
        }
    }

    func thumbnail(for asset: ProjectAsset,
                   maximumPixelSize: Int = ProjectThumbnailDiskCache.maximumPixelSize,
                   priority: Operation.QueuePriority = .normal,
                   owner: UUID? = nil) -> NSImage? {
        thumbnail(for: asset, resolution: .browsing(maximumPixelSize: maximumPixelSize), priority: priority, owner: owner)
    }

    func detailedThumbnail(for asset: ProjectAsset, priority: Operation.QueuePriority = .low,
                           owner: UUID? = nil) -> NSImage? {
        thumbnail(for: asset, resolution: .detail1080, priority: priority, owner: owner)
    }

    func displayThumbnail(for asset: ProjectAsset, pixelSize: Int,
                          priority: Operation.QueuePriority = .low, owner: UUID? = nil) -> NSImage? {
        thumbnail(for: asset, resolution: .display(pixelSize: pixelSize), priority: priority, owner: owner)
    }

    private func thumbnail(for asset: ProjectAsset, resolution: ProjectThumbnailResolution,
                           priority: Operation.QueuePriority, owner: UUID?) -> NSImage? {
        guard let projectID = currentProject?.id else { return nil }
        let cached = cachedThumbnailEntry(for: asset, projectID: projectID)
        if let cached, cached.resolution.rawValue >= resolution.rawValue { return cached.image }
        let key = thumbnailKey(for: asset, projectID: projectID, resolution: resolution)
        let requestPriority: Operation.QueuePriority = cached != nil && priority.rawValue > Operation.QueuePriority.low.rawValue
            ? .low : priority
        if var pending = thumbnailRequests[key] {
            // A prefetched photo may scroll into view before its task begins.
            if pending.operation.queuePriority.rawValue < requestPriority.rawValue {
                pending.operation.queuePriority = requestPriority
            }
            if owner == nil {
                pending.hasUnscopedDemand = true
                thumbnailRequests[key] = pending
            }
            return cached?.image
        }
        guard !failedThumbnails.contains(key) else { return cached?.image }
        let requestID = UUID()
        let url = assetURL(asset)
        let cacheDirectory = assetDirectory(projectID: projectID).deletingLastPathComponent()
            .appendingPathComponent(".thumbnails/v2", isDirectory: true)
        let operation = BlockOperation { [weak self] in
            let image = autoreleasepool {
                ProjectThumbnailDiskCache.load(sourceURL: url, cacheDirectory: cacheDirectory,
                                               assetID: asset.id, contentRevision: asset.contentRevision,
                                               resolution: resolution)?.image
            }
            Task { @MainActor [weak self] in
                // Cancel may race with a queue starting a request. An obsolete
                // completion must not remove a newer request for the same key.
                guard let self, self.thumbnailRequests[key]?.id == requestID else { return }
                self.thumbnailRequests.removeValue(forKey: key)
                guard let image else {
                    self.failedThumbnails.insert(key)
                    return
                }
                let preview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                ProjectThumbnailMetadata.register(preview, resolution: resolution)
                self.thumbnails.setObject(preview, forKey: key as NSString, cost: image.bytesPerRow * image.height)
                self.scheduleThumbnailNotification(for: asset.id)
            }
        }
        // Fill empty cells before spending time refining already visible images.
        operation.queuePriority = requestPriority
        thumbnailRequests[key] = ThumbnailRequest(id: requestID, projectID: projectID, assetID: asset.id,
                                                  operation: operation, hasUnscopedDemand: owner == nil)
        thumbnailQueue.addOperation(operation)
        return cached?.image
    }

    private func scheduleThumbnailNotification(for assetID: UUID) {
        completedThumbnailIDs.insert(assetID)
        guard !thumbnailNotificationScheduled else { return }
        thumbnailNotificationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.thumbnailNotificationScheduled = false
            let completed = self.completedThumbnailIDs
            self.completedThumbnailIDs.removeAll(keepingCapacity: true)
            self.thumbnailUpdates.invalidate(completed)
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
        guard !chosen.isEmpty else { return nil }
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

    /// Move a group to its final zero-based position after removing it from the list.
    /// Drag/drop callers can therefore keep a stable insertion index while hovering.
    func moveGroup(_ id: UUID, to targetIndex: Int) {
        editDocument { document in
            guard let sourceIndex = document.groups.firstIndex(where: { $0.id == id }) else { return }
            let group = document.groups.remove(at: sourceIndex)
            let destination = min(max(0, targetIndex), document.groups.count)
            document.groups.insert(group, at: destination)
        }
    }

    /// Resolve both identities against the current document at mouse-up. Hover
    /// state is only a visual hint and must never decide the committed position.
    @discardableResult
    func moveGroup(_ id: UUID, relativeTo targetID: UUID, before: Bool) -> Bool {
        guard id != targetID, var reordered = currentProject?.groups,
              let source = reordered.firstIndex(where: { $0.id == id }),
              reordered.contains(where: { $0.id == targetID }) else { return false }
        let group = reordered.remove(at: source)
        guard let target = reordered.firstIndex(where: { $0.id == targetID }) else { return false }
        reordered.insert(group, at: target + (before ? 0 : 1))
        editDocument { $0.groups = reordered }
        return currentProject?.groups == reordered
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
            guard let asset = byID[document.assets[index].id] else { continue }
            // Undo covers organization edits. An original replaced by a later
            // import keeps its current metadata and decoded-preview identity.
            document.assets[index].position = asset.position
            document.assets[index].groupID = asset.groupID
            document.assets[index].isRemoved = asset.isRemoved
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
        let active = document.orderedActiveAssets
        let cover = Array(active.prefix(3)).map {
            ProjectSummaryCoverAsset(id: $0.id, fileName: $0.fileName, contentRevision: $0.contentRevision,
                                     sourcePath: $0.sourcePath, isReference: $0.isReference)
        }
        let manager = FileManager.default
        let missing = active.filter { asset in
            if asset.isReference, let sourcePath = asset.sourcePath {
                return !manager.fileExists(atPath: sourcePath)
            }
            return !manager.fileExists(atPath: assetDirectory(projectID: document.id)
                .appendingPathComponent(asset.fileName).path)
        }.count
        return ProjectSummary(id: document.id, name: document.name, createdAt: document.createdAt, modifiedAt: document.modifiedAt,
                              assetCount: active.count, coverAssets: cover, missingCount: missing)
    }

    nonisolated private static func newestProjectFirst(_ left: ProjectSummary, _ right: ProjectSummary) -> Bool {
        if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        return left.id.uuidString < right.id.uuidString
    }

    private func updateSummary(_ document: ProjectDocument) {
        projects.removeAll { $0.id == document.id }
        projects.append(summary(document))
        projects.sort(by: Self.newestProjectFirst)
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

    nonisolated private static func scanImages(_ urls: [URL], excluding protectedDirectories: [URL]) -> ProjectImportScan {
        var result = ProjectImportScan(imageURLs: [], failures: [])
        let manager = FileManager.default
        let protectedPaths = protectedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                .isHiddenKey, .isPackageKey, .contentTypeKey, .fileSizeKey]
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
                if seenFiles.insert(canonical.path).inserted { result.imageURLs.append(url) }
                return 1
            } catch {
                result.recordFailure("\(url.lastPathComponent)：无法读取")
                return 0
            }
        }

        for url in urls { _ = collectImages(at: url, isRoot: true) }
        return result
    }

    nonisolated private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated private static func isWithinDirectory(_ url: URL, directory: URL) -> Bool {
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return url.path == directory.path || url.path.hasPrefix(prefix)
    }

    nonisolated private static func fileSize(of url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size >= 0 else { return nil }
        return UInt64(size)
    }

    nonisolated private static func duplicateMatch(for url: URL, fileSize: UInt64?, existingAssets: [ProjectAsset])
        -> (asset: ProjectAsset, reasons: [String])? {
        let path = canonicalPath(url)
        let name = url.lastPathComponent
        for asset in existingAssets where !asset.isRemoved {
            var reasons: [String] = []
            if asset.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                reasons.append("文件名相同")
            }
            if let sourcePath = asset.sourcePath,
               canonicalPath(URL(fileURLWithPath: sourcePath)) == path,
               let sourceSize = asset.sourceFileSize, sourceSize == fileSize {
                reasons.append("文件路径和大小相同")
            }
            if !reasons.isEmpty { return (asset, reasons) }
        }
        return nil
    }

    nonisolated private static func duplicateItems(in imageURLs: [URL], document: ProjectDocument) -> [ProjectDuplicateItem] {
        imageURLs.compactMap { url in
            guard let match = duplicateMatch(for: url, fileSize: fileSize(of: url),
                                             existingAssets: document.assets) else { return nil }
            return ProjectDuplicateItem(incomingID: UUID(), incomingName: url.lastPathComponent,
                                        incomingPath: canonicalPath(url), existingName: match.asset.name,
                                        reasons: match.reasons)
        }
    }

    nonisolated private static func uniqueName(_ name: String, occupied: inout Set<String>) -> String {
        let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard occupied.contains(key) else { occupied.insert(key); return name }
        let ext = URL(fileURLWithPath: name).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidateKey = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if occupied.insert(candidateKey).inserted { return candidate }
            index += 1
        }
    }

    /// Reference-only import: photos stay where they are and the project records
    /// their location. Replacing a legacy copy asset also switches it to a reference.
    nonisolated private static func referenceImages(_ urls: [URL],
                                                    excluding protectedDirectories: [URL],
                                                    existingAssets: [ProjectAsset],
                                                    duplicateResolution: ProjectDuplicateResolution?,
                                                    duplicateDecisions: [String: ProjectDuplicateResolution]?) -> ProjectImportResult {
        let scan = scanImages(urls, excluding: protectedDirectories)
        var result = ProjectImportResult(assets: [], failures: scan.failures, failureCount: scan.failureCount)
        var occupiedNames = Set(existingAssets.filter { !$0.isRemoved }.map {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
        for url in scan.imageURLs {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL, readThumbnail(url, maximum: 64) != nil else { throw ProjectLibraryError.notAnImage }
                let sourcePath = canonicalPath(url)
                let sourceSize = fileSize(of: url)
                let match = duplicateMatch(for: url, fileSize: sourceSize, existingAssets: existingAssets)
                if let match {
                    let policy = duplicateDecisions?[sourcePath] ?? duplicateResolution ?? .skip
                    switch policy {
                    case .skip:
                        result.skippedDuplicates += 1
                        continue
                    case .overwrite:
                        var updated = match.asset
                        updated.name = url.lastPathComponent
                        updated.sourcePath = sourcePath
                        updated.sourceFileSize = sourceSize
                        updated.contentRevision = UUID()
                        updated.isRemoved = false
                        updated.isReference = true
                        result.overwritten.append(updated)
                        continue
                    case .keepBoth:
                        break
                    }
                }
                let id = UUID()
                let extensionPart = String(url.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(16))
                let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
                // The UUID-based name is only a stable identity and cache key;
                // reference assets never create a file under this name.
                let fileName = id.uuidString + suffix
                let displayName = uniqueName(url.lastPathComponent, occupied: &occupiedNames)
                result.assets.append(ProjectAsset(id: id, fileName: fileName, name: displayName,
                                                  sourcePath: sourcePath, sourceFileSize: sourceSize,
                                                  position: .zero, isReference: true))
            } catch { result.recordFailure("\(url.lastPathComponent)：无法导入") }
        }
        let importedPaths = Set((result.assets + result.overwritten).compactMap(\.sourcePath))
        for url in urls where url.isFileURL {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            let isDirectory = (try? canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let containsImportedPhoto = isDirectory
                ? importedPaths.contains(where: { Self.isWithinDirectory(URL(fileURLWithPath: $0), directory: canonical) })
                : importedPaths.contains(canonical.path)
            guard containsImportedPhoto else { continue }
            let folder = isDirectory ? canonical : canonical.deletingLastPathComponent()
            if !result.sourceDirectoryPaths.contains(folder.path) { result.sourceDirectoryPaths.append(folder.path) }
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
