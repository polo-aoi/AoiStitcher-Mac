import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct CanvasCropSession: Identifiable {
    var id: UUID
    var item: StitchItem
}

struct FreeCanvasView: View {
    @ObservedObject var store: CanvasStore
    var isActive: Bool
    @EnvironmentObject private var projectLibrary: ProjectLibraryStore
    @EnvironmentObject private var projectBridge: ProjectEditorBridge
    @AppStorage("colorSchemeStyle") private var theme = 1
    @AppStorage("exportWidth") private var exportWidth = AppPreferences.defaultExportWidth
    @AppStorage("exportPNG") private var exportPNG = AppPreferences.defaultExportPNG
    @AppStorage("lastExportDir") private var lastExportDir = ""
    @AppStorage(AppPreferences.canvasWheelBehaviorKey) private var wheelBehavior: CanvasScrollBehavior = .zoom
    @AppStorage(AppPreferences.canvasGestureBehaviorKey) private var gestureBehavior: CanvasScrollBehavior = .pan
    @AppStorage(AppPreferences.canvasZoomSensitivityKey) private var zoomSensitivity = 1.0
    @AppStorage(AppPreferences.canvasReverseZoomKey) private var reverseZoom = false
    @AppStorage(AppPreferences.canvasPanModeKey) private var panMode: DragPanMode = .rightMouse
    @AppStorage(AppPreferences.canvasPanKeyKey) private var panKey: LongStitchPanKey = .space
    @State private var layoutMargin: CGFloat = 40
    @State private var layoutGap: CGFloat = 24
    @State private var layoutSplit: CGFloat = 0.5
    @State private var showingExportSettings = false
    @State private var exportedFile: String?
    @State private var showingMissingBackgroundAlert = false
    @State private var cropSession: CanvasCropSession?
    @State private var inspectedID: UUID?
    @State private var showingPaperLibrary = false
    @StateObject private var paperLibrary = PaperLibraryStore()
    private let swatches: [NSColor] = [
        .white, NSColor(deviceWhite: 0.92, alpha: 1),
        NSColor(deviceRed: 0.95, green: 0.91, blue: 0.82, alpha: 1),
        NSColor(deviceRed: 0.55, green: 0.12, blue: 0.14, alpha: 1),
        NSColor(deviceRed: 0.19, green: 0.28, blue: 0.23, alpha: 1),
        NSColor(deviceWhite: 0.08, alpha: 1)
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: EditorStyle.sidebarWidth)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                workspaceToolbar
                Divider()
                ZStack {
                    CanvasWorkspace(store: store, isActive: isActive, settings: interactionSettings,
                                    onCrop: startCrop, onInspect: openInspector)
                    if store.document.layers.isEmpty {
                        EditorEmptyState()
                    }
                    if store.isLoading {
                        VStack {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取照片…") }
                                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            Spacer()
                        }.padding(16).allowsHitTesting(false)
                    }
                }.clipped()
                Text(interactionSettings.hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
        .preferredColorScheme(theme == 2 ? .dark : .light)
        .onReceive(projectBridge.$request) { request in
            guard request?.operation == .freeCanvas else { return }
            DispatchQueue.main.async { receiveProjectImages() }
        }
        .onAppear { projectBridge.observeCanvas(store) }
        .onChange(of: store.isLoading) { _, loading in
            if !loading { receiveProjectImages() }
        }
        .onChange(of: store.isExporting) { _, exporting in
            if !exporting { receiveProjectImages() }
        }
        .onChange(of: store.selectedID) { _, id in
            if id != inspectedID { inspectedID = nil }
        }
        .onChange(of: store.document.layers.map(\.id)) { _, ids in
            if let inspectedID, !ids.contains(inspectedID) { self.inspectedID = nil }
        }
        .onChange(of: isActive) { _, active in if !active { inspectedID = nil } }
        .sheet(item: $cropSession) { session in
            CropEditorView(item: session.item) { updated in
                store.updateCrop(updated, layerID: session.id); cropSession = nil
            } onCancel: { cropSession = nil }
        }
        .sheet(isPresented: $showingPaperLibrary) {
            PaperLibraryView(library: paperLibrary) { url in
                store.importURLs([url], as: .paper)
            }
        }
        .alert("aoipic", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("确定") { store.message = nil }
        } message: { Text(store.message ?? "") }
        .alert("导出成功", isPresented: Binding(get: { exportedFile != nil }, set: { if !$0 { exportedFile = nil } })) {
            Button("保留画布", role: .cancel) { exportedFile = nil }
            Button("清空画布", role: .destructive) { clearCanvas(); exportedFile = nil }
        } message: { Text("图片已保存：\(exportedFile ?? "")") }
        .alert("当前没有背景", isPresented: $showingMissingBackgroundAlert) {
            Button("返回添加背景", role: .cancel) {}
            Button("继续导出", role: .destructive) { performExport() }
        } message: {
            Text("当前画布只有照片，没有纯色背景或底图。仍要导出吗？")
        }
    }

