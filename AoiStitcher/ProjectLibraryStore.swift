import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ProjectOperation: String, Codable, CaseIterable, Identifiable, Sendable {
    case freeCanvas, longStitch, gridCollage, compression

    var id: String { rawValue }
    var maximumPhotoCount: Int? { self == .gridCollage ? 16 : nil }
    var title: String {
        switch self {
        case .freeCanvas: return "自由画布"
        case .longStitch: return "长图拼接"
        case .gridCollage: return "标准拼图"
        case .compression: return "图片压缩"
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

nonisolated enum ProjectColorLabel: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, yellow, green, blue, purple

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "无颜色"
        case .red: return "红色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        }
    }
}

nonisolated struct ProjectAsset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var fileName: String
    var name: String
    var position: CGPoint
    var rating: Int = 0
    var colorLabel: ProjectColorLabel = .none
    // Retain identity and originals so export history and undo remain valid after removal.
    var isRemoved: Bool = false

    init(id: UUID, fileName: String, name: String, position: CGPoint,
         rating: Int = 0, colorLabel: ProjectColorLabel = .none, isRemoved: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.name = name
        self.position = position
        self.rating = rating
        self.colorLabel = colorLabel
        self.isRemoved = isRemoved
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, name, position, rating, colorLabel, isRemoved
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fileName = try values.decode(String.self, forKey: .fileName)
        name = try values.decode(String.self, forKey: .name)
        position = try values.decode(CGPoint.self, forKey: .position)
        rating = try values.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        colorLabel = try values.decodeIfPresent(ProjectColorLabel.self, forKey: .colorLabel) ?? .none
        isRemoved = try values.decodeIfPresent(Bool.self, forKey: .isRemoved) ?? false
    }
}

nonisolated struct ProjectExportRecord: Identifiable, Codable, Sendable {
    var id: UUID
    var operation: ProjectOperation
    var assetIDs: [UUID]
    var createdAt: Date
    var outputPath: String
}

nonisolated struct ProjectDocument: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var assets: [ProjectAsset]
    var exports: [ProjectExportRecord]
    var thumbnailSize: Double
    // Separate from thumbnail geometry so browsing never changes saved asset positions.
    var viewZoom: Double? = nil

    var activeAssets: [ProjectAsset] { assets.filter { !$0.isRemoved } }
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

