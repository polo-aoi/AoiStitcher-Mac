import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The built-in border choices intentionally live in the border workspace.
/// They are not part of the user-managed paper or watermark libraries.
enum AoiBorderPreset: String, CaseIterable, Identifiable {
    case clean = "留白"
    case film = "胶片"
    case instant = "拍立得"
    case editorial = "杂志"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .clean: return "rectangle"
        case .film: return "film"
        case .instant: return "camera.filters"
        case .editorial: return "text.rectangle"
        }
    }

    var detail: String {
        switch self {
        case .clean: return "简洁留白"
        case .film: return "复古胶片"
        case .instant: return "即时成像"
        case .editorial: return "编辑版式"
        }
    }
}

/// The copy action is kept outside the view so the production view and a
/// regression test use exactly the same pasteboard behavior.
enum AoiBorderContact {
    static let userDefaultsKey = "aoipic.contact.email"

    @discardableResult
    static func copyEmail(_ email: String, to pasteboard: NSPasteboard = .general) -> Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }
}

private struct AoiBorderPhoto: Identifiable, Equatable {
    let id: URL
    let name: String
    let image: NSImage

    init?(url: URL) {
        guard let image = NSImage(contentsOf: url) else { return nil }
        self.id = url
        self.name = url.lastPathComponent
        self.image = image
    }
}

/// Independent batch border/watermark workspace. The image processing hook is
/// deliberately small so the shared renderer can be connected without making
/// this view own the canvas model.
struct BorderWorkspaceView: View {
    var isActive: Bool = true
    var contactEmail: String?
    var onExport: (([URL], AoiBorderPreset) -> Void)?

    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme
    @AppStorage(AoiBorderContact.userDefaultsKey) private var storedContactEmail = ""
    @State private var photos: [AoiBorderPhoto] = []
    @State private var selectedPreset: AoiBorderPreset = .clean
    @State private var showingContactSheet = false
    @State private var showingCopiedFeedback = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var resolvedContactEmail: String {
        let supplied = contactEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return supplied.isEmpty ? storedContactEmail.trimmingCharacters(in: .whitespacesAndNewlines) : supplied
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: EditorStyle.sidebarWidth)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()
            workspace
        }
        .preferredColorScheme(theme == 2 ? .dark : .light)
        .sheet(isPresented: $showingContactSheet) {
            AoiBorderSuggestionSheet(email: resolvedContactEmail) {
                copyEmailAndShowFeedback()
            }
        }
        .alert("aoipic", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if showingCopiedFeedback {
                Text("Email 已复制")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityLabel("Email 已复制")
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            EditorSidebarHeader(theme: $theme) {
                Button { importPhotos() } label: {
                    Label(isImporting ? "正在添加…" : "添加照片", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isActive || isImporting)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EditorSection("边框样式") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(AoiBorderPreset.allCases) { preset in
                                Button { selectedPreset = preset } label: {
                                    VStack(spacing: 7) {
                                        Image(systemName: preset.icon).font(.title3)
                                            .frame(height: 28)
                                        Text(preset.rawValue).font(.caption.weight(.medium))
                                        Text(preset.detail).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity).frame(height: 78)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(AoiBorderPresetButtonStyle(selected: selectedPreset == preset))
                                .accessibilityLabel("边框：\(preset.rawValue)")
                            }
                            Button { showingContactSheet = true } label: {
                                VStack(spacing: 7) {
                                    Image(systemName: "ellipsis.bubble").font(.title3)
                                        .frame(height: 28)
                                    Text("提交效果").font(.caption.weight(.medium))
                                    Text("点餐").font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity).frame(height: 78)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(AoiBorderPresetButtonStyle(selected: false))
                            .accessibilityLabel("提交喜欢的边框或效果")
                        }
                    }
                    Divider()
                    EditorSection("素材") {
                        if photos.isEmpty {
                            Text("照片会显示在这里。")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(photos) { photo in
                                HStack(spacing: 8) {
                                    Image(nsImage: photo.image)
                                        .resizable().scaledToFill()
                                        .frame(width: 30, height: 30)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text(photo.name)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button { remove(photo) } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("移除照片")
                                    .accessibilityLabel("移除 \(photo.name)")
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .padding(EditorStyle.padding)
            }
            Divider()
            EditorActionBar(isExporting: false,
                            disabled: photos.isEmpty,
                            clearTitle: "清空列表",
                            clear: { photos.removeAll() },
                            export: {
                                if let onExport {
                                    onExport(photos.map(\.id), selectedPreset)
                                } else {
                                    errorMessage = "边框样式和素材列表已准备好，批量边框渲染将在后续模块接入。"
                                }
                            },
                            settings: { })
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            EditorToolbar {
                Text("\(photos.count) 张照片")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(selectedPreset.rawValue)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            ZStack {
                Color(NSColor.controlBackgroundColor)
                if photos.isEmpty {
                    EditorEmptyState()
                } else {
                    List(photos) { photo in
                        HStack(spacing: 10) {
                            Image(nsImage: photo.image)
                                .resizable().scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            Text(photo.name)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("待处理")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
        }
    }

    private func importPhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        appendPhotos(panel.urls)
    }

    private func appendPhotos(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        let newPhotos = urls.compactMap { url in
            AoiBorderPhoto(url: url)
        }
        let existing = Set(photos.map(\.id))
        photos.append(contentsOf: newPhotos.filter { !existing.contains($0.id) })
        isImporting = false
        if newPhotos.count < urls.count {
            errorMessage = "有 \(urls.count - newPhotos.count) 个文件无法读取。请使用 PNG、JPEG、HEIC 或 TIFF 图片。"
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { appendPhotos([url]) }
            }
        }
        return true
    }

    private func remove(_ photo: AoiBorderPhoto) {
        photos.removeAll { $0.id == photo.id }
    }

    private func copyEmailAndShowFeedback() {
        guard AoiBorderContact.copyEmail(resolvedContactEmail) else {
            errorMessage = "联系邮箱尚未配置。请在设置中填写开发者邮箱。"
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { showingCopiedFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.18)) { showingCopiedFeedback = false }
        }
    }
}

private struct AoiBorderPresetButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: selected ? 1.4 : 0.8)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Standalone sheet so the parent workspace can reuse the same submit action.
struct AoiBorderSuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let email: String
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "ellipsis.bubble.fill")
                    .foregroundStyle(Color.accentColor)
                Text("提交效果建议").font(.title3.weight(.semibold))
                Spacer()
            }
            Text("如果你喜欢某种调色、边框或效果，欢迎告诉开发者。点击确定后会自动复制联系邮箱。")
                .fixedSize(horizontal: false, vertical: true)
            if email.isEmpty {
                Text("联系邮箱尚未配置")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text(email).textSelection(.enabled)
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("确定") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 410)
    }
}