    private var interactionSettings: CanvasInteractionSettings {
        CanvasInteractionSettings(wheelBehavior: wheelBehavior, gestureBehavior: gestureBehavior,
                                  zoomSensitivity: zoomSensitivity, reverseZoom: reverseZoom,
                                  panMode: panMode, panKey: panKey)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            EditorSidebarHeader(theme: $theme) {
                    Button { store.importImages() } label: {
                        Label("添加照片", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(store.isLoading)
                    Menu {
                        ForEach(CanvasPaperStyle.allCases) { style in
                            Button(style.rawValue) { store.addPaper(style) }
                        }
                        Divider()
                        Button("导入底图…") { store.importImages(as: .paper) }
                        Button("打开纸张库…") { showingPaperLibrary = true }
                    } label: { Label("添加纸张", systemImage: "doc.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(store.isLoading)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    canvasControls
                    Divider()
                    paperLibraryControls
                    Divider()
                    layoutControls
                    Divider()
                    layersControls
                }.padding(16)
            }
            Divider()
            exportControls
        }
    }

    private var paperLibraryControls: some View {
        EditorSection("纸张库") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showingPaperLibrary = true
                } label: {
                    Label("打开纸张库", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                Text("导入、保存、排序纸张；拖入画布后成为底图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var workspaceToolbar: some View {
        EditorToolbar {
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(store.undoCount == 0).help("撤销（⌘Z）").accessibilityLabel("撤销")
            Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(store.redoCount == 0).help("重做（⇧⌘Z）").accessibilityLabel("重做")
            Divider().frame(height: 18)
            Text("\(store.photoCount) 张照片 · \(store.document.layers.count - store.photoCount) 张纸")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { store.fitRequest += 1 } label: { Label("适合窗口", systemImage: "viewfinder") }
                .help("将画布放回窗口中心（Q）")
            Text("\(Int(store.displayedZoom * 100))%").font(.callout.monospacedDigit()).frame(width: 48)
        }
    }

    private var canvasControls: some View {
        EditorSection("画布") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Picker("比例", selection: canvasRatioBinding) {
                        ForEach(CanvasAspectRatio.allCases) { preset in Text(preset.rawValue).tag(preset) }
                    }
                    Button { store.swapCanvasOrientation() } label: {
                        Label("横竖切换", systemImage: "arrow.left.arrow.right").labelStyle(.iconOnly)
                    }
                    .disabled(store.document.size.width == store.document.size.height)
                    .help("横竖切换：互换画布宽高，例如 3:2 与 2:3")
                    .accessibilityLabel("互换画布宽高")
                }
                HStack {
                    CanvasNumberField(title: "宽", value: canvasDimension(width: true))
                    CanvasNumberField(title: "高", value: canvasDimension(width: false))
                }
                ColorPicker("底色", selection: backgroundBinding, supportsOpacity: false)
                colorSwatches { color in store.mutate { $0.background = CanvasColor(color) } }
            }
        }
    }

    private var layoutControls: some View {
        EditorSection("快捷排版") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { arrange(horizontal: true) } label: { Label("左右排", systemImage: "rectangle.split.2x1").frame(maxWidth: .infinity) }
                    Button { arrange(horizontal: false) } label: { Label("上下排", systemImage: "rectangle.split.1x2").frame(maxWidth: .infinity) }
                }.disabled(store.photoCount == 0 || store.photoCount > 2)
                HStack {
                    CanvasNumberField(title: "留白", value: $layoutMargin)
                    CanvasNumberField(title: "间距", value: $layoutGap)
                }
                if store.photoCount == 2 {
                    HStack { Text("两图区域比例").font(.caption); Spacer(); Text("\(Int(layoutSplit * 100)) : \(100 - Int(layoutSplit * 100))").font(.caption.monospacedDigit()) }
                    Slider(value: $layoutSplit, in: 0.15...0.85)
                } else if store.photoCount > 2 {
                    Text("快捷排版适用于一至两张照片；多张照片可直接拖动、缩放和旋转。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectedControls(_ layer: CanvasLayer) -> some View {
        EditorSection(layer.kind == .photo ? "照片参数" : "纸张参数") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(layer.name).lineLimit(1).truncationMode(.middle).font(.callout.weight(.medium))
                    Spacer()
                    Button { store.toggleLock(layer.id) } label: { Image(systemName: layer.locked ? "lock.fill" : "lock.open") }
                        .buttonStyle(.borderless).help(layer.locked ? "解锁素材" : "锁定素材").accessibilityLabel(layer.locked ? "解锁素材" : "锁定素材")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        CanvasNumberField(title: "X", value: layerValue(\.center.x, fallback: layer.center.x))
                        CanvasNumberField(title: "Y", value: layerValue(\.center.y, fallback: layer.center.y))
                    }
                    HStack {
                        CanvasNumberField(title: "宽", value: layerDimension(width: true))
                        CanvasNumberField(title: "高", value: layerDimension(width: false))
                    }
                    HStack {
                        Text("旋转").font(.callout)
                        Spacer()
                        TextField("角度", value: layerValue(\.rotation, fallback: layer.rotation).asDouble,
                                  format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder).frame(width: 74)
                        Text("°").foregroundStyle(.secondary)
                    }
                    Slider(value: layerValue(\.rotation, fallback: layer.rotation), in: -180...180,
                           onEditingChanged: continuousEdit)
                    HStack { Text("不透明度").font(.callout); Spacer(); Text("\(Int(layer.opacity * 100))%").font(.callout.monospacedDigit()) }
                    Slider(value: layerValue(\.opacity, fallback: layer.opacity), in: 0...1, onEditingChanged: continuousEdit)
                    if layer.kind == .paper && layer.image == nil {
                        ColorPicker("纸张颜色", selection: paperColorBinding, supportsOpacity: false)
                        colorSwatches { color in store.editSelected { $0.color = CanvasColor(color) } }
                    }
                    HStack {
                        Button("居中") { store.centerSelected() }
                        Button("适合画布") { store.fitSelected(fill: false) }
                        Button("铺满") { store.fitSelected(fill: true) }
                    }.controlSize(.small)
                    HStack {
                        Button("置于顶层") { store.reorderSelected(toTop: true) }
                        Button("置于底层") { store.reorderSelected(toTop: false) }
                    }.controlSize(.small)
                    if layer.kind == .photo {
                        Button { startCrop(layer) } label: { Label("裁剪与水印…", systemImage: "crop") }
                    }
                    HStack {
                        Button { store.duplicateSelected() } label: { Label("复制", systemImage: "plus.square.on.square") }
                        Spacer()
                        Button(role: .destructive) { store.deleteSelected() } label: { Label("删除", systemImage: "trash") }
                    }
                }.disabled(layer.locked)
                if layer.locked { Text("素材已锁定，解锁后可调整。").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var layersControls: some View {
        EditorSection("素材") {
            VStack(alignment: .leading, spacing: 4) {
                if store.document.layers.isEmpty {
                    Text("照片和纸张会显示在这里。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                if !store.document.layers.isEmpty {
                    CanvasLayersList(store: store, onInspect: openInspector)
                        .frame(height: min(264, CGFloat(store.document.layers.count) * 44 + 4))
                }
            }
        }
        .popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { closeInspector() } }),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
            VStack(spacing: 0) {
                HStack {
                    Text("素材设置").font(.headline)
                    Spacer()
                    Button("完成", action: closeInspector).keyboardShortcut(.cancelAction)
                }.padding(16)
                Divider()
                ScrollView {
                    if let layer = store.selectedLayer, layer.id == inspectedID {
                        selectedControls(layer).padding(16)
                    }
                }
            }
            .frame(width: 320, height: 580)
            .preferredColorScheme(theme == 2 ? .dark : .light)
        }
    }

