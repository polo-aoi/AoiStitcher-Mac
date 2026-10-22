import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct LongStitchSidebarPage<Content: View>: View {
    let title: String
    var onBack: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").frame(width: 20, height: 22)
                }
                .buttonStyle(.borderless).help("返回").accessibilityLabel("返回")
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 42)
            Divider()
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background { LongStitchStableScrollViewConfigurator() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct LongStitchEdgeEditor: View {
    @ObservedObject var preferences: LongStitchPreferences
    @State var edge: LongStitchEdge
    var onWillChange: (() -> Void)?
    var onBack: () -> Void
    var openLibrary: (LongStitchEdge) -> Void
    @State private var copyTargets: Set<LongStitchEdge> = []

    private var margin: LongStitchMargin { preferences.settings[edge].sanitized() }
    private var item: WatermarkLibraryItem? { preferences.library.item(id: margin.watermarkID) }

    private func binding<Value>(_ keyPath: WritableKeyPath<LongStitchMargin, Value>) -> Binding<Value> {
        let target = edge
        return Binding {
            preferences.settings[target][keyPath: keyPath]
        } set: { value in
            onWillChange?()
            var next = preferences.settings
            var margin = next[target]
            margin[keyPath: keyPath] = value
            next[target] = margin.sanitized()
            preferences.settings = next
        }
    }

    private func percentageBinding(_ keyPath: WritableKeyPath<LongStitchMargin, Double>) -> Binding<Double> {
        let original = binding(keyPath)
        return Binding(get: { original.wrappedValue * 100 }, set: { original.wrappedValue = $0 / 100 })
    }

    var body: some View {
        LongStitchSidebarPage(title: "留白与水印", onBack: onBack) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("调整方向", selection: Binding(get: { edge }, set: { value in
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    edge = value
                })) {
                    ForEach(LongStitchEdge.allCases) { edge in Text(edge.title).tag(edge) }
                }.pickerStyle(.segmented).labelsHidden()

                HStack(spacing: 6) {
                    Text("\(edge.title)留白").frame(width: 56, alignment: .leading)
                    Toggle("\(edge.title)留白", isOn: binding(\.isEnabled))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
                    Spacer(minLength: 4)
                    LongStitchNumberField(title: "留白大小", value: binding(\.size), range: 0...16_384)
                        .disabled(!margin.isEnabled)
                    Text("px").foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { min(margin.size, 1600) }, set: { binding(\.size).wrappedValue = $0.rounded() }),
                       in: 0...1600) { editing in
                    if editing { LongStitchNumericEditing.discardDrafts() }
                }
                    .disabled(!margin.isEnabled)
                    .accessibilityLabel("留白大小")
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        LongStitchLibraryThumbnail(library: preferences.library, itemID: item?.id)
                            .frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item?.name ?? "未选择水印")
                                .font(.callout.weight(.medium)).lineLimit(2)
                            if let item, !item.note.isEmpty {
                                Text(item.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Button(item == nil ? "选择水印" : "更换水印") { openLibrary(edge) }
                        Spacer()
                        Button("取消使用") {
                            onWillChange?()
                            preferences.selectWatermark(nil, for: edge)
                        }.buttonStyle(.borderless).disabled(item == nil)
                    }
                }
                .disabled(!margin.isEnabled)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("水印大小")
                        Spacer()
                        LongStitchNumberField(title: "水印缩放", value: binding(\.watermarkScale),
                                              range: 0.05...5, decimals: 2)
                        Text("倍").foregroundStyle(.secondary)
                    }
                    Slider(value: binding(\.watermarkScale), in: 0.05...5) { editing in
                        if editing { LongStitchNumericEditing.discardDrafts() }
                    }
                        .accessibilityLabel("水印缩放")

                    HStack(alignment: .top, spacing: 14) {
                        positionGrid
                        VStack(alignment: .leading, spacing: 6) {
                            Text("对齐位置").font(.callout)
                            Text("选择九宫格后，可用下方数值微调。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    percentageRow("水平偏移", keyPath: \.offsetX)
                    percentageRow("垂直偏移", keyPath: \.offsetY)
                    Text("−100% 为左侧或顶部，0% 居中，100% 为右侧或底部。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("恢复水印大小和位置") {
                        LongStitchNumericEditing.discardDrafts()
                        onWillChange?()
                        preferences.resetWatermarkPlacement(for: edge)
                    }.buttonStyle(.borderless)
                }
                .disabled(!margin.isEnabled || item == nil)
                Divider()
                copyControls
            }.id(edge)
        }
        .onChange(of: edge) { _, _ in copyTargets.removeAll() }
    }

    private var positionGrid: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { column in
                        let x = Double(column - 1)
                        let y = Double(row - 1)
                        let selected = abs(margin.offsetX - x) < 0.005 && abs(margin.offsetY - y) < 0.005
                        Button {
                            LongStitchNumericEditing.discardDrafts()
                            onWillChange?()
                            var next = preferences.settings
                            next[edge].offsetX = x; next[edge].offsetY = y
                            preferences.settings = next
                        } label: {
                            Circle().fill(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                                .frame(width: 5, height: 5)
                                .frame(width: 23, height: 23)
                                .background(selected ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(["左", "中", "右"][column])\(["上", "中", "下"][row])对齐")
                    }
                }
            }
        }
    }

    private func percentageRow(_ title: String, keyPath: WritableKeyPath<LongStitchMargin, Double>) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                LongStitchNumberField(title: title, value: percentageBinding(keyPath), range: -100...100, decimals: 1)
                Text("%").foregroundStyle(.secondary)
            }
            Slider(value: percentageBinding(keyPath), in: -100...100) { editing in
                if editing { LongStitchNumericEditing.discardDrafts() }
            }
                .accessibilityLabel(title)
        }
    }

    private var copyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("复用到其他留白").font(.callout.weight(.semibold))
            HStack(spacing: 10) {
                ForEach(LongStitchEdge.allCases.filter { $0 != edge }) { target in
                    Toggle(target.title, isOn: Binding(
                        get: { copyTargets.contains(target) },
                        set: { selected in
                            if selected { copyTargets.insert(target) } else { copyTargets.remove(target) }
                        }
                    )).toggleStyle(.checkbox)
                }
            }
            Text("仅更换所选边的水印，保留各自的大小和位置。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("应用到所选留白") {
                onWillChange?()
                preferences.copyWatermark(from: edge, to: Array(copyTargets))
                copyTargets.removeAll()
            }.disabled(copyTargets.isEmpty || item == nil)
        }
        .disabled(!margin.isEnabled)
    }
}

