import AppKit
import ImageIO

@main struct CompressionWorkspaceTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let domain = "aoipic.compression.tests." + UUID().uuidString
        let legacyDomain = domain + ".legacy"
        let defaults = UserDefaults(suiteName: domain)!, legacy = UserDefaults(suiteName: legacyDomain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            legacy.removePersistentDomain(forName: legacyDomain)
        }
        var checks: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) throws {
            checks.append(["name": name, "passed": value])
            guard value else { throw NSError(domain: "CompressionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        }
        func wait(_ work: CompressionWorkspace) async throws {
            let deadline = Date().addingTimeInterval(60)
            while work.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try check("queue finishes without blocking the main actor", !work.isBusy)
        }
        let fixtures = root.appendingPathComponent("Tests/Compression/Fixtures/Inputs")
        let inputs = try ["portrait_2560x3840.jpg", "landscape_4000x2400.png", "small_640x480.jpg"].map { name -> URL in
            let target = output.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: target)
            return target
        }
        let sourceData = try inputs.map { try Data(contentsOf: $0) }
        defaults.set("2200", forKey: "exportWidth"); defaults.set(false, forKey: "exportPNG")
        defaults.set(2, forKey: "colorSchemeStyle"); defaults.set("/original/folder", forKey: "lastExportDir")
        var saved = ExportSettings()
        saved.preset = "moments"; saved.format = .png; saved.quality = 62; saved.allowUpscale = true
        saved.dimension = .height; saved.pixels = 640; saved.revealAfterExport = false
        let savedData = try JSONEncoder().encode(saved)
        legacy.set(savedData, forKey: "AoiFit.settings")
        legacy.set("/legacy/output", forKey: "AoiFit.outputFolder")
        let work = CompressionWorkspace(defaults: defaults, legacyDefaults: legacy)
        try check("legacy platform settings normalize automatic recipe", work.settings.pixels == 1920 && work.settings.dimension == .shortest && work.settings.effectiveFormat == .jpeg && !work.settings.allowUpscale)
        try check("migration preserves AoiFit preferences", legacy.data(forKey: "AoiFit.settings") == savedData)
        try check("migration preserves existing stitch and appearance preferences", defaults.string(forKey: "exportWidth") == "2200" && !defaults.bool(forKey: "exportPNG") && defaults.integer(forKey: "colorSchemeStyle") == 2 && defaults.string(forKey: "lastExportDir") == "/original/folder")
        work.setPixels(1080)
        try check("platform rejects stale size edits", work.settings.pixels == 1920)
        work.applyPreset("custom"); work.settings.format = .heic; work.settings.quality = 82
        work.settings.dimension = .width; work.setPixels(1440); work.settings.allowUpscale = true
        work.applyPreset("redbook"); work.applyPreset("douyin")
        try check("Douyin selection uses the automatic 2160 JPG recipe", work.settings.preset == "douyin" && work.settings.dimension == .shortest && work.settings.pixels == 2160 && work.settings.effectiveFormat == .jpeg && !work.settings.allowUpscale)
        work.setPixels(1080)
        try check("Douyin rejects manual size edits", work.settings.pixels == 2160)
        work.applyPreset("custom")
        try check("custom dimensions format and quality survive platform switches", work.settings.pixels == 1440 && work.settings.dimension == .width && work.settings.format == .heic && work.settings.quality == 82 && work.settings.allowUpscale)
        work.applyPreset("douyin")
        let restored = CompressionWorkspace(defaults: defaults, legacyDefaults: nil)
        try check("Douyin selection persists across relaunch", restored.settings.preset == "douyin" && restored.settings.pixels == 2160 && restored.settings.isPlatformPreset)
        restored.applyPreset("custom")
        try check("custom recipe survives relaunch from platform mode", restored.settings.pixels == 1440 && restored.settings.format == .heic && restored.settings.quality == 82)
        work.settings.revealAfterExport = false
        try check("empty queue cannot export", !work.canExport)
        work.importURLs(inputs); try await wait(work)
        try check("multi-file import enables export", work.photos.count == 3 && work.canExport)
        let alias = output.appendingPathComponent("alias.jpg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inputs[0])
        work.importURLs(inputs + [alias]); try await wait(work)
        try check("duplicates and symbolic aliases are ignored", work.photos.count == 3)
        let bad = output.appendingPathComponent("broken.png")
        try Data("invalid image".utf8).write(to: bad)
        work.importURLs([bad]); try await wait(work)
        try check("invalid import stays in list with exact filename and error", work.photos.last?.url == bad && work.photos.last?.status == .failed && work.photos.last?.failure != nil)
        let exports = output.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        work.outputFolder = exports
        work.exportAll(); try await wait(work)
        try check("batch records every result and isolates failure", work.photos.filter { $0.status == .done }.count == 3 && work.failedCount == 1 && work.exportCompleted == 4)
        let douyinSizes = ["portrait_2560x3840": CGSize(width: 2160, height: 3240),
                           "landscape_4000x2400": CGSize(width: 3600, height: 2160),
                           "small_640x480": CGSize(width: 640, height: 480)]
        for photo in work.photos where photo.status == .done {
            let data = try Data(contentsOf: photo.exportedURL!)
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let size = douyinSizes[photo.name]!
            try check("actual output dimensions and format: " + photo.name, image.width == Int(size.width) && image.height == Int(size.height) && CGImageSourceGetType(source) as String? == "public.jpeg" && data.count == photo.outputBytes)
        }
        let firstURLs = work.photos.compactMap(\.exportedURL)
        let firstData = try firstURLs.map { try Data(contentsOf: $0) }
        work.applyPreset("moments")
        try check("switching away from Douyin resets completed rows for the new recipe", work.photos.prefix(3).allSatisfy { $0.status == .waiting && $0.exportedURL == nil } && work.settings.pixels == 1920)
        work.applyPreset("douyin")
        work.exportAll(); try await wait(work)
        try check("repeat batch auto-numbers without altering earlier exports", try firstURLs.map { try Data(contentsOf: $0) } == firstData && FileManager.default.contentsOfDirectory(atPath: exports.path).count == 6)
        // Repair the invalid source; retry only this row, preserving completed rows.
        try sourceData[2].write(to: bad)
        let completedURLs = work.photos.filter { $0.status == .done }.map(\.exportedURL)
        work.exportAll(retryFailed: true); try await wait(work)
        try check("retry handles repaired source and preserves successful rows", work.failedCount == 0 && work.exportTotal == 1 && Array(work.photos.prefix(3)).map(\.exportedURL) == completedURLs)
        try check("repaired source refreshes dimensions and byte count", work.photos.last?.width == 640 && work.photos.last?.height == 480 && work.photos.last?.fileBytes == Int64(sourceData[2].count))
        work.outputFolder = output.appendingPathComponent("missing")
        work.exportAll(); try await wait(work)
        try check("unwritable destination produces a failure on every file", work.failedCount == 4 && work.photos.allSatisfy { $0.failure != nil })
        work.outputFolder = exports
        work.exportAll(retryFailed: true); try await wait(work)
        try check("retry uses newly selected output folder", work.failedCount == 0 && work.photos.allSatisfy { $0.exportedURL?.deletingLastPathComponent().path == exports.path })
        let beforeCancel = try FileManager.default.contentsOfDirectory(atPath: exports.path).count
        work.exportAll(); work.cancelExport(); try await wait(work)
        try check("cancel leaves no stuck rows or partial new files", work.exportCompleted == 0 && work.photos.allSatisfy { $0.status == .waiting } && FileManager.default.contentsOfDirectory(atPath: exports.path).count == beforeCancel)
        try check("cancel result is visible", work.statusMessage?.hasPrefix("已停止") == true)
        try check("no staging files remain after success failure or cancellation", !FileManager.default.contentsOfDirectory(atPath: exports.path).contains { $0.hasPrefix(".aoipic-") })
        work.remove(Set(work.photos.prefix(2).map(\.id)))
        try check("multi-selection removal only changes the queue", work.photos.count == 2 && inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        work.clearPhotos()
        try check("clear resets queue and progress", work.photos.isEmpty && work.selectedIDs.isEmpty && work.exportCompleted == 0 && !work.canExport)
        // Folder imports use the same entry point as Finder drops.
        work.importURLs([fixtures]); try await wait(work)
        try check("folder drop imports all supported images", work.photos.count == 3)
        work.clearPhotos()
        try check("all original input bytes remain unchanged", try inputs.map { try Data(contentsOf: $0) } == sourceData)
        try check("saved output folder restores", CompressionWorkspace(defaults: defaults, legacyDefaults: nil).outputFolder?.path == exports.path)
        work.restoreDefaults()
        try check("compression reset leaves old settings untouched", defaults.string(forKey: "exportWidth") == "2200" && defaults.integer(forKey: "colorSchemeStyle") == 2 && work.outputFolder == nil)
        try check("reset stays reset after relaunch without reimporting legacy folder", CompressionWorkspace(defaults: defaults, legacyDefaults: legacy).outputFolder == nil)
        let report: [String: Any] = ["checks": checks, "passed": checks.count, "failed": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("workspace-results.json"))
        print("PASS: \(checks.count) compression workflow checks. " + output.path)
    }
}
