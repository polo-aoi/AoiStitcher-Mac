import AppKit
import SwiftUI

struct PaperCropEditorView: View {
    @ObservedObject var library: PaperLibraryStore
    let item: PaperLibraryItem
    let onSaved: (PaperLibraryItem, CGImage, CGImage, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("colorSchemeStyle") private var theme = 1
    @State private var store: CropStore?
    @State private var loadingError: String?
    @State private var retryID = UUID()
    @State private var isSaving = false

    var body: some View {
        Group {
            if let store {
                PaperCropWorkspace(library: library, item: item, store: store, isSaving: $isSaving) { saved, full, preview, asNew in
                    onSaved(saved, full, preview, asNew)
                    dismiss()
                }
            } else {
                VStack(spacing: 0) {
                    EditorToolbar {
                        Text("裁剪纸张").font(.headline)
                        Text(item.displayName).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    Divider()
                    VStack(spacing: 14) {
                        if let loadingError {
                            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                            Text(loadingError).multilineTextAlignment(.center)
                                .foregroundStyle(.secondary).frame(maxWidth: 380)
                            Button("重试") { retryID = UUID() }
                        } else {
                            ProgressView()
                            Text("正在读取纸张…").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 940, height: 650)
        .background(Color(NSColor.windowBackgroundColor))
        .preferredColorScheme(theme == 2 ? .dark : .light)
        .interactiveDismissDisabled(isSaving)
        .task(id: retryID) { await loadImage() }
    }

    private func loadImage() async {
        guard store == nil else { return }
        loadingError = nil
        let url = library.url(for: item)
        let loaded = await Task.detached(priority: .userInitiated) { CanvasImageLoader.load(url) }.value
        guard !Task.isCancelled else { return }
        guard let loaded else {
            loadingError = "无法读取这张纸张。文件可能已移动、损坏，或尺寸过大。"
            return
        }
        let image = NSImage(cgImage: loaded.image, size: CGSize(width: loaded.image.width, height: loaded.image.height))
        store = CropStore(item: StitchItem(url: url, image: image), initialPreset: .free)
    }
}

private struct PaperCropWorkspace: View {
    @ObservedObject var library: PaperLibraryStore
    let item: PaperLibraryItem
    @ObservedObject var store: CropStore
    @Binding var isSaving: Bool
    let onSaved: (PaperLibraryItem, CGImage, CGImage, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choosingSaveMode = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar {
                Text("裁剪纸张").font(.headline)
                Text(item.displayName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(store.undoCount == 0).help("撤销（⌘Z）").accessibilityLabel("撤销")
                Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(store.redoCount == 0).help("重做（⇧⌘Z）").accessibilityLabel("重做")
                Divider().frame(height: 18)
                Button("取消") { if !isSaving { dismiss() } }.keyboardShortcut(.cancelAction)
                Button {
                    store.endChange()
                    choosingSaveMode = true
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text(isSaving ? "正在保存…" : "完成裁剪")
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(library.isBusy)
            }
            .disabled(isSaving)
            Divider()
            cropControls.disabled(isSaving)
            Divider()
            CropCanvas(store: store).disabled(isSaving)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("拖动边缘或角点调整裁剪范围")
                    Spacer()
                    Text("\(Int(store.outputSize.width)) × \(Int(store.outputSize.height)) px")
                        .monospacedDigit()
                }.foregroundStyle(.secondary)
            }
            .font(.caption).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .confirmationDialog("保存裁剪后的纸张", isPresented: $choosingSaveMode, titleVisibility: .visible) {
            Button("保存并替换") { save(asNew: false) }
            Button("另存为新纸张") { save(asNew: true) }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("保存并替换会永久裁掉框外像素，并同步当前画布中使用此纸张的背景。另存为新纸张会保留原纸张。")
        }
    }

    private var cropControls: some View {
        HStack(spacing: 14) {
            Label("比例", systemImage: "aspectratio")
            Picker("裁剪比例", selection: Binding(get: { store.state.preset }, set: { store.applyPreset($0) })) {
                ForEach(CropRatioPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
            }
            .labelsHidden().frame(width: 100)
            Button { store.swapAspect() } label: { Image(systemName: "arrow.left.arrow.right") }
                .help("交换裁剪框横竖比例").accessibilityLabel("交换裁剪框横竖比例")
            Divider().frame(height: 18)
            Button { store.rotateQuarter() } label: { Image(systemName: "rotate.right") }
                .help("顺时针旋转 90°").accessibilityLabel("顺时针旋转 90 度")
            Toggle("三分网格", isOn: $store.showGrid).toggleStyle(.checkbox)
            Spacer()
            Text("\(Int(store.displayedZoom * 100))%").monospacedDigit().frame(width: 48)
            Button { store.fitRequest += 1 } label: { Image(systemName: "viewfinder") }
                .help("适合窗口").accessibilityLabel("适合窗口")
            Button { store.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("重置裁剪").accessibilityLabel("重置裁剪")
        }
        .font(.callout).buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func save(asNew: Bool) {
        guard !isSaving, !library.isBusy else { return }
        store.endChange()
        guard let snapshot = CropRenderSnapshot(store) else {
            saveError = "无法读取裁剪图像，请关闭后重新打开这张纸张。"
            return
        }
        saveError = nil
        isSaving = true
        store.isSaving = true
        Task {
            do {
                let (full, preview) = try await Task.detached(priority: .userInitiated) {
                    let full = try CropRenderer.makeImage(snapshot, background: nil)
                    return (full, CanvasImageLoader.thumbnail(full))
                }.value
                let saved = try await library.saveCroppedImage(full, for: item, asNew: asNew)
                store.isSaving = false
                isSaving = false
                onSaved(saved, full, preview, asNew)
            } catch {
                store.isSaving = false
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}
