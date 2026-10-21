import Foundation
import UniformTypeIdentifiers

nonisolated final class CompressionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

nonisolated struct CompressionProgress: Sendable {
    var id: UUID
    var status: PhotoStatus
    var url: URL?
    var bytes: Int?
    var error: String?
    var source: PhotoItem?
}

nonisolated struct CompressionResult: Sendable {
    var succeeded = 0
    var failed = 0
    var bytes: Int64 = 0
    var lastURL: URL?
    var cancelled = false
}

/// Serial, bounded-memory processing. No AppKit or SwiftUI dependency.
nonisolated final class CompressionProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aoipic.compression", qos: .userInitiated)
    private let pipeline = ImagePipeline()

    func importPhotos(_ urls: [URL], existing: Set<String>,
                      completion: @escaping @MainActor @Sendable ([PhotoItem]) -> Void) {
        queue.async {
            var candidates: [URL] = [], seen = existing
            var failures: [PhotoItem] = []
            for url in urls where url.isFileURL {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                    let enumerator = FileManager.default.enumerator(
                        at: url, includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                        errorHandler: { failedURL, error in
                            failures.append(Self.failedImport(failedURL, error: error))
                            return true
                        })
                    while let item = enumerator?.nextObject() as? URL {
                        if UTType(filenameExtension: item.pathExtension)?.conforms(to: .image) == true {
                            candidates.append(item)
                        }
                    }
                } else { candidates.append(url) }
            }
            var added: [PhotoItem] = []
            for url in candidates.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                guard seen.insert(url.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { continue }
                autoreleasepool {
                    do { added.append(try ImagePipeline.inspect(url)) }
                    catch { added.append(Self.failedImport(url, error: error)) }
                }
            }
            let result = added + failures
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func failedImport(_ url: URL, error: Error) -> PhotoItem {
        PhotoItem(url: url, width: 0, height: 0, fileBytes: 0,
                  status: .failed, failure: error.localizedDescription)
    }

    func export(_ items: [PhotoItem], settings: ExportSettings, directory: URL,
                cancellation: CompressionCancellation,
                progress: @escaping @MainActor @Sendable (CompressionProgress) -> Void,
                completion: @escaping @MainActor @Sendable (CompressionResult) -> Void) {
        queue.async {
            var summary = CompressionResult()
            for item in items {
                if cancellation.isCancelled { break }
                DispatchQueue.main.async { progress(CompressionProgress(id: item.id, status: .processing)) }
                let result: Result<(URL, Int, PhotoItem), Error> = autoreleasepool {
                    Result {
                        // Reinspect so a replaced or repaired source gets its current dimensions.
                        let current = try ImagePipeline.inspect(item.url)
                        let image = try self.pipeline.render(current, settings: settings)
                        if cancellation.isCancelled { throw CancellationError() }
                        let url = ImagePipeline.batchDestination(photo: item, directory: directory,
                                                                format: settings.effectiveFormat)
                        try ImagePipeline.write(image.data, to: url)
                        return (url, image.data.count, current)
                    }
                }
                let update: CompressionProgress
                switch result {
                case .success(let (url, bytes, current)):
                    summary.succeeded += 1; summary.bytes += Int64(bytes); summary.lastURL = url
                    update = CompressionProgress(id: item.id, status: .done, url: url, bytes: bytes, source: current)
                case .failure(let error) where error is CancellationError:
                    update = CompressionProgress(id: item.id, status: .waiting)
                case .failure(let error):
                    summary.failed += 1
                    update = CompressionProgress(id: item.id, status: .failed, error: error.localizedDescription)
                }
                DispatchQueue.main.async { progress(update) }
                if cancellation.isCancelled { break }
            }
            summary.cancelled = cancellation.isCancelled
            let result = summary
            DispatchQueue.main.async { completion(result) }
        }
    }
}