    private var exportControls: some View {
        EditorActionBar(isExporting: store.isExporting, disabled: store.document.layers.isEmpty || store.isLoading,
                        clear: clearCanvas, export: exportCanvas, settings: { showingExportSettings = true })
            .popover(isPresented: $showingExportSettings) { ExportSettingsView(outputSize: outputDimensions) }
    }

    private var outputDimensions: String {
        guard let width = AppPreferences.exportWidth(exportWidth), let size = try? CanvasRenderer.outputSize(for: CanvasRenderSnapshot(store.document), width: width) else { return "检查导出尺寸" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private func colorSwatches(action: @escaping (NSColor) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(swatches.indices, id: \.self) { index in
                Button { action(swatches[index]) } label: {
                    Circle().fill(Color(swatches[index])).frame(width: 23, height: 23)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                }.buttonStyle(.plain).accessibilityLabel(["白色", "浅灰色", "米色", "深红色", "墨绿色", "黑色"][index])
            }
        }
    }

    private var backgroundBinding: Binding<Color> {
        Binding(get: { Color(store.document.background.nsColor) }, set: { color in store.mutate { $0.background = CanvasColor(NSColor(color)) } })
    }
    private var paperColorBinding: Binding<Color> {
        Binding(get: { Color(store.selectedLayer?.color.nsColor ?? .white) }, set: { color in store.editSelected { $0.color = CanvasColor(NSColor(color)) } })
    }
    private var canvasRatioBinding: Binding<CanvasAspectRatio> {
        Binding(get: { CanvasAspectRatio.matching(store.document.size) }, set: { preset in
            guard let value = preset.value else { return }
            store.resizeCanvas(CGSize(width: store.document.size.width, height: store.document.size.width / value))
        })
    }
    private func canvasDimension(width: Bool) -> Binding<CGFloat> {
        Binding(get: { width ? store.document.size.width : store.document.size.height }, set: { value in
            guard value.isFinite, value >= 200 else { return }
            store.resizeCanvas(CGSize(width: width ? value : store.document.size.width,
                                      height: width ? store.document.size.height : value))
        })
    }
    private func layerValue(_ keyPath: WritableKeyPath<CanvasLayer, CGFloat>, fallback: CGFloat) -> Binding<CGFloat> {
        Binding(get: { store.selectedLayer?[keyPath: keyPath] ?? fallback }, set: { value in
            guard value.isFinite else { return }
            store.editSelected { layer in
                if keyPath == \.opacity { layer.opacity = min(1, max(0, value)) }
                else if keyPath == \.rotation { layer.rotation = ((value + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180 }
                else { layer[keyPath: keyPath] = min(32000, max(-32000, value)) }
            }
        })
    }
    private func layerDimension(width: Bool) -> Binding<CGFloat> {
        Binding(get: { width ? (store.selectedLayer?.size.width ?? 1) : (store.selectedLayer?.size.height ?? 1) }, set: { value in
            guard value.isFinite, value > 0 else { return }
            store.editSelected {
                let old = $0.size, bounded = min(32000, max(12, value))
                if width {
                    $0.size.width = bounded
                    if $0.preservesAspect { $0.size.height = bounded * old.height / old.width }
                } else {
                    $0.size.height = bounded
                    if $0.preservesAspect { $0.size.width = bounded * old.width / old.height }
                }
            }
        })
    }
    private func continuousEdit(_ editing: Bool) {
        if editing { store.beginContinuousChange() } else { store.endContinuousChange() }
    }
    private func arrange(horizontal: Bool) {
        guard store.photoCount <= 2 else { return }
        store.arrange(horizontal: horizontal, margin: layoutMargin, gap: layoutGap, split: layoutSplit)
    }
    private func startCrop(_ layer: CanvasLayer) {
        guard !layer.locked, let item = layer.photo else { return }
        closeInspector()
        cropSession = CanvasCropSession(id: layer.id, item: item)
    }
    private func openInspector(_ layer: CanvasLayer) {
        store.selectedID = layer.id
        inspectedID = layer.id
    }
    private func closeInspector() {
        store.endContinuousChange()
        inspectedID = nil
    }
    private func exportCanvas() {
        let snapshot = CanvasRenderSnapshot(store.document)
        if store.shouldWarnMissingBackground {
            showingMissingBackgroundAlert = true
            return
        }
        performExport(snapshot: snapshot)
    }

    private func performExport(snapshot suppliedSnapshot: CanvasRenderSnapshot? = nil) {
        guard !store.isLoading, !store.isExporting else { return }
        let snapshot = suppliedSnapshot ?? CanvasRenderSnapshot(store.document)
        let signature = ProjectCompositionSignature.canvas(snapshot)
        guard let width = AppPreferences.exportWidth(exportWidth) else {
            store.message = "导出宽度需为 1 到 16384 的整数。"
            return
        }
        do { _ = try CanvasRenderer.outputSize(for: snapshot, width: width) }
        catch { store.message = error.localizedDescription; return }
        let projectContext = projectLibrary.captureExport(operation: .freeCanvas, sourceURLs: snapshot.sourceURLs)
        let panel = NSSavePanel()
        let png = exportPNG
        panel.allowedContentTypes = [png ? .png : .jpeg]
        panel.nameFieldStringValue = png ? "aoipic_Canvas.png" : "aoipic_Canvas.jpg"
        if !lastExportDir.isEmpty { panel.directoryURL = URL(fileURLWithPath: lastExportDir) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastExportDir = url.deletingLastPathComponent().path
        store.isExporting = true
        projectBridge.beginExport()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CanvasRenderer.export(snapshot, width: width, png: png, to: url) }
            DispatchQueue.main.async {
                store.isExporting = false
                projectBridge.endExport()
                switch result {
                case .success:
                    projectBridge.didExport(operation: .freeCanvas, signature: signature)
                    if let projectContext { projectLibrary.recordExport(projectContext, outputURL: url) }
                    exportedFile = url.lastPathComponent
                case .failure(let error): store.message = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func receiveProjectImages() {
        guard !store.isLoading, !store.isExporting,
              let request = projectBridge.request, request.operation == .freeCanvas else { return }
        projectBridge.observeCanvas(store)
        store.importURLs(request.urls, projectMode: request.mode)
        projectBridge.consume(id: request.id)
    }

    private func clearCanvas() {
        closeInspector()
        store.clear()
        store.fitRequest += 1
    }
}

private struct CanvasNumberField: View {
    var title: String
    @Binding var value: CGFloat
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.callout)
            TextField(title, value: $value.asDouble, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
        }
    }
}
