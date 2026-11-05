import AppKit
import ImageIO
import SwiftUI

/// A compact library that stays beside the canvas while papers are compared.
struct PaperLibrarySidebar: View {
    @ObservedObject var library: PaperLibraryStore
    var isActive: Bool
    var isApplying: Bool
    var onUse: (PaperLibraryItem) -> Void
    var onAddLayer: (PaperLibraryItem) -> Void
    var onImageReplaced: (PaperLibraryItem, CGImage, CGImage) -> Void

    @State private var expandedFolders: Set<UUID> = []
    @State private var selectedFolderID: UUID?
    @State private var selectedItemID: UUID?
    @State private var form: PaperLibraryForm?
    @State private var deletion: PaperLibraryDeletion?
    @State private var cropItem: PaperLibraryItem?
    @State private var isDragging = false
    @State private var dropFeedback: PaperLibraryDropFeedback?

    private var canEdit: Bool { isActive && !isApplying && !library.isBusy }

    private var rows: [PaperLibraryTreeRow] {
        let folders = Dictionary(grouping: library.folders, by: \.parentID)
        let items = Dictionary(grouping: library.items, by: \.parentID)
        var result: [PaperLibraryTreeRow] = []
        var visited: Set<UUID> = []
        func appendChildren(of parent: UUID?, depth: Int) {
            for folder in folders[parent, default: []] where visited.insert(folder.id).inserted {
                result.append(PaperLibraryTreeRow(folder: folder, depth: depth))
                if expandedFolders.contains(folder.id) { appendChildren(of: folder.id, depth: depth + 1) }
            }
            for item in items[parent, default: []] {
                result.append(PaperLibraryTreeRow(item: item, depth: depth))
            }
        }
        appendChildren(of: nil, depth: 0)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("素材库").font(.callout.weight(.semibold))
                Spacer()
                if library.isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                        .accessibilityLabel(library.isSavingCrop ? "正在保存纸张" : "正在导入纸张")
                }
                Menu {
                    Button("导入图片…") { library.importPanel(into: selectedFolderID) }
                    Button("导入文件夹…") { library.importFolderPanel(into: selectedFolderID) }
                    Divider()
                    if let selectedFolderID {
                        Button("新建同级文件夹…") {
                            openNewFolder(in: library.folders.first(where: { $0.id == selectedFolderID })?.parentID)
                        }
                        Button("新建子文件夹…") { openNewFolder(in: selectedFolderID) }
                    } else {
                        Button("新建根目录文件夹…") { openNewFolder(in: nil) }
                    }
                    Button("新建纯色纸张…") { openNewColor(in: selectedFolderID) }
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("导入纸张或新建文件夹、纯色纸张")
                .accessibilityLabel("添加素材")
                .disabled(!canEdit)
            }

