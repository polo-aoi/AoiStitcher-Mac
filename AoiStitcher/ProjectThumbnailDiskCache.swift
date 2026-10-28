import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Browsing tiers limit the long edge. Detail explicitly targets a 1080-pixel
/// short edge, preserving the original's aspect ratio and never upscaling.
nonisolated enum ProjectThumbnailResolution: Int, CaseIterable, Sendable {
    case browsing192, browsing384, browsing512, detail1080

    static func browsing(maximumPixelSize: Int) -> Self {
        if maximumPixelSize <= 192 { return .browsing192 }
        if maximumPixelSize <= 384 { return .browsing384 }
        return .browsing512
    }

    /// The caller supplies actual display pixels (points × backing scale).
    /// A small margin keeps scaling crisp without decoding the detail tier for
    /// every small grid cell.
    static func display(pixelSize: Int) -> Self {
        let target = ceil(Double(max(0, pixelSize)) * 1.25)
        guard target <= 512 else { return .detail1080 }
        return browsing(maximumPixelSize: Int(target))
    }

    var cacheKey: String {
        switch self {
        case .browsing192: return "192"
        case .browsing384: return "384"
        case .browsing512: return "512"
        case .detail1080: return "1080short"
        }
    }

    func maximumPixelSize(width: Int, height: Int) -> Int {
        switch self {
        case .browsing192: return 192
        case .browsing384: return 384
        case .browsing512: return 512
        case .detail1080:
            let shortEdge = max(1, min(width, height))
            let longEdge = max(width, height)
            guard shortEdge > 1080 else { return longEdge }
            return Int(ceil(1080 * Double(longEdge) / Double(shortEdge)))
        }
    }
}

/// Disposable browsing previews. Originals and Quick Look never use this cache.
/// All filesystem work and ImageIO decoding runs on the thumbnail operation queue.
nonisolated enum ProjectThumbnailDiskCache {
    static let maximumPixelSize = 192
    static let pixelSizes = [192, 384, 512]

    /// A few reusable sizes cover the grid and Retina displays without creating
    /// a separate decoded image for every position of the size slider.
    static func pixelSize(for requestedSize: Int) -> Int {
        pixelSizes.first(where: { $0 >= requestedSize }) ?? pixelSizes.last!
    }

    enum Source: Equatable { case original, disk }

    struct Result {
        let image: CGImage
        let source: Source
    }

    static func load(sourceURL: URL, cacheDirectory: URL, assetID: UUID, contentRevision: UUID?,
                     maximumPixelSize: Int = ProjectThumbnailDiskCache.maximumPixelSize,
                     decodeOriginal: ((URL) -> CGImage?)? = nil) -> Result? {
        load(sourceURL: sourceURL, cacheDirectory: cacheDirectory, assetID: assetID,
             contentRevision: contentRevision, resolution: .browsing(maximumPixelSize: maximumPixelSize),
             decodeOriginal: decodeOriginal)
    }

    static func load(sourceURL: URL, cacheDirectory: URL, assetID: UUID, contentRevision: UUID?,
                     resolution: ProjectThumbnailResolution,
                     decodeOriginal: ((URL) -> CGImage?)? = nil) -> Result? {
        // A replacement can finish while an earlier decode is running. Retry
        // that read once, and never save pixels under a different file's key.
        for _ in 0..<2 {
            guard let signature = signature(for: sourceURL, revision: contentRevision) else { return nil }
            let cacheURL = cacheDirectory.appendingPathComponent("\(assetID.uuidString)-\(signature)-\(resolution.cacheKey).png")
            if let image = readCached(cacheURL, resolution: resolution) {
                return Result(image: image, source: .disk)
            }
            let decoded: CGImage?
            if let decodeOriginal { decoded = decodeOriginal(sourceURL) }
            else { decoded = readOriginal(sourceURL, resolution: resolution) }
            guard let image = decoded else { return nil }
            guard signature == self.signature(for: sourceURL, revision: contentRevision) else { continue }
            // A full or read-only cache volume must not prevent the preview.
            write(image, to: cacheURL)
            return Result(image: image, source: .original)
        }
        return nil
    }

    private static func signature(for url: URL, revision: UUID?) -> String? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = values[.size] as? NSNumber,
              let modified = values[.modificationDate] as? Date else { return nil }
        let inode = (values[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let version = "\(revision?.uuidString ?? "original")/\(url.lastPathComponent)/\(size)/\(modified.timeIntervalSince1970.bitPattern)/\(inode)"
        return SHA256.hash(data: Data(version.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func readCached(_ url: URL, resolution: ProjectThumbnailResolution) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        if resolution == .detail1080 {
            // ImageIO may round an aspect-ratio division by a pixel.
            guard min(image.width, image.height) <= 1081 else { return nil }
        } else {
            guard max(image.width, image.height) <= resolution.maximumPixelSize(width: image.width, height: image.height)
                else { return nil }
        }
        return image
    }

    private static func readOriginal(_ url: URL, resolution: ProjectThumbnailResolution) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let maximumPixelSize = resolution.maximumPixelSize(width: width, height: height)
        let options: [CFString: Any] = [
            // Embedded camera previews may be much smaller than the requested
            // Retina tier. Decode from the image so an upgrade really is sharper.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func write(_ image: CGImage, to url: URL) {
        // Encode into memory first; the atomic file write cannot expose a
        // partially encoded preview to a future project-open request.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data as Data).write(to: url, options: .atomic)
        } catch { /* The next request can still decode the original. */ }
    }
}
