import AppKit
import UniformTypeIdentifiers

enum EditorFileDropContent {
    /// Finder supplies file URLs through item providers. Collect the whole
    /// drag before importing so multiple photos retain their original order.
    static func loadFileURLs(from providers: [NSItemProvider],
                             completion: @escaping ([URL]) -> Void) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [(Int, URL)] = []
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? String {
                    url = URL(string: value)
                } else {
                    url = nil
                }
                if let url, url.isFileURL {
                    lock.lock(); loaded.append((index, url)); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            completion(loaded.sorted { $0.0 < $1.0 }.map(\.1))
        }
        return true
    }
}
