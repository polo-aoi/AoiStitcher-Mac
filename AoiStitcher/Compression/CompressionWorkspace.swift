import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class CompressionWorkspace: ObservableObject {
    static let settingsKey = "aoipic.compression.settings"
    static let customSettingsKey = "aoipic.compression.customSettings"
    static let outputFolderKey = "aoipic.compression.outputFolder"

    @Published private(set) var photos: [PhotoItem] = [] {
        didSet {
            if oldValue.map(\.id) != photos.map(\.id) { publishProjectStatus() }
        }
    }
    @Published var selectedIDs: Set<UUID> = []
    @Published var settings: ExportSettings {
        didSet {
            persist(settings, key: Self.settingsKey)
            if !settings.isPlatformPreset { customSettings = settings; persist(settings, key: Self.customSettingsKey) }
            if Self.renderSignature(oldValue) != Self.renderSignature(settings) && !isExporting {
                for index in photos.indices where photos[index].width > 0 {
                    photos[index].status = .waiting
                    photos[index].outputBytes = nil; photos[index].failure = nil; photos[index].exportedURL = nil
                }
                statusMessage = nil
            }
            publishProjectStatus()
        }
    }
    @Published private(set) var isImporting = false { didSet { publishProjectStatus() } }
    @Published private(set) var isExporting = false { didSet { publishProjectStatus() } }
    @Published private(set) var isCancelling = false
    @Published private(set) var exportCompleted = 0
    @Published private(set) var exportTotal = 0
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var lastExportDirectory: URL?
    @Published private(set) var lastExportedURL: URL?
    @Published var outputFolder: URL? {
        didSet {
            if let outputFolder { defaults.set(outputFolder.path, forKey: Self.outputFolderKey) }
            else { defaults.removeObject(forKey: Self.outputFolderKey) }
        }
    }

    private let defaults: UserDefaults
    private let processor = CompressionProcessor()
    private var customSettings: ExportSettings
    private var cancellation: CompressionCancellation?
    private weak var projectLibrary: ProjectLibraryStore?
    private weak var projectBridge: ProjectEditorBridge?
    private var exportedSignatures: [UUID: String] = [:]

    func connectProject(library: ProjectLibraryStore, bridge: ProjectEditorBridge) {
        projectLibrary = library; projectBridge = bridge
        publishProjectStatus()
    }

    private static func renderSignature(_ settings: ExportSettings) -> String {
        var rendered = settings
        rendered.applyPlatformRecipe()
        // Revealing the output folder does not change the exported image.
        rendered.revealAfterExport = false
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(rendered).base64EncodedString()) ?? ""
    }

    private func signature(for photo: PhotoItem, renderedSettings: String) -> String {
        photo.id.uuidString + "|" + photo.url.standardizedFileURL.path + "|" + renderedSettings
    }

    private func publishProjectStatus() {
        guard let projectBridge else { return }
        let renderedSettings = Self.renderSignature(settings)
        let signature = photos.map { self.signature(for: $0, renderedSettings: renderedSettings) }.joined(separator: "\n")
        projectBridge.update(operation: .compression, count: photos.count, signature: signature, isBusy: isBusy)
        if !photos.isEmpty, photos.allSatisfy({ exportedSignatures[$0.id] == self.signature(for: $0, renderedSettings: renderedSettings) }) {
            projectBridge.didExport(operation: .compression, signature: signature)
        }
    }

    init(defaults: UserDefaults = .standard, legacyDefaults: UserDefaults? = UserDefaults(suiteName: "studio.aoi.fit")) {
        self.defaults = defaults
        let migrateLegacy = defaults.data(forKey: Self.settingsKey) == nil
        let saved = defaults.data(forKey: Self.settingsKey) ?? legacyDefaults?.data(forKey: "AoiFit.settings")
        var restored = saved.flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) } ?? ExportSettings()
        restored.applyPlatformRecipe()
        if !restored.isPlatformPreset { restored.preset = "custom" }
        settings = restored
        customSettings = defaults.data(forKey: Self.customSettingsKey)
            .flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) }
            ?? (restored.isPlatformPreset ? ExportSettings() : restored)
        let path = defaults.string(forKey: Self.outputFolderKey)
            ?? (migrateLegacy ? legacyDefaults?.string(forKey: "AoiFit.outputFolder") : nil)
        if let path { outputFolder = URL(fileURLWithPath: path, isDirectory: true) }
        // Copy once into the existing AoiStitcher domain; never mutate AoiFit's preferences.
        persist(restored, key: Self.settingsKey)
        persist(customSettings, key: Self.customSettingsKey)
        if let outputFolder { defaults.set(outputFolder.path, forKey: Self.outputFolderKey) }
    }

    deinit { cancellation?.cancel() }

    var isBusy: Bool { isImporting || isExporting }
    var canExport: Bool { !photos.isEmpty && !isBusy }
    var failedCount: Int { photos.filter { $0.status == .failed }.count }
    var processingName: String? { photos.first { $0.status == .processing }?.url.lastPathComponent }
    var totalBytes: Int64 { photos.reduce(0) { $0 + $1.fileBytes } }

    private func persist(_ value: ExportSettings, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    func applyPreset(_ preset: String) {
        guard !isExporting, ["moments", "redbook", "douyin", "custom"].contains(preset) else { return }
        var next = settings
        next.preset = preset
        if preset == "custom" {
            next.dimension = customSettings.dimension; next.pixels = customSettings.pixels
            next.format = customSettings.format; next.quality = customSettings.quality
            next.allowUpscale = customSettings.allowUpscale
        } else { next.applyPlatformRecipe() }
        settings = next
    }

    func setPixels(_ value: Int) {
        guard !isExporting, !settings.isPlatformPreset else { return }
        settings.pixels = min(4320, max(320, value))
    }

    func importPanel() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "添加照片"; panel.prompt = "添加照片"
        panel.message = "可多选图片或文件夹，重复文件会自动忽略。"
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.image]
        present(panel) { [weak self] response in
            if response == .OK { self?.importURLs(panel.urls) }
        }
    }

    @discardableResult
    func importURLs(_ urls: [URL], mode: ProjectImportMode = .append, preservingInputOrder: Bool = false) -> Bool {
        guard !isBusy, !urls.isEmpty else { return false }
        isImporting = true; statusMessage = nil
        let existing = mode == .replace ? Set<String>()
            : Set(photos.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
        let expectedPaths = Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        var inputOrder: [String: Int] = [:]
        if preservingInputOrder {
            for (index, url) in urls.enumerated() {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if inputOrder[path] == nil { inputOrder[path] = index }
            }
        }
        let requestedOrder = inputOrder
        processor.importPhotos(urls, existing: existing) { [weak self] added in
            guard let self else { return }
            let ordered = preservingInputOrder ? added.enumerated().sorted { lhs, rhs in
                let leftPath = lhs.element.url.resolvingSymlinksInPath().standardizedFileURL.path
                let rightPath = rhs.element.url.resolvingSymlinksInPath().standardizedFileURL.path
                let leftIndex = requestedOrder[leftPath] ?? Int.max
                let rightIndex = requestedOrder[rightPath] ?? Int.max
                return leftIndex == rightIndex ? lhs.offset < rhs.offset : leftIndex < rightIndex
            }.map(\.element) : added
            if mode == .replace {
                let receivedPaths = Set(ordered.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
                guard !ordered.isEmpty, ordered.allSatisfy({ $0.status != .failed }), receivedPaths == expectedPaths else {
                    self.isImporting = false
                    self.errorMessage = "新照片未能全部读取，已保留当前列表。请检查文件后重试。"
                    return
                }
                self.exportedSignatures.removeAll()
                self.selectedIDs.removeAll()
                self.photos = ordered
            } else { self.photos.append(contentsOf: ordered) }
            self.isImporting = false
            if added.isEmpty { self.statusMessage = "没有新照片可添加" }
            else if added.contains(where: { $0.status == .failed }) {
                self.statusMessage = "部分文件读取失败，点击对应行的“失败”查看详情。"
            }
        }
        return true
    }

    func remove(_ ids: Set<UUID>) {
        guard !isBusy else { return }
        for id in ids { exportedSignatures.removeValue(forKey: id) }
        photos.removeAll { ids.contains($0.id) }; selectedIDs.subtract(ids)
        statusMessage = nil
    }

    func clearPhotos() {
        guard !isBusy else { return }
        exportedSignatures.removeAll()
        photos.removeAll(); selectedIDs.removeAll(); statusMessage = nil
        exportCompleted = 0; exportTotal = 0
    }

    func chooseOutputFolder() {
        guard !isExporting else { return }
        let panel = folderPanel(title: "选择输出位置", prompt: "选择文件夹")
        present(panel) { [weak self] response in
            if response == .OK { self?.outputFolder = panel.url }
        }
    }

    func exportAll(retryFailed: Bool = false) {
        guard canExport else { return }
        let items = retryFailed ? photos.filter { $0.status == .failed } : photos
        guard !items.isEmpty else { return }
        // A corrected output location must also apply to a retry.
        if let folder = outputFolder { beginBatch(items, directory: folder); return }
        let panel = folderPanel(title: "导出图片", prompt: "导出到这里")
        present(panel) { [weak self] response in
            if response == .OK, let folder = panel.url, let self, !self.isBusy {
                self.outputFolder = folder; self.beginBatch(items, directory: folder)
            }
        }
    }

    private func beginBatch(_ items: [PhotoItem], directory: URL) {
        var snapshot = settings
        snapshot.applyPlatformRecipe()
        let renderedSettings = Self.renderSignature(snapshot)
        let signatures = Dictionary(uniqueKeysWithValues: items.map { ($0.id, signature(for: $0, renderedSettings: renderedSettings)) })
        let contexts = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (UUID, ProjectExportContext)? in
            guard let context = projectLibrary?.captureExport(operation: .compression, sourceURLs: [item.url]) else { return nil }
            return (item.id, context)
        })
        let exportLibrary = projectLibrary
        let exportBridge = projectBridge
        exportBridge?.beginExport()
        let flag = CompressionCancellation()
        cancellation = flag; isExporting = true; isCancelling = false; statusMessage = nil
        exportCompleted = 0; exportTotal = items.count
        lastExportDirectory = directory; lastExportedURL = nil
        for item in items { update(CompressionProgress(id: item.id, status: .waiting)) }
        processor.export(items, settings: snapshot, directory: directory, cancellation: flag,
                         progress: { [weak self] progress in
            guard let self else { return }
            if progress.status == .done, let outputURL = progress.url {
                self.exportedSignatures[progress.id] = signatures[progress.id]
                if let context = contexts[progress.id] { exportLibrary?.recordExport(context, outputURL: outputURL) }
            }
            self.update(progress)
            if progress.status == .done || progress.status == .failed { self.exportCompleted += 1 }
        }, completion: { [weak self] result in
            exportBridge?.endExport()
            guard let self else { return }
            self.isExporting = false; self.isCancelling = false; self.cancellation = nil
            self.lastExportedURL = result.lastURL
            self.statusMessage = (result.cancelled ? "已停止 · " : "")
                + "已导出 \(result.succeeded) 张 · \(readableBytes(result.bytes))"
                + (result.failed > 0 ? " · \(result.failed) 张失败" : "")
            if result.succeeded > 0 && snapshot.revealAfterExport && !result.cancelled {
                NSWorkspace.shared.open(directory)
            }
        })
    }

    private func update(_ progress: CompressionProgress) {
        guard let index = photos.firstIndex(where: { $0.id == progress.id }) else { return }
        photos[index].status = progress.status; photos[index].failure = progress.error
        photos[index].outputBytes = progress.bytes; photos[index].exportedURL = progress.url
        if let source = progress.source {
            photos[index].width = source.width; photos[index].height = source.height
            photos[index].fileBytes = source.fileBytes
        }
    }

    func cancelExport() { isCancelling = true; cancellation?.cancel() }
    func showFailure(_ photo: PhotoItem) {
        errorMessage = photo.url.lastPathComponent + "\n" + (photo.failure ?? "无法处理这个文件。") + "\n\n" + photo.url.path
    }
    func revealExport() {
        if let url = lastExportedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func restoreDefaults() {
        guard !isExporting else { return }
        settings = ExportSettings(); outputFolder = nil
    }

    private func folderPanel(title: String, prompt: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title; panel.prompt = prompt
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.directoryURL = outputFolder ?? lastExportDirectory
        return panel
    }

    private func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