struct LongStitchWatermarkLibraryPage: View {
    @ObservedObject var preferences: LongStitchPreferences
    let target: LongStitchEdge?
    var onBack: () -> Void
    var onAdd: () -> Void
    var onEdit: (UUID) -> Void
    var onSelected: (UUID) -> Void
    @State private var search = ""
    @State private var pendingDelete: WatermarkLibraryItem?
    @State private var errorMessage: String?

    private var filteredItems: [WatermarkLibraryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return preferences.library.items.filter { item in
            query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || item.note.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        LongStitchSidebarPage(title: target.map { "选择\($0.title)水印" } ?? "水印素材库", onBack: onBack) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("搜索名称或备注", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索水印名称或备注")
                Button(action: onAdd) {
                    Label("上传水印", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                if let error = preferences.library.loadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if filteredItems.isEmpty {
                    Text(search.isEmpty ? "还没有水印，上传后可在多个留白中复用。" : "没有匹配的水印。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 12)
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredItems) { item in
                        libraryRow(item)
                        Divider()
                    }
                }
            }
        }
        .alert("删除水印", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) { deletePendingItem() }
        } message: {
            if let item = pendingDelete { Text(deletionMessage(item)) }
        }
        .alert("无法删除水印", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func libraryRow(_ item: WatermarkLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { if target == nil { onEdit(item.id) } else { onSelected(item.id) } } label: {
                HStack(alignment: .top, spacing: 10) {
                    LongStitchLibraryThumbnail(library: preferences.library, itemID: item.id)
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        if !item.note.isEmpty {
                            Text(item.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let target, preferences.settings[target].watermarkID == item.id {
                            Label("当前使用", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                if target != nil { Button("使用") { onSelected(item.id) } }
                Button("名称与备注") { onEdit(item.id) }
                Spacer(minLength: 0)
                Button { pendingDelete = item } label: { Image(systemName: "trash") }
                    .help("删除\(item.name)").accessibilityLabel("删除\(item.name)")
            }.buttonStyle(.borderless).font(.caption)
        }
    }

    private func deletionMessage(_ item: WatermarkLibraryItem) -> String {
        let users = LongStitchEdge.allCases.filter { preferences.settings[$0].watermarkID == item.id }.map(\.title)
        return users.isEmpty ? "删除“\(item.name)”？此操作会从素材库移除该水印。"
            : "“\(item.name)”正在用于\(users.joined(separator: "、"))留白。删除后，这些留白将取消使用该水印。"
    }

    private func deletePendingItem() {
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        do { try preferences.deleteWatermark(item.id) }
        catch { errorMessage = error.localizedDescription }
    }
}

struct LongStitchWatermarkForm: View {
    @ObservedObject var preferences: LongStitchPreferences
    var onCancel: () -> Void
    var onComplete: (WatermarkLibraryItem) -> Void
    @State private var sourceURL: URL?
    @State private var preview: NSImage?
    @State private var name = ""
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        LongStitchSidebarPage(title: "上传水印", onBack: onCancel) {
            VStack(alignment: .leading, spacing: 14) {
                LongStitchWatermarkPreview(image: preview)
                Button(sourceURL == nil ? "选择图片…" : "更换图片…", action: chooseImage)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text("名称").font(.callout)
                    TextField("水印名称", text: $name).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("备注").font(.callout)
                    TextField("可选，方便查找和区分", text: $note, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(3...5)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("保存到水印库", action: save)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(sourceURL == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "选择水印图片"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
              ] as CFDictionary) else {
            errorMessage = "无法读取这张图片，请选择其他水印。"; return
        }
        sourceURL = url
        preview = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = url.deletingPathExtension().lastPathComponent }
        errorMessage = nil
    }

    private func save() {
        guard let sourceURL else { return }
        do {
            let item = try preferences.library.importImage(from: sourceURL, name: name, note: note)
            onComplete(item)
        } catch { errorMessage = error.localizedDescription }
    }
}

struct LongStitchWatermarkMetadataPage: View {
    @ObservedObject var preferences: LongStitchPreferences
    let itemID: UUID
    var onBack: () -> Void
    var onWillChange: (() -> Void)?
    @State private var name = ""
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var preview: NSImage?

    var body: some View {
        LongStitchSidebarPage(title: "名称与备注", onBack: onBack) {
            VStack(alignment: .leading, spacing: 14) {
                LongStitchWatermarkPreview(image: preview)
                VStack(alignment: .leading, spacing: 6) {
                    Text("名称").font(.callout)
                    TextField("水印名称", text: $name).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("备注").font(.callout)
                    TextField("可选，方便查找和区分", text: $note, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(3...5)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("保存修改") {
                    do {
                        try preferences.library.update(id: itemID, name: name, note: note)
                        onBack()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            guard let item = preferences.library.item(id: itemID) else { return }
            name = item.name; note = item.note
        }
        .task(id: itemID) { preview = preferences.library.thumbnail(for: itemID, maximumDimension: 600) }
    }
}

struct LongStitchShortcutAndExportPage: View {
    @ObservedObject var preferences: LongStitchPreferences
    var onBack: () -> Void
    var onWillChange: (() -> Void)?

    var body: some View {
        LongStitchSidebarPage(title: "快捷键与导出", onBack: onBack) {
            VStack(alignment: .leading, spacing: 18) {
                EditorSection("画布快捷键") {
                    Picker("拖拽查看", selection: $preferences.settings.panKey) {
                        ForEach(LongStitchPanKey.allCases) { key in Text(key.title).tag(key) }
                    }
                    Picker("滚轮缩放", selection: $preferences.settings.zoomModifier) {
                        ForEach(LongStitchZoomModifier.allCases) { key in Text(key.title).tag(key) }
                    }
                    Text("按住平移键拖动画布；按住缩放修饰键滚动。触控板双指捏合也可缩放。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                EditorSection("导出") {
                    LongStitchExportSettingsFields(preferences: preferences, onWillChange: onWillChange)
                }
            }
        }
    }
}

private struct LongStitchLibraryThumbnail: View {
    @ObservedObject var library: WatermarkLibraryStore
    let itemID: UUID?
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            LongStitchCheckerboard()
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)) }
        .task(id: itemID) { thumbnail = library.thumbnail(for: itemID, maximumDimension: 160) }
    }
}

private struct LongStitchWatermarkPreview: View {
    let image: NSImage?
    @State private var background = 0

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if background == 0 { LongStitchCheckerboard() }
                else if background == 1 { Color.white }
                else { Color(white: 0.15) }
                if let image { Image(nsImage: image).resizable().scaledToFit().padding(12) }
                else { Label("尚未选择图片", systemImage: "photo").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity).frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)) }
            Picker("预览底色", selection: $background) {
                Text("透明").tag(0)
                Text("浅色").tag(1)
                Text("深色").tag(2)
            }.labelsHidden().pickerStyle(.segmented)
        }
    }
}

private struct LongStitchCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.95)))
            let rows = Int(ceil(size.height / side))
            let columns = Int(ceil(size.width / side))
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side,
                                             width: side, height: side)), with: .color(Color(white: 0.83)))
                }
            }
        }
    }
}