@MainActor final class ProjectLibraryStore: ObservableObject {
    static let projectsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("aoipic/Projects", isDirectory: true)
    }()

    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var currentProject: ProjectDocument?
    @Published private(set) var isImporting = false
    @Published var message: String?

    // Updated by the material board; these are viewport measurements, not project edits.
    var boardViewportWidth: CGFloat = 800
    var boardViewZoom: CGFloat = 1

    private var editHistory: [UUID: [[ProjectAsset]]] = [:]
    private let thumbnails = NSCache<NSString, NSImage>()
    private var thumbnailRequests: Set<String> = []
    private var failedThumbnails: Set<String> = []
    private var importQueue: [ProjectImportRequest] = []

    var canUndoEdit: Bool {
        guard let id = currentProject?.id else { return false }
        return !(editHistory[id]?.isEmpty ?? true)
    }

    init() {
        thumbnails.countLimit = 2_000
        thumbnails.totalCostLimit = 128 * 1024 * 1024
        refreshProjects()
    }

    deinit {
        for request in importQueue {
            request.securityScopes.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    func refreshProjects() {
        do {
            try FileManager.default.createDirectory(at: Self.projectsDirectory, withIntermediateDirectories: true)
            let entries = try FileManager.default.contentsOfDirectory(at: Self.projectsDirectory,
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
            try saveDocument(document)
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

    func closeProject() { currentProject = nil }

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
        let protectedDirectory = Self.projectsDirectory
        isImporting = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                defer { request.securityScopes.forEach { $0.stopAccessingSecurityScopedResource() } }
                return Self.copyImages(request.urls, to: destination, excluding: protectedDirectory)
            }.value
            guard let self else { return }
            do {
                // Load the project that initiated this import, even if the user has since opened another.
                var document = try self.readDocument(id: projectID)
                if !result.assets.isEmpty {
                    let cardHeight = CGFloat(document.thumbnailSize) + 62
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
            return Self.projectsDirectory.appendingPathComponent(asset.fileName)
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
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { Self.readThumbnail(url, maximum: pixelSize) }.value
            guard let self else { return }
            self.thumbnailRequests.remove(key)
            guard let image else {
                self.failedThumbnails.insert(key)
                return
            }
            let preview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            self.thumbnails.setObject(preview, forKey: key as NSString, cost: image.bytesPerRow * image.height)
            // NSCache is not published; refresh observed boards when an asynchronous preview arrives.
            self.objectWillChange.send()
        }
        return nil
    }

    private func editAssets(_ ids: Set<UUID>, change: (inout ProjectAsset) -> Void) {
        guard !ids.isEmpty, var document = documentForEditing() else { return }
        var previous: [ProjectAsset] = []
        for index in document.assets.indices {
            let asset = document.assets[index]
            guard ids.contains(asset.id), !asset.isRemoved else { continue }
            change(&document.assets[index])
            if document.assets[index] != asset { previous.append(asset) }
        }
        guard !previous.isEmpty, commitCurrent(document) else { return }
        editHistory[document.id, default: []].append(previous)
        if editHistory[document.id, default: []].count > 50 { editHistory[document.id]?.removeFirst() }
    }

    func moveAssets(_ positions: [UUID: CGPoint]) {
        editAssets(Set(positions.keys)) { asset in
            guard let point = positions[asset.id], point.x.isFinite, point.y.isFinite else { return }
            asset.position = CGPoint(x: max(0, point.x), y: max(0, point.y))
        }
    }

    func setRating(_ ids: Set<UUID>, rating: Int) {
        guard (0...5).contains(rating) else { return }
        editAssets(ids) { $0.rating = rating }
    }

    func setColor(_ ids: Set<UUID>, color: ProjectColorLabel) {
        editAssets(ids) { $0.colorLabel = color }
    }

    func removeAssets(_ ids: Set<UUID>) {
        editAssets(ids) { $0.isRemoved = true }
    }

    func undoLastEdit() {
        guard var document = documentForEditing(), let previous = editHistory[document.id]?.last else { return }
        let byID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for index in document.assets.indices {
            if let asset = byID[document.assets[index].id] { document.assets[index] = asset }
        }
        guard commitCurrent(document) else { return }
        editHistory[document.id]?.removeLast()
    }

    func arrangeAssets(viewportWidth: CGFloat, zoom: CGFloat) {
        guard let document = currentProject else { return }
        let layout = assetLayout(thumbnailSize: document.thumbnailSize, viewportWidth: viewportWidth, zoom: zoom, startX: 24)
        let ordered = document.activeAssets.sorted { left, right in
            let leftRow = floor(left.position.y / layout.rowStride)
            let rightRow = floor(right.position.y / layout.rowStride)
            return leftRow == rightRow ? left.position.x < right.position.x : leftRow < rightRow
        }
        let positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, asset in
            (asset.id, CGPoint(x: 24 + CGFloat(index % layout.columns) * layout.columnStride,
                               y: 24 + CGFloat(index / layout.columns) * layout.rowStride))
        })
        moveAssets(positions)
    }

    private func assetLayout(thumbnailSize: Double, viewportWidth: CGFloat, zoom: CGFloat, startX: CGFloat)
        -> (columns: Int, columnStride: CGFloat, rowStride: CGFloat) {
        let cardWidth = CGFloat(thumbnailSize) + 16
        let columnStride = cardWidth + 20
        let rowStride = CGFloat(thumbnailSize) + 62 + 20
        let safeWidth = viewportWidth.isFinite ? max(1, viewportWidth) : 800
        let safeZoom = zoom.isFinite ? min(2, max(0.02, zoom)) : 1
        // The board adds 24 screen points on each side, outside the scaled logical coordinates.
        let availableWidth = max(cardWidth, (safeWidth - 48) / safeZoom - startX)
        // A pathological screen measurement should never overflow the integer conversion.
        let columns = max(1, Int(min(10_000, floor((availableWidth + 20) / columnStride))))
        return (columns, columnStride, rowStride)
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
        guard size.isFinite, var document = documentForEditing() else { return }
        let clamped = min(224, max(72, size))
        guard document.thumbnailSize != clamped else { return }
        document.thumbnailSize = clamped
        _ = commitCurrent(document)
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
        guard let id = currentProject?.id else { return nil }
        do { return try readDocument(id: id) }
        catch {
            message = "读取项目最新资料失败：\(error.localizedDescription)"
            return nil
        }
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
        Self.projectsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func assetDirectory(projectID: UUID) -> URL {
        projectDirectory(id: projectID).appendingPathComponent("Originals", isDirectory: true)
    }
    private func metadataURL(id: UUID) -> URL {
        projectDirectory(id: id).appendingPathComponent("project.json")
    }

    private func readDocument(id: UUID) throws -> ProjectDocument {
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: metadataURL(id: id)))
        try validate(document, expectedID: id)
        return document
    }

    private func saveDocument(_ document: ProjectDocument) throws {
        try validate(document, expectedID: document.id)
        let url = metadataURL(id: document.id)
        // Never replace metadata that cannot be decoded, even if an older in-memory copy exists.
        if FileManager.default.fileExists(atPath: url.path) { _ = try readDocument(id: document.id) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    private func validate(_ document: ProjectDocument, expectedID: UUID) throws {
        let assetIDs = Set(document.assets.map(\.id))
        guard document.id == expectedID,
              document.thumbnailSize.isFinite, (72...224).contains(document.thumbnailSize),
              document.viewZoom.map({ $0.isFinite && (0.02...2).contains($0) }) ?? true,
              assetIDs.count == document.assets.count,
              Set(document.assets.map(\.fileName)).count == document.assets.count,
              Set(document.exports.map(\.id)).count == document.exports.count,
              document.assets.allSatisfy({ asset in
                  (0...5).contains(asset.rating) && !asset.fileName.isEmpty && asset.fileName != "." && asset.fileName != ".." &&
                  !asset.fileName.contains("/") && !asset.fileName.contains("\\") &&
                  asset.position.x.isFinite && asset.position.y.isFinite && asset.position.x >= 0 && asset.position.y >= 0
              }),
              document.exports.allSatisfy({ record in
                  !record.assetIDs.isEmpty && record.assetIDs.allSatisfy { assetIDs.contains($0) }
              }) else { throw ProjectLibraryError.invalidMetadata }
    }

    nonisolated private static func copyImages(_ urls: [URL], to directory: URL, excluding protectedDirectory: URL) -> ProjectImportResult {
        var result = ProjectImportResult(assets: [], failures: [])
        let manager = FileManager.default
        let protectedPath = protectedDirectory.standardizedFileURL.resolvingSymlinksInPath().path
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
            guard canonical.path != protectedPath && !canonical.path.hasPrefix(protectedPath + "/") else {
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
