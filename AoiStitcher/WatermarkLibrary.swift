import AppKit
import Combine
import Foundation
import ImageIO

struct WatermarkLibraryItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var note: String
    var fileName: String
    /// Used only to make migration from the former single-watermark file idempotent.
    var legacySourceIdentifier: String?

    init(id: UUID = UUID(), name: String, note: String = "", fileName: String,
         legacySourceIdentifier: String? = nil) {
        self.id = id
        self.name = name
        self.note = note
        self.fileName = fileName
        self.legacySourceIdentifier = legacySourceIdentifier
    }
}

@MainActor
final class WatermarkLibraryStore: ObservableObject {
    static let shared = WatermarkLibraryStore()

    @Published private(set) var items: [WatermarkLibraryItem] = []
    @Published private(set) var loadError: String?

    private struct Index: Codable {
        var version = 1
        var items: [WatermarkLibraryItem]
    }

    private let directoryURL: URL
    private let indexURL: URL
    private let imageCache = NSCache<NSString, NSImage>()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var canWriteIndex = true
    private var failedImageIDs = Set<UUID>()
    private var failedThumbnailKeys = Set<String>()
    private var pendingReadError: String?

    init(directoryURL: URL? = nil) {
        let resolvedDirectory = directoryURL ?? Self.defaultDirectory
        self.directoryURL = resolvedDirectory
        self.indexURL = resolvedDirectory.appendingPathComponent("index.json")
        imageCache.countLimit = 6
        imageCache.totalCostLimit = 160 * 1024 * 1024
        thumbnailCache.countLimit = 32
        thumbnailCache.totalCostLimit = 24 * 1024 * 1024
        loadIndex()
    }

