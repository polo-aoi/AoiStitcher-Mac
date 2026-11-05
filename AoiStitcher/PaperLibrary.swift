import Combine
import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PaperLibraryColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        red = min(1, max(0, Double(rgb.redComponent)))
        green = min(1, max(0, Double(rgb.greenComponent)))
        blue = min(1, max(0, Double(rgb.blueComponent)))
        alpha = min(1, max(0, Double(rgb.alphaComponent)))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

nonisolated struct PaperLibraryItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var fileName: String
    var displayName: String
    var parentID: UUID? = nil
    var color: PaperLibraryColor? = nil

    var url: URL {
        PaperLibraryStore.libraryDirectory.appendingPathComponent(fileName)
    }
}

nonisolated struct PaperLibraryFolder: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var parentID: UUID? = nil
}

@MainActor final class PaperLibraryStore: ObservableObject {
    static let paperPasteboardType = NSPasteboard.PasteboardType("com.aoipic.paper-url")
    nonisolated static let libraryDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("aoipic/PaperLibrary", isDirectory: true)
    }()

    @Published private(set) var items: [PaperLibraryItem] = []
    @Published private(set) var folders: [PaperLibraryFolder] = []
    @Published private(set) var isImporting = false
    @Published private(set) var isSavingCrop = false
    var isBusy: Bool { isImporting || isSavingCrop }
    @Published var message: String?
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var canPersist = true

    nonisolated private struct Index: Codable, Sendable {
        var version = 1
        var folders: [PaperLibraryFolder]
        var items: [PaperLibraryItem]
    }

    nonisolated private struct ImportResult: Sendable {
        var folders: [PaperLibraryFolder] = []
        var items: [PaperLibraryItem] = []
        var copiedFiles: [URL] = []
        var failed = 0
    }

    nonisolated private enum CropSaveError: LocalizedError {
        case busy, unreadableLibrary, staleItem, encodingFailed

        var errorDescription: String? {
            switch self {
            case .busy: "素材库正在处理文件，请稍后再保存裁剪。"
            case .unreadableLibrary: "素材库暂时无法读取，不能保存裁剪，以免覆盖原有资料。"
            case .staleItem: "这张纸张已被替换或移除，请重新打开纸张后裁剪。"
            case .encodingFailed: "无法将裁剪结果保存为 PNG 图片。"
            }
        }
    }

    init(directory: URL = PaperLibraryStore.libraryDirectory) {
        self.directory = directory.standardizedFileURL
        load()
    }

    func load() {
        guard !isBusy else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            let index: Index
            if let legacy = try? decoder.decode([PaperLibraryItem].self, from: data) {
                index = Index(folders: [], items: legacy)
            } else {
                index = try decoder.decode(Index.self, from: data)
            }
            guard index.version == 1, Self.isValid(index) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            folders = index.folders
            items = index.items
            canPersist = true
            // Migration is saved only with the next explicit edit. Missing
            // image files remain visible so a temporary disk issue loses no data.
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            items = []
            folders = []
            canPersist = true
        } catch {
            canPersist = false
            message = "纸张库暂时无法读取，原有资料已保留。请检查素材库文件后重试。"
        }
    }

    func url(for item: PaperLibraryItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    @discardableResult
    func createFolder(named name: String, parentID: UUID?) -> UUID? {
        guard canEdit, validParent(parentID), let name = cleanedName(name) else { return nil }
        let folder = PaperLibraryFolder(id: UUID(), name: name, parentID: parentID)
        return commit(items: items, folders: folders + [folder]) ? folder.id : nil
    }

    @discardableResult
    func createColor(named name: String, color: NSColor, parentID: UUID?) -> PaperLibraryItem? {
        guard canEdit, validParent(parentID), let name = cleanedName(name) else { return nil }
        let item = PaperLibraryItem(id: UUID(), fileName: "", displayName: name,
                                    parentID: parentID, color: PaperLibraryColor(color))
        return commit(items: items + [item], folders: folders) ? item : nil
    }

    @discardableResult
    func renameItem(id: UUID, to name: String) -> Bool {
        guard canEdit, let index = items.firstIndex(where: { $0.id == id }),
              let name = cleanedName(name) else { return false }
        guard items[index].displayName != name else { return true }
        var updated = items
        updated[index].displayName = name
        return commit(items: updated, folders: folders)
    }

    @discardableResult
    func renameFolder(id: UUID, to name: String) -> Bool {
        guard canEdit, let index = folders.firstIndex(where: { $0.id == id }),
              let name = cleanedName(name) else { return false }
        guard folders[index].name != name else { return true }
        var updated = folders
        updated[index].name = name
        return commit(items: items, folders: updated)
    }

    func updateColor(id: UUID, color: NSColor) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        updateColorPaper(id: id, name: item.displayName, color: color)
    }

    @discardableResult
    func updateColorPaper(id: UUID, name: String, color: NSColor) -> PaperLibraryItem? {
        guard canEdit, let index = items.firstIndex(where: { $0.id == id }), items[index].color != nil,
              let name = cleanedName(name) else { return nil }
        let value = PaperLibraryColor(color)
        guard items[index].displayName != name || items[index].color != value else { return items[index] }
        var updated = items
        updated[index].displayName = name
        updated[index].color = value
        return commit(items: updated, folders: folders) ? updated[index] : nil
    }

    func saveCroppedImage(_ image: CGImage, for original: PaperLibraryItem, asNew: Bool) async throws -> PaperLibraryItem {
        guard !isBusy else { throw CropSaveError.busy }
        guard canPersist else { throw CropSaveError.unreadableLibrary }
        guard original.color == nil,
              let index = items.firstIndex(where: { $0.id == original.id }),
              items[index].color == nil, items[index].fileName == original.fileName else {
            throw CropSaveError.staleItem
        }
        try Task.checkCancellation()
        isSavingCrop = true
        defer { isSavingCrop = false }

        let previous = items[index]
        var saved = previous
        saved.fileName = UUID().uuidString + ".png"
        var nextItems = items
        if asNew {
            saved.id = UUID()
            saved.displayName = previous.displayName + " 裁剪"
            nextItems.append(saved)
        } else {
            nextItems[index] = saved
        }
        let nextIndex = Index(folders: folders, items: nextItems)
        let destination = url(for: saved)
        let libraryDirectory = directory
        // Busy gates keep this snapshot stable while both file writes run away
        // from the main actor. Once the index is saved, cancellation must not
        // leave the published library behind the persisted one.
        try await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
                try Self.writePNG(image, to: destination)
                try Self.writeIndex(nextIndex, to: libraryDirectory)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }.value
        items = nextItems

        if !asNew, !nextItems.contains(where: { $0.fileName == previous.fileName }) {
            let previousURL = url(for: previous)
            await Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: previousURL)
            }.value
        }
        return saved
    }

    @discardableResult
    func moveItem(id: UUID, to parentID: UUID?, beforeItemID: UUID? = nil) -> Bool {
        guard canEdit, validParent(parentID), let index = items.firstIndex(where: { $0.id == id }),
              beforeItemID != id else { return false }
        if let beforeItemID {
            guard let sibling = items.first(where: { $0.id == beforeItemID }), sibling.parentID == parentID else { return false }
        }
        var updated = items
        var moving = updated.remove(at: index)
        moving.parentID = parentID
        let insertionIndex: Int
        if let beforeItemID, let siblingIndex = updated.firstIndex(where: { $0.id == beforeItemID }) {
            insertionIndex = siblingIndex
        } else {
            insertionIndex = updated.lastIndex(where: { $0.parentID == parentID }).map { $0 + 1 } ?? updated.count
        }
        updated.insert(moving, at: insertionIndex)
        guard updated != items else { return true }
        return commit(items: updated, folders: folders)
    }

    @discardableResult
    func moveFolder(id: UUID, to parentID: UUID?, beforeFolderID: UUID? = nil) -> Bool {
        guard canEdit, validParent(parentID), let index = folders.firstIndex(where: { $0.id == id }),
              beforeFolderID != id else { return false }
        if let beforeFolderID {
            guard let sibling = folders.first(where: { $0.id == beforeFolderID }), sibling.parentID == parentID else { return false }
        }
        if let parentID, descendantFolderIDs(of: id).contains(parentID) {
            message = "不能将文件夹移入它自己或它的子文件夹。"
            return false
        }
        var updated = folders
        var moving = updated.remove(at: index)
        moving.parentID = parentID
        let insertionIndex: Int
        if let beforeFolderID, let siblingIndex = updated.firstIndex(where: { $0.id == beforeFolderID }) {
            insertionIndex = siblingIndex
        } else {
            insertionIndex = updated.lastIndex(where: { $0.parentID == parentID }).map { $0 + 1 } ?? updated.count
        }
        updated.insert(moving, at: insertionIndex)
        guard updated != folders else { return true }
        return commit(items: items, folders: updated)
    }

    func removeItem(id: UUID) {
        guard canEdit, let item = items.first(where: { $0.id == id }) else { return }
        guard commit(items: items.filter { $0.id != id }, folders: folders) else { return }
        removeUnusedFiles([item])
    }

    func removeFolder(id: UUID) {
        guard canEdit, folders.contains(where: { $0.id == id }) else { return }
        let removedIDs = descendantFolderIDs(of: id)
        let removedItems = items.filter { $0.parentID.map(removedIDs.contains) == true }
        let remaining = items.filter { $0.parentID.map(removedIDs.contains) != true }
        guard commit(items: remaining, folders: folders.filter { !removedIDs.contains($0.id) }) else { return }
        removeUnusedFiles(removedItems)
    }

    func importPanel(into parentID: UUID? = nil) {
        guard canEdit, validParent(parentID) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择要添加到素材库的纸张图片"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls, into: parentID)
    }

    func importFolderPanel(into parentID: UUID? = nil) {
        guard canEdit, validParent(parentID) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "导入文件夹，并保留其中的子文件夹"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls, into: parentID)
    }

    func importURLs(_ urls: [URL], into parentID: UUID? = nil) {
        guard canEdit, validParent(parentID), !urls.isEmpty else { return }
        isImporting = true
        let destination = directory
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.prepareImport(urls, into: parentID, directory: destination) }
            }.value
            guard let self else {
                if case .success(let imported) = result {
                    for url in imported.copiedFiles { try? FileManager.default.removeItem(at: url) }
                }
                return
            }
            defer { self.isImporting = false }
            switch result {
            case .success(let imported):
                guard self.validParent(parentID),
                      self.commit(items: self.items + imported.items, folders: self.folders + imported.folders) else {
                    for url in imported.copiedFiles { try? FileManager.default.removeItem(at: url) }
                    return
                }
                if imported.failed > 0 {
                    self.message = "已添加 \(imported.items.count) 张纸张，有 \(imported.failed) 项无法读取或复制。"
                } else if imported.items.isEmpty && imported.folders.isEmpty {
                    self.message = "未找到可以导入的纸张图片。"
                }
            case .failure(let error):
                self.message = "导入纸张失败：\(error.localizedDescription)"
            }
        }
    }

    private var canEdit: Bool {
        guard canPersist else {
            message = "纸张库无法读取，暂时不能修改，以免覆盖原有资料。"
            return false
        }
        return !isBusy
    }

    private func validParent(_ id: UUID?) -> Bool {
        id == nil || folders.contains { $0.id == id }
    }

    private func cleanedName(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            message = "请输入名称。"
            return nil
        }
        return value
    }

    private func descendantFolderIDs(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var pending = [id]
        while let parent = pending.popLast() {
            for child in folders where child.parentID == parent {
                if result.insert(child.id).inserted { pending.append(child.id) }
            }
        }
        return result
    }

    @discardableResult
    private func commit(items nextItems: [PaperLibraryItem], folders nextFolders: [PaperLibraryFolder]) -> Bool {
        guard canPersist else { return false }
        do {
            let index = Index(folders: nextFolders, items: nextItems)
            try Self.writeIndex(index, to: directory)
            items = nextItems
            folders = nextFolders
            return true
        } catch {
            message = "保存素材库失败：\(error.localizedDescription)"
            return false
        }
    }

    nonisolated private static func writeIndex(_ index: Index, to directory: URL) throws {
        guard isValid(index) else { throw CocoaError(.fileWriteInvalidFileName) }
        let data = try JSONEncoder().encode(index)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CropSaveError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CropSaveError.encodingFailed }
    }

    private func removeUnusedFiles(_ removed: [PaperLibraryItem]) {
        let remainingNames = Set(items.map(\.fileName))
        for item in removed where item.color == nil && !remainingNames.contains(item.fileName) {
            try? FileManager.default.removeItem(at: url(for: item))
        }
    }

    nonisolated private static func isValid(_ index: Index) -> Bool {
        let folderIDs = Set(index.folders.map(\.id))
        let itemIDs = Set(index.items.map(\.id))
        guard folderIDs.count == index.folders.count, itemIDs.count == index.items.count,
              folderIDs.isDisjoint(with: itemIDs) else { return false }
        let parents = Dictionary(uniqueKeysWithValues: index.folders.map { ($0.id, $0.parentID) })
        for folder in index.folders {
            var seen: Set<UUID> = [folder.id]
            var next = folder.parentID
            while let id = next {
                guard folderIDs.contains(id), seen.insert(id).inserted else { return false }
                next = parents[id] ?? nil
            }
        }
        return index.items.allSatisfy { item in
            guard item.parentID == nil || folderIDs.contains(item.parentID!) else { return false }
            if let color = item.color {
                return [color.red, color.green, color.blue, color.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
            }
            return !item.fileName.isEmpty && item.fileName != "." && item.fileName != ".." && item.fileName != "index.json"
                && !item.fileName.contains("/") && !item.fileName.contains("\\")
        }
    }

    nonisolated private static func prepareImport(_ urls: [URL], into parentID: UUID?, directory: URL) throws -> ImportResult {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        var result = ImportResult()
        var visited = Set<URL>()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey]
        let libraryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path

        func visit(_ url: URL, parent: UUID?) {
            let normalized = url.standardizedFileURL
            guard visited.insert(normalized).inserted else { return }
            let path = normalized.resolvingSymlinksInPath().path
            guard path != libraryPath, !path.hasPrefix(libraryPath + "/") else { return }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, values.isHidden != true,
                      values.isPackage != true, !url.lastPathComponent.hasPrefix(".") else { return }
                if values.isDirectory == true {
                    let contents = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
                                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    let folder = PaperLibraryFolder(id: UUID(), name: url.lastPathComponent, parentID: parent)
                    result.folders.append(folder)
                    for child in contents { visit(child, parent: folder.id) }
                } else if values.isRegularFile == true {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          CGImageSourceGetCount(source) > 0,
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                          width.doubleValue > 0, height.doubleValue > 0 else { return }
                    let id = UUID()
                    let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
                    let fileExtension = url.pathExtension.isEmpty ? (type?.preferredFilenameExtension ?? "img") : url.pathExtension
                    let fileName = id.uuidString + "." + fileExtension
                    let destination = directory.appendingPathComponent(fileName)
                    do {
                        try manager.copyItem(at: url, to: destination)
                    } catch {
                        try? manager.removeItem(at: destination)
                        throw error
                    }
                    result.copiedFiles.append(destination)
                    result.items.append(PaperLibraryItem(id: id, fileName: fileName,
                                                          displayName: url.deletingPathExtension().lastPathComponent,
                                                          parentID: parent))
                }
            } catch {
                result.failed += 1
            }
        }
        for url in urls { visit(url, parent: parentID) }
        return result
    }
}