            breadcrumb

            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("添加你的第一张纸张").font(.callout)
                    Text("点击 ＋ 导入图片，或创建纯色纸张。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { row in
                            if let folder = row.folder {
                                folderRow(folder, depth: row.depth, treeRow: row)
                            } else if let item = row.item {
                                itemRow(item, depth: row.depth, treeRow: row)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .projectOverlayScrollbars()
                }
                .frame(height: min(252, max(66, CGFloat(rows.count) * 29 + 4)))
                .scrollIndicators(.automatic)
                Text("悬停预览 · 单击使用")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $form) { form in
            PaperLibraryEditorView(form: form) { name, color, useImmediately in
                save(form, name: name, color: color, useImmediately: useImmediately)
            }
        }
        .sheet(item: $cropItem) { item in
            PaperCropEditorView(library: library, item: item) { savedItem, image, preview, asNew in
                expandAndSelect(savedItem.parentID)
                selectedItemID = savedItem.id
                if !asNew { onImageReplaced(savedItem, image, preview) }
            }
        }
        .alert("删除素材", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("取消", role: .cancel) { deletion = nil }
            Button("删除", role: .destructive) { deletePending() }
        } message: {
            if let deletion {
                Text(deletion.isFolder
                     ? "删除“\(deletion.name)”及其中的文件夹和纸张？已放入画布的纸张不受影响。"
                     : "从素材库删除“\(deletion.name)”？已放入画布的纸张不受影响。")
            }
        }
        .alert("素材库", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("确定") { library.message = nil }
        } message: { Text(library.message ?? "") }
        .onChange(of: library.folders.map(\.id)) { _, ids in
            let valid = Set(ids)
            expandedFolders.formIntersection(valid)
            if let selectedFolderID, !valid.contains(selectedFolderID) { self.selectedFolderID = nil }
        }
        .onChange(of: library.items.map(\.id)) { _, ids in
            if let selectedItemID, !ids.contains(selectedItemID) { self.selectedItemID = nil }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                form = nil
                deletion = nil
                isDragging = false
                dropFeedback = nil
            }
        }
    }

    private var breadcrumbFolders: [PaperLibraryFolder] {
        var path: [PaperLibraryFolder] = []
        var current = selectedFolderID
        var visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted,
              let folder = library.folders.first(where: { $0.id == id }) {
            path.append(folder)
            current = folder.parentID
        }
        return path.reversed()
    }

    private var breadcrumb: some View {
        HStack(spacing: 3) {
            dragRow(target: .root) {
                Button {
                    selectedFolderID = nil
                    selectedItemID = nil
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "house")
                        Text("素材库")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("素材库根目录，可将文件夹拖到这里移出当前层级")
                .accessibilityLabel("素材库根目录")
                .background(dropFeedback == .root ? Color.accentColor.opacity(0.13) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 70, height: 20)

            ForEach(breadcrumbFolders) { folder in
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                dragRow(target: .breadcrumbFolder(folder.id)) {
                    Button {
                        selectedFolderID = folder.id
                        selectedItemID = nil
                    } label: {
                        Text(folder.name).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("移至“\(folder.name)”；拖动到这里可将素材或文件夹放入此层级")
                    .background(dropFeedback == .insideFolder(folder.id)
                                ? Color.accentColor.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: 20)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dragRow<Content: View>(target: PaperLibraryDropDestination.Target,
                                       node: PaperLibraryDragNode? = nil,
                                       onClick: ((CGPoint) -> Void)? = nil,
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        PaperLibraryDragRow(library: library, target: target, node: node,
                            isEnabled: canEdit && form == nil && deletion == nil && cropItem == nil,
                            onClick: onClick,
                            onDragState: { isDragging = $0 },
                            onFeedback: { feedback in
            if dropFeedback != feedback {
                withAnimation(.easeOut(duration: 0.12)) { dropFeedback = feedback }
            }
        }, onMove: { destination in
            expandAndSelect(destination)
            selectedItemID = nil
        }, content: content)
    }

    private func insertionMarkerDepth(before row: PaperLibraryTreeRow) -> Int? {
        switch dropFeedback {
        case .beforeFolder(let id) where row.folder?.id == id: return row.depth
        case .beforeItem(let id) where row.item?.id == id: return row.depth
        default: return nil
        }
    }

    private func insertionMarkerDepth(after row: PaperLibraryTreeRow) -> Int? {
        switch dropFeedback {
        case .afterFolder(let id):
            guard let index = rows.firstIndex(where: { $0.folder?.id == id }) else { return nil }
            let lastIndex = rows[(index + 1)...].firstIndex(where: { $0.depth <= rows[index].depth })
                .map { $0 - 1 } ?? rows.count - 1
            return rows.indices.contains(lastIndex) && rows[lastIndex].id == row.id ? rows[index].depth : nil
        case .afterItem(let id) where row.item?.id == id:
            return row.depth
        default:
            return nil
        }
    }

    private func insertionMarker(depth: Int) -> some View {
        Capsule().fill(Color.accentColor)
            .frame(width: 2, height: 22)
            .padding(.leading, indentation(depth) + 8)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
    }

    private func insertionFeedback(for row: PaperLibraryTreeRow) -> some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                if let depth = insertionMarkerDepth(before: row) {
                    insertionMarker(depth: depth).offset(y: -11)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let depth = insertionMarkerDepth(after: row) {
                    insertionMarker(depth: depth).offset(y: 11)
                }
            }
            .allowsHitTesting(false)
    }

    private func folderRow(_ folder: PaperLibraryFolder, depth: Int,
                           treeRow: PaperLibraryTreeRow) -> some View {
        dragRow(target: .folder(folder.id), node: .folder(folder.id), onClick: { point in
            if point.x >= indentation(depth) + 18 {
                selectedFolderID = folder.id
                selectedItemID = nil
            }
            toggleFolder(folder.id)
        }) {
            HStack(spacing: 4) {
                Button { toggleFolder(folder.id) } label: {
                    Image(systemName: expandedFolders.contains(folder.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expandedFolders.contains(folder.id) ? "收起" : "展开") \(folder.name)")
                Button {
                    selectedFolderID = folder.id
                    selectedItemID = nil
                    toggleFolder(folder.id)
                } label: {
                    Text(folder.name).lineLimit(1).truncationMode(.middle)
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, indentation(depth))
            .padding(.trailing, 6)
            .background(selectedFolderID == folder.id && selectedItemID == nil
                        ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if dropFeedback == .insideFolder(folder.id) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
                        .allowsHitTesting(false)
                }
            }
            .contextMenu {
                Button("导入图片…") { expandAndSelect(folder.id); library.importPanel(into: folder.id) }
                Button("新建子文件夹…") { openNewFolder(in: folder.id) }
                Button("新建同级文件夹…") { openNewFolder(in: folder.parentID) }
                Button("新建纯色纸张…") { openNewColor(in: folder.id) }
                Divider()
                Button("重命名…") { form = .rename(folder) }
                moveMenu(folderID: folder.id, itemID: nil)
                Button("删除文件夹…", role: .destructive) {
                    deletion = PaperLibraryDeletion(id: folder.id, name: folder.name, isFolder: true)
                }
            }
            .disabled(!canEdit)
        }
        .frame(height: 28)
        .overlay { insertionFeedback(for: treeRow) }
        .animation(.easeOut(duration: 0.12), value: dropFeedback)
    }

    private func itemRow(_ item: PaperLibraryItem, depth: Int,
                         treeRow: PaperLibraryTreeRow) -> some View {
        dragRow(target: .item(item.id), node: .item(item.id), onClick: { _ in use(item) }) {
            PaperLibraryItemRow(item: item, url: library.url(for: item),
                                selected: selectedItemID == item.id,
                                enabled: canEdit && form == nil && deletion == nil && cropItem == nil,
                                isDragging: isDragging) { use(item) }
            .padding(.leading, indentation(depth) + 22)
            .contextMenu {
                Button("添加新背景图层") { onAddLayer(item) }
                if item.color == nil {
                    Button("裁剪…") { cropItem = item }
                }
                Divider()
                Button("重命名…") { form = .rename(item) }
                if item.color != nil {
                    Button("编辑颜色…") { form = .edit(item) }
                }
                moveMenu(folderID: nil, itemID: item.id)
                Button("从素材库删除…", role: .destructive) {
                    deletion = PaperLibraryDeletion(id: item.id, name: item.displayName, isFolder: false)
                }
            }
            .disabled(!canEdit)
        }
        .frame(height: 28)
        .overlay { insertionFeedback(for: treeRow) }
        .animation(.easeOut(duration: 0.12), value: dropFeedback)
    }

    private func use(_ item: PaperLibraryItem) {
        selectedItemID = item.id
        selectedFolderID = item.parentID
        onUse(item)
    }

    private func moveMenu(folderID: UUID?, itemID: UUID?) -> some View {
        Menu("移至") {
            Button("素材库根目录") { move(folderID: folderID, itemID: itemID, to: nil) }
            ForEach(library.folders.filter { candidate in
                guard let folderID else { return true }
                return candidate.id != folderID && !isDescendant(candidate.id, of: folderID)
            }) { folder in
                Button(folderPath(folder.id)) { move(folderID: folderID, itemID: itemID, to: folder.id) }
            }
        }
    }

    private func move(folderID: UUID?, itemID: UUID?, to parentID: UUID?) {
        if let folderID { library.moveFolder(id: folderID, to: parentID) }
        if let itemID { library.moveItem(id: itemID, to: parentID) }
        expandAndSelect(parentID)
    }

    private func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        var current: UUID? = id
        var visited: Set<UUID> = []
        while let candidate = current, visited.insert(candidate).inserted {
            if candidate == ancestor { return true }
            current = library.folders.first { $0.id == candidate }?.parentID
        }
        return false
    }

    private func folderPath(_ id: UUID) -> String {
        var names: [String] = []
        var current: UUID? = id
        var visited: Set<UUID> = []
        while let candidate = current, visited.insert(candidate).inserted,
              let folder = library.folders.first(where: { $0.id == candidate }) {
            names.append(folder.name)
            current = folder.parentID
        }
        return names.reversed().joined(separator: " / ")
    }

    private func indentation(_ depth: Int) -> CGFloat { CGFloat(min(depth, 8)) * 12 }

    private func toggleFolder(_ id: UUID) {
        if !expandedFolders.insert(id).inserted { expandedFolders.remove(id) }
    }

    private func expandAndSelect(_ id: UUID?) {
        selectedFolderID = id
        var current = id
        var visited: Set<UUID> = []
        while let candidate = current, visited.insert(candidate).inserted {
            expandedFolders.insert(candidate)
            current = library.folders.first { $0.id == candidate }?.parentID
        }
    }

    private func openNewFolder(in parentID: UUID?) {
        expandAndSelect(parentID)
        form = .newFolder(parentID: parentID)
    }

    private func openNewColor(in parentID: UUID?) {
        expandAndSelect(parentID)
        form = .newColor(parentID: parentID)
    }

    private func save(_ form: PaperLibraryForm, name: String, color: NSColor, useImmediately: Bool) -> String? {
        library.message = nil
        var saved = false
        var itemToUse: PaperLibraryItem?
        switch form.kind {
        case .newFolder:
            if library.createFolder(named: name, parentID: form.parentID) != nil {
                expandAndSelect(form.parentID)
                saved = true
            }
        case .newColor:
            if let item = library.createColor(named: name, color: color, parentID: form.parentID) {
                selectedItemID = item.id
                itemToUse = item
                saved = true
            }
        case .renameFolder:
            if let id = form.targetID { saved = library.renameFolder(id: id, to: name) }
        case .renameItem:
            if let id = form.targetID { saved = library.renameItem(id: id, to: name) }
        case .editColor:
            if let id = form.targetID, let item = library.updateColorPaper(id: id, name: name, color: color) {
                itemToUse = item
                saved = true
            }
        }
        guard saved else {
            let error = library.message ?? "未能保存，请重试。"
            library.message = nil
            return error
        }
        self.form = nil
        if useImmediately, let itemToUse { onUse(itemToUse) }
        return nil
    }

    private func deletePending() {
        guard let deletion else { return }
        if deletion.isFolder { library.removeFolder(id: deletion.id) }
        else { library.removeItem(id: deletion.id) }
        self.deletion = nil
    }
}

private struct PaperLibraryTreeRow: Identifiable {
    let id: UUID
    let folder: PaperLibraryFolder?
    let item: PaperLibraryItem?
    let depth: Int
    init(folder: PaperLibraryFolder, depth: Int) {
        id = folder.id; self.folder = folder; item = nil; self.depth = depth
    }
    init(item: PaperLibraryItem, depth: Int) {
        id = item.id; folder = nil; self.item = item; self.depth = depth
    }
}

private struct PaperLibraryDeletion {
    let id: UUID
    let name: String
    let isFolder: Bool
}

private struct PaperLibraryForm: Identifiable {
    enum Kind { case newFolder, newColor, renameFolder, renameItem, editColor }
    let id = UUID()
    let kind: Kind
    let title: String
    var parentID: UUID?
    var targetID: UUID?
    var name = ""
    var color = NSColor.white
    var hasColor: Bool { kind == .newColor || kind == .editColor }

    static func newFolder(parentID: UUID?) -> Self { Self(kind: .newFolder, title: "新建文件夹", parentID: parentID) }
    static func newColor(parentID: UUID?) -> Self { Self(kind: .newColor, title: "新建纯色纸张", parentID: parentID) }
    static func rename(_ folder: PaperLibraryFolder) -> Self {
        Self(kind: .renameFolder, title: "重命名文件夹", targetID: folder.id, name: folder.name)
    }
    static func rename(_ item: PaperLibraryItem) -> Self {
        Self(kind: .renameItem, title: "重命名纸张", targetID: item.id, name: item.displayName)
    }
    static func edit(_ item: PaperLibraryItem) -> Self {
        Self(kind: .editColor, title: "编辑纯色纸张", targetID: item.id, name: item.displayName,
             color: item.color?.nsColor ?? .white)
    }
}

private struct PaperLibraryEditorView: View {
    let form: PaperLibraryForm
    let onSave: (String, NSColor, Bool) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: Color
    @State private var hex: String
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool

    init(form: PaperLibraryForm, onSave: @escaping (String, NSColor, Bool) -> String?) {
        self.form = form; self.onSave = onSave
        _name = State(initialValue: form.name)
        _color = State(initialValue: Color(nsColor: form.color))
        _hex = State(initialValue: Self.hex(form.color))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmedName.isEmpty && (!form.hasColor || Self.parseHex(hex) != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(form.title).font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                .onSubmit { if valid { save(use: false) } }
            if form.hasColor {
                RoundedRectangle(cornerRadius: 8).fill(color)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                    .frame(height: 100)
                HStack(spacing: 12) {
                    ColorPicker("颜色", selection: $color, supportsOpacity: false)
                    TextField("#FFFFFF", text: $hex)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder).frame(width: 96)
                        .accessibilityLabel("十六进制颜色")
                }
                .onChange(of: color) { _, value in
                    let value = Self.hex(NSColor(value))
                    if hex.uppercased() != value { hex = value }
                }
                .onChange(of: hex) { _, value in
                    if let parsed = Self.parseHex(value), Self.hex(NSColor(color)) != Self.hex(parsed) {
                        color = Color(nsColor: parsed)
                    }
                }
                if Self.parseHex(hex) == nil {
                    Text("请输入六位颜色值，例如 #F2EBDD。")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save(use: false) }.disabled(!valid)
                    .keyboardShortcut(.defaultAction)
                if form.hasColor {
                    Button("保存并使用") { save(use: true) }
                        .buttonStyle(.borderedProminent).disabled(!valid)
                }
            }
        }
        .padding(20).frame(width: 340)
        .onAppear { nameFocused = true }
    }

    private func save(use: Bool) {
        saveError = onSave(trimmedName, Self.parseHex(hex) ?? NSColor(color), use)
    }

    private static func hex(_ value: NSColor) -> String {
        let rgb = value.usingColorSpace(.deviceRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    private static func parseHex(_ value: String) -> NSColor? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return NSColor(deviceRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

private struct PaperLibraryItemRow: View {
    let item: PaperLibraryItem
    let url: URL
    let selected: Bool
    let enabled: Bool
    let isDragging: Bool
    let onUse: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            hovering = false
            onUse()
        } label: {
            Text(item.displayName).font(.callout)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.13) : (hovering ? Color.primary.opacity(0.04) : .clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .background {
            PaperLibraryHoverAnchor(item: item, url: url, show: hovering && enabled && !isDragging)
                .allowsHitTesting(false)
        }
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .accessibilityHint("单击使用此背景，右键可重命名、移动或删除")
        .disabled(!enabled)
    }
}

private struct PaperLibraryHoverAnchor: NSViewRepresentable {
    let item: PaperLibraryItem
    let url: URL
    let show: Bool

    func makeNSView(context: Context) -> PaperLibraryHoverView { PaperLibraryHoverView() }
    func updateNSView(_ view: PaperLibraryHoverView, context: Context) {
        view.update(item: item, url: url, show: show)
    }
    static func dismantleNSView(_ view: PaperLibraryHoverView, coordinator: ()) { view.hidePreview() }
}

private final class PaperLibraryPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PaperLibraryHoverView: NSView {
    private var request: Task<Void, Never>?
    private var panel: PaperLibraryPreviewPanel?
    private var shownItem: PaperLibraryItem?
    private var shouldShow = false
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(item: PaperLibraryItem, url: URL, show: Bool) {
        guard show else { hidePreview(); return }
        guard !shouldShow || shownItem != item else { return }
        hidePreview()
        shouldShow = true
        shownItem = item
        request = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.shouldShow else { return }
            var image: NSImage?
            if item.color == nil {
                image = Self.cache.object(forKey: url as NSURL)
                if image == nil {
                    let pixels = await Task.detached(priority: .userInitiated) { Self.thumbnail(at: url) }.value
                    guard !Task.isCancelled, self.shouldShow, self.shownItem == item else { return }
                    if let pixels {
                        let decoded = NSImage(cgImage: pixels, size: CGSize(width: pixels.width, height: pixels.height))
                        Self.cache.setObject(decoded, forKey: url as NSURL, cost: pixels.bytesPerRow * pixels.height)
                        image = decoded
                    }
                }
            }
            guard !Task.isCancelled, self.shouldShow, self.shownItem == item else { return }
            self.present(item: item, image: image)
        }
    }

    func hidePreview() {
        NotificationCenter.default.removeObserver(self)
        shouldShow = false
        shownItem = nil
        request?.cancel()
        request = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hidePreview() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func present(item: PaperLibraryItem, image: NSImage?) {
        guard let window, window.isKeyWindow, !visibleRect.isEmpty else { return }
        let size = CGSize(width: 280, height: 320)
        let panel = PaperLibraryPreviewPanel(contentRect: CGRect(origin: .zero, size: size),
                                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PaperLibraryHoverPreview(item: item, image: image))
        panel.appearance = window.effectiveAppearance
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(screen.minX + 8, anchor.maxX + 10), screen.maxX - size.width - 8)
        let y = min(max(screen.minY + 8, anchor.midY - size.height / 2), screen.maxY - size.height - 8)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
        NotificationCenter.default.addObserver(self, selector: #selector(dismissPreview),
                                               name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(dismissPreview),
                                               name: NSWindow.didResizeNotification, object: window)
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(dismissPreview),
                                                       name: NSView.boundsDidChangeNotification, object: clip)
            }
            ancestor = view.superview
        }
    }

    @objc private func dismissPreview(_ notification: Notification) { hidePreview() }

    nonisolated private static func thumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 560,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

private struct PaperLibraryHoverPreview: View {
    let item: PaperLibraryItem
    let image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor))
                if let color = item.color {
                    Rectangle().fill(Color(nsColor: color.nsColor)).padding(1)
                } else if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Label("无法预览此图片", systemImage: "photo")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(item.displayName).font(.callout.weight(.medium)).lineLimit(2)
            Text(item.color == nil ? "单击使用此背景" : "纯色纸张 · 单击使用")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280, height: 320)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5))
    }
}
