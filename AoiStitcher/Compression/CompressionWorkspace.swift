import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class CompressionWorkspace: ObservableObject {
    static let settingsKey = "aoipic.compression.settings"
    static let customSettingsKey = "aoipic.compression.customSettings"
    static let outputFolderKey = "aoipic.compression.outputFolder"

    @Published private(set) var photos: [PhotoItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var settings: ExportSettings {
        didSet {
            persist(settings, key: Self.settingsKey)
            if !settings.isPlatformPreset { customSettings = settings; persist(settings, key: Self.customSettingsKey) }
            if oldValue != settings && !isExporting {
                for index in photos.indices where photos[index].width > 0 {
                    photos[index].status = .waiting
                    photos[index].outputBytes = nil; photos[index].failure = nil; photos[index].exportedURL = nil
                }
                statusMessage = nil
            }
        }
    }
    @Published private(set) var isImporting = false
    @Published private(set) var isExporting = false
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
    func importURLs(_ urls: [URL]) -> Bool {
        guard !isBusy, !urls.isEmpty else { return false }
        isImporting = true; statusMessage = nil
        let existing = Set(photos.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
        processor.importPhotos(urls, existing: existing) { [weak self] added in
            guard let self else { return }
            self.photos.append(contentsOf: added); self.isImporting = false
            if added.isEmpty { self.statusMessage = "没有新照片可添加" }
            else if added.contains(where: { $0.status == .failed }) {
                self.statusMessage = "部分文件读取失败，点击对应行的“失败”查看详情。"
            }
        }
        return true
    }

    func remove(_ ids: Set<UUID>) {
        guard !isBusy else { return }
        photos.removeAll { ids.contains($0.id) }; selectedIDs.subtract(ids)
        statusMessage = nil
    }

    func clearPhotos() {
        guard !isBusy else { return }
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
        let flag = CompressionCancellation()
        cancellation = flag; isExporting = true; isCancelling = false; statusMessage = nil
        exportCompleted = 0; exportTotal = items.count
        lastExportDirectory = directory; lastExportedURL = nil
        for item in items { update(CompressionProgress(id: item.id, status: .waiting)) }
        processor.export(items, settings: snapshot, directory: directory, cancellation: flag,
                         progress: { [weak self] progress in
            guard let self else { return }
            self.update(progress)
            if progress.status == .done || progress.status == .failed { self.exportCompleted += 1 }
        }, completion: { [weak self] result in
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