    func item(id: UUID?) -> WatermarkLibraryItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func image(for id: UUID?) -> NSImage? {
        guard let item = item(id: id) else { return nil }
        let key = item.id.uuidString as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard !failedImageIDs.contains(item.id) else { return nil }
        let url = imageURL(for: item)
        guard let image = NSImage(contentsOf: url),
              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            failedImageIDs.insert(item.id)
            reportReadError("无法读取水印“\(item.name)”的图片文件。")
            return nil
        }
        let byteCost = Int64(pixels.width) * Int64(pixels.height) * 4
        imageCache.setObject(image, forKey: key, cost: Int(min(byteCost, Int64(Int.max))))
        return image
    }

    func thumbnail(for id: UUID?, maximumDimension: CGFloat = 240) -> NSImage? {
        guard let item = item(id: id) else { return nil }
        let limit = max(1, min(maximumDimension.isFinite ? maximumDimension : 240, 2048))
        let key = "\(item.id.uuidString)-\(Int(limit))" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard !failedThumbnailKeys.contains(key as String) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(limit),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(imageURL(for: item) as CFURL,
                                                     [kCGImageSourceShouldCache: false] as CFDictionary),
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            failedThumbnailKeys.insert(key as String)
            reportReadError("无法读取水印“\(item.name)”的缩略图。")
            return nil
        }
        let thumbnail = NSImage(cgImage: pixels,
                                size: NSSize(width: pixels.width, height: pixels.height))
        thumbnailCache.setObject(thumbnail, forKey: key,
                                 cost: pixels.width * pixels.height * 4)
        return thumbnail
    }

    @discardableResult
    func importImage(from url: URL, name: String, note: String) throws -> WatermarkLibraryItem {
        try importImage(from: url, name: name, note: note, legacySourceIdentifier: nil)
    }

    @discardableResult
    func importLegacyImage(from url: URL, name: String, note: String,
                           legacySourceIdentifier: String) throws -> WatermarkLibraryItem {
        if let existing = item(legacySourceIdentifier: legacySourceIdentifier) { return existing }
        return try importImage(from: url, name: name, note: note,
                               legacySourceIdentifier: legacySourceIdentifier)
    }

    func update(id: UUID, name: String, note: String) throws {
        guard canWriteIndex else { throw WatermarkLibraryError.indexUnreadable }
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw WatermarkLibraryError.itemNotFound
        }
        var updated = items
        updated[index].name = normalizedName(name, fallback: updated[index].name)
        updated[index].note = note
        try persist(updated)
        items = updated
        loadError = nil
        thumbnailCache.removeObject(forKey: "\(id.uuidString)-240" as NSString)
    }

    func remove(id: UUID) throws {
        guard canWriteIndex else { throw WatermarkLibraryError.indexUnreadable }
        guard let existing = items.first(where: { $0.id == id }) else {
            throw WatermarkLibraryError.itemNotFound
        }
        let candidate = items.filter { $0.id != id }
        let sourceURL = imageURL(for: existing)
        var quarantinedURL: URL?
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            let quarantine = directoryURL.appendingPathComponent(".delete-\(UUID().uuidString).png")
            do {
                try FileManager.default.moveItem(at: sourceURL, to: quarantine)
                quarantinedURL = quarantine
            } catch {
                throw WatermarkLibraryError.fileOperation(error.localizedDescription)
            }
        }
        do {
            try persist(candidate)
        } catch {
            if let quarantinedURL {
                do {
                    try FileManager.default.moveItem(at: quarantinedURL, to: sourceURL)
                } catch {
                    throw WatermarkLibraryError.fileOperation(
                        "更新索引失败，且无法恢复原水印文件：\(error.localizedDescription)"
                    )
                }
            }
            throw error
        }
        items = candidate
        loadError = nil
        let key = id.uuidString as NSString
        imageCache.removeObject(forKey: key)
        thumbnailCache.removeObject(forKey: "\(id.uuidString)-240" as NSString)
        if let quarantinedURL {
            do {
                try FileManager.default.removeItem(at: quarantinedURL)
            } catch {
                let message = "水印已从库中删除，但清理旧文件失败：\(error.localizedDescription)"
                loadError = message
            }
        }
    }

    func item(legacySourceIdentifier: String) -> WatermarkLibraryItem? {
        items.first { $0.legacySourceIdentifier == legacySourceIdentifier }
    }

    func reload() {
        pendingReadError = nil
        failedImageIDs.removeAll()
        failedThumbnailKeys.removeAll()
        imageCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        loadIndex()
    }

    private func importImage(from url: URL, name: String, note: String,
                             legacySourceIdentifier: String?) throws -> WatermarkLibraryItem {
        guard canWriteIndex else { throw WatermarkLibraryError.indexUnreadable }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = NSImage(contentsOf: url),
              let pixels = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WatermarkLibraryError.invalidImage(url.lastPathComponent)
        }
        let bitmap = NSBitmapImageRep(cgImage: pixels)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw WatermarkLibraryError.cannotEncodeImage
        }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let destination = directoryURL.appendingPathComponent(fileName)
        let item = WatermarkLibraryItem(id: id,
                                        name: normalizedName(name, fallback: url.deletingPathExtension().lastPathComponent),
                                        note: note,
                                        fileName: fileName,
                                        legacySourceIdentifier: legacySourceIdentifier)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            do {
                try persist(items + [item])
            } catch {
                do {
                    try FileManager.default.removeItem(at: destination)
                } catch {
                    throw WatermarkLibraryError.fileOperation(
                        "索引保存失败，且无法回滚新水印文件：\(error.localizedDescription)"
                    )
                }
                throw error
            }
        } catch let error as WatermarkLibraryError {
            throw error
        } catch {
            throw WatermarkLibraryError.fileOperation(error.localizedDescription)
        }
        items.append(item)
        loadError = nil
        let byteCost = Int64(pixels.width) * Int64(pixels.height) * 4
        imageCache.setObject(NSImage(cgImage: pixels,
                                     size: NSSize(width: pixels.width, height: pixels.height)),
                             forKey: id.uuidString as NSString,
                             cost: Int(min(byteCost, Int64(Int.max))))
        return item
    }

    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            items = []
            canWriteIndex = true
            loadError = nil
            return
        }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode(Index.self, from: data)
            guard decoded.version == 1 else { throw WatermarkLibraryError.unsupportedIndexVersion }
            guard decoded.items.allSatisfy({ safeFileName($0.fileName) }),
                  Set(decoded.items.map(\.id)).count == decoded.items.count else {
                throw WatermarkLibraryError.invalidIndex
            }
            items = decoded.items
            canWriteIndex = true
            loadError = nil
        } catch {
            canWriteIndex = false
            loadError = "无法读取水印库索引；为避免覆盖素材，当前水印库暂时只读。\n\(error.localizedDescription)"
        }
    }

    private func persist(_ candidate: [WatermarkLibraryItem]) throws {
        guard canWriteIndex else { throw WatermarkLibraryError.indexUnreadable }
        let index = Index(items: candidate)
        let data: Data
        do {
            data = try JSONEncoder().encode(index)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            throw WatermarkLibraryError.fileOperation(error.localizedDescription)
        }
    }

    private func imageURL(for item: WatermarkLibraryItem) -> URL {
        directoryURL.appendingPathComponent(item.fileName)
    }

    private func reportReadError(_ message: String) {
        guard loadError != message, pendingReadError != message else { return }
        pendingReadError = message
        // Image requests can originate in a SwiftUI body; publish on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingReadError == message else { return }
            self.pendingReadError = nil
            self.loadError = message
        }
    }

    private func safeFileName(_ value: String) -> Bool {
        !value.isEmpty && value == URL(fileURLWithPath: value).lastPathComponent && value.lowercased().hasSuffix(".png")
    }

    private func normalizedName(_ value: String, fallback: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("aoipic/WatermarkLibrary", isDirectory: true)
    }
}

enum WatermarkLibraryError: LocalizedError {
    case indexUnreadable
    case invalidIndex
    case unsupportedIndexVersion
    case itemNotFound
    case invalidImage(String)
    case cannotEncodeImage
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case .indexUnreadable:
            return "水印库索引无法读取，为保护已有素材，暂时不能修改水印库。"
        case .invalidIndex:
            return "水印库索引包含无效文件名，为避免访问库外文件，当前水印库只读。"
        case .unsupportedIndexVersion:
            return "水印库格式版本不受支持。"
        case .itemNotFound:
            return "找不到要操作的水印素材。"
        case .invalidImage(let name):
            return "无法读取图片“\(name)”，请选择有效的水印图片。"
        case .cannotEncodeImage:
            return "无法以 PNG 格式保存水印图片。"
        case .fileOperation(let reason):
            return "水印库保存失败：\(reason)"
        }
    }
}
