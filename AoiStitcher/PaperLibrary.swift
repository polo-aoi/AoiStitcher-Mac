import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

struct PaperLibraryItem: Identifiable, Codable, Equatable {
    var id: UUID
    var fileName: String
    var displayName: String

    var url: URL {
        PaperLibraryStore.libraryDirectory.appendingPathComponent(fileName)
    }
}

@MainActor final class PaperLibraryStore: ObservableObject {
    static let pageSize = 10
    static let paperPasteboardType = NSPasteboard.PasteboardType("com.aoipic.paper-url")
    static let libraryDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("aoipic/PaperLibrary", isDirectory: true)
    }()
    private static let indexURL = libraryDirectory.appendingPathComponent("index.json")

    @Published private(set) var items: [PaperLibraryItem] = []
    @Published var message: String?

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let decoded = try? JSONDecoder().decode([PaperLibraryItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        persist()
    }

    func importPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: Self.libraryDirectory, withIntermediateDirectories: true)
            var imported = 0
            for url in urls {
                guard let source = NSImage(contentsOf: url) else { continue }
                let id = UUID()
                let sourceExt = url.pathExtension.lowercased()
                let useJPEG = sourceExt == "jpg" || sourceExt == "jpeg"
                let outputExt = useJPEG ? "jpg" : "png"
                let fileName = "\(id.uuidString).\(outputExt)"
                let destination = Self.libraryDirectory.appendingPathComponent(fileName)
                guard let data = source.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: data),
                      let encoded = rep.representation(using: useJPEG ? .jpeg : .png, properties: [:]) else { continue }
                try encoded.write(to: destination, options: .atomic)
                items.append(PaperLibraryItem(id: id, fileName: fileName, displayName: url.deletingPathExtension().lastPathComponent))
                imported += 1
            }
            persist()
            if imported < urls.count { message = "有 \(urls.count - imported) 个文件无法保存到纸张库。" }
        } catch {
            message = "保存纸张失败：\(error.localizedDescription)"
        }
    }

    func remove(_ item: PaperLibraryItem) {
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
        persist()
    }

    func move(_ item: PaperLibraryItem, offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let destination = min(items.count - 1, max(0, index + offset))
        guard destination != index else { return }
        items.swapAt(index, destination)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: Self.libraryDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}

struct PaperLibraryView: View {
    @ObservedObject var library: PaperLibraryStore
    let onUse: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme
    @State private var page = 0
    @State private var expandedID: UUID?

    private var pageItems: [PaperLibraryItem] {
        let start = page * PaperLibraryStore.pageSize
        guard start < library.items.count else { return [] }
        return Array(library.items.dropFirst(start).prefix(PaperLibraryStore.pageSize))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("纸张库").font(.title3.weight(.semibold))
                Spacer()
                Button { library.importPanel() } label: { Label("导入纸张", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("点击纸张展开，选择后可作为底图加入画布。每页最多显示 10 张，原文件会复制到 AoiStitcher 资源目录。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if pageItems.isEmpty {
                ContentUnavailableView("暂无纸张", systemImage: "doc", description: Text("点击右上角导入纸张。"))
                    .frame(maxWidth: .infinity, minHeight: 210)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: expandedID == nil ? -62 : -10) {
                        ForEach(pageItems) { item in
                            paperCard(item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(page == 0)
                        Text("第 \(page + 1) / \(max(1, (library.items.count + 9) / 10)) 页")
                            .font(.callout.monospacedDigit())
                        Button { page = min(max(0, (library.items.count - 1) / 10), page + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled((page + 1) * 10 >= library.items.count)
                        Spacer()
                        if let selected = pageItems.first(where: { $0.id == expandedID }) {
                            Button { library.move(selected, offset: -1) } label: { Label("前移", systemImage: "arrow.left") }
                                .disabled(library.items.first?.id == selected.id)
                            Button { library.move(selected, offset: 1) } label: { Label("后移", systemImage: "arrow.right") }
                                .disabled(library.items.last?.id == selected.id)
                            Button(role: .destructive) { library.remove(selected); expandedID = nil } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button("添加到底图") { onUse(selected.url); dismiss() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 920, height: 340)
        .preferredColorScheme(theme == 2 ? .dark : .light)
        .alert("纸张库", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("确定") { library.message = nil }
        } message: { Text(library.message ?? "") }
    }

    @ViewBuilder private func paperCard(_ item: PaperLibraryItem) -> some View {
        let selected = expandedID == item.id
        Button { withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) { expandedID = selected ? nil : item.id } } label: {
            VStack(spacing: 7) {
                if let image = NSImage(contentsOf: item.url) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: selected ? 130 : 74, height: 130)
                        .clipped()
                } else {
                    Image(systemName: "doc").font(.title2).frame(height: 130)
                }
                Text(item.displayName).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .padding(8)
            .frame(width: selected ? 150 : 94, height: 174)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 1.5 : 0.8))
        }
        .buttonStyle(.plain)
        .help(selected ? "已展开，下面可添加到底图" : "点击展开")
        .zIndex(selected ? 100 : Double(pageItems.firstIndex(where: { $0.id == item.id }) ?? 0))
        .onDrag { paperDragProvider(for: item) }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: selected)
    }

    private func paperDragProvider(for item: PaperLibraryItem) -> NSItemProvider {
        let provider = NSItemProvider()
        let urlString = item.url.absoluteString
        provider.registerDataRepresentation(forTypeIdentifier: PaperLibraryStore.paperPasteboardType.rawValue,
                                            visibility: .all) { completion in
            completion(Data(urlString.utf8), nil)
            return nil
        }
        return provider
    }
}
