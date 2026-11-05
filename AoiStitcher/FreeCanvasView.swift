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
    @State private var isAdjustingGap = false
    @State private var hasStartedGapChange = false
    @State private var showingExportSettings = false
    @State private var exportedFile: String?
    @State private var showingMissingBackgroundAlert = false
    @State private var cropSession: CanvasCropSession?
    @StateObject private var paperLibrary = PaperLibraryStore()

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
                                    onCrop: startCrop, onReplace: chooseReplacement)
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
                if !store.document.layers.isEmpty {
                    Text(interactionSettings.hint)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                }
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
        .onChange(of: store.document.arrangement, initial: true) { _, arrangement in
            if let arrangement {
                layoutMargin = arrangement.margin
                layoutGap = arrangement.gap
            } else {
                finishGapAdjustment()
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { finishGapAdjustment() }
        }
        .onDisappear { finishGapAdjustment() }
        .sheet(item: $cropSession) { session in
            CropEditorView(item: session.item) { updated in
                store.updateCrop(updated, layerID: session.id); cropSession = nil
            } onCancel: { cropSession = nil }
        }
        .alert("AoiStitcher", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
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
            EditorSidebarHeader {
                Button { store.importImages() } label: {
                    Label("添加照片", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(store.isLoading || store.isExporting)
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
        PaperLibrarySidebar(library: paperLibrary, isActive: isActive,
                            isApplying: store.isLoading || store.isExporting,
                            onUse: { usePaper($0) },
                            onAddLayer: { usePaper($0, addingLayer: true) },
                            onImageReplaced: { item, image, preview in
                                store.refreshPaperLibraryImage(id: item.id, name: item.displayName,
                                                               image: image, preview: preview)
                            })
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
            }
        }
    }

    private var layoutControls: some View {
        EditorSection("快捷排版") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    arrangementButton("左右排", icon: "rectangle.split.2x1", horizontal: true)
                    arrangementButton("上下排", icon: "rectangle.split.1x2", horizontal: false)
                }
                .disabled(!canArrange || store.isLoading || store.isExporting)
                HStack {
                    CanvasNumberField(title: "留白", value: arrangementMarginBinding)
                    CanvasNumberField(title: "间距", value: arrangementGapBinding)
                }
                .disabled(store.isLoading || store.isExporting)
                Slider(value: arrangementGapBinding, in: 0...max(1, store.maximumArrangementGap)) { editing in
                    isAdjustingGap = editing
                    if !editing { finishGapAdjustment() }
                }
                .disabled(store.document.arrangement == nil || arrangedPhotoCount < 2
                          || store.isLoading || store.isExporting)
                .accessibilityLabel("照片间距")
                Text(store.document.arrangement == nil
                     ? "选择排版方向后，可实时调整照片间距。"
                     : "横排等高，竖排等宽；照片整体适应画布。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var layersControls: some View {
        EditorSection("画布图层") {
            VStack(alignment: .leading, spacing: 4) {
                if store.document.layers.isEmpty {
                    Text("照片和纸张会显示在这里。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                if !store.document.layers.isEmpty {
                    CanvasLayersList(store: store, onCrop: startCrop, onReplace: chooseReplacement)
                        .frame(height: min(264, CGFloat(store.document.layers.count) * 44 + 4))
                }
                if let layer = store.selectedLayer, layer.kind == .paper, layer.image == nil {
                    ColorPicker("纸张颜色", selection: paperColorBinding, supportsOpacity: false)
                        .disabled(layer.locked || store.isLoading || store.isExporting)
                }
            }
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

    private var arrangedPhotoCount: Int {
        store.document.layers.filter { $0.kind == .photo && !$0.locked }.count
    }

    private var canArrange: Bool { arrangedPhotoCount > 0 }

    private func arrangementButton(_ title: String, icon: String, horizontal: Bool) -> some View {
        let selected = store.document.arrangement?.direction == (horizontal ? .horizontal : .vertical)
        return Button { arrange(horizontal: horizontal) } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Color.accentColor : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var arrangementMarginBinding: Binding<CGFloat> {
        Binding(get: { store.document.arrangement?.margin ?? layoutMargin }, set: { value in
            guard value.isFinite else { return }
            layoutMargin = max(0, value)
            store.updateArrangement(margin: layoutMargin)
        })
    }

    private var arrangementGapBinding: Binding<CGFloat> {
        Binding(get: { store.document.arrangement?.gap ?? layoutGap }, set: { value in
            guard value.isFinite else { return }
            let gap = max(0, value)
            guard gap != (store.document.arrangement?.gap ?? layoutGap) else { return }
            if isAdjustingGap, !hasStartedGapChange, store.document.arrangement != nil {
                store.beginContinuousChange()
                hasStartedGapChange = true
            }
            layoutGap = gap
            store.updateArrangement(gap: gap)
        })
    }

    private func finishGapAdjustment() {
        if hasStartedGapChange { store.endContinuousChange() }
        hasStartedGapChange = false
        isAdjustingGap = false
    }

    private func usePaper(_ item: PaperLibraryItem, addingLayer: Bool = false) {
        finishGapAdjustment()
        if let color = item.color {
            store.usePaperColor(CanvasColor(color.nsColor), name: item.displayName,
                                libraryID: item.id, addingLayer: addingLayer)
        } else {
            store.usePaperImage(at: paperLibrary.url(for: item), name: item.displayName,
                                libraryID: item.id, addingLayer: addingLayer)
        }
    }
    private var paperColorBinding: Binding<Color> {
        Binding(get: { Color(store.selectedLayer?.color.nsColor ?? .white) }, set: { color in
            guard let id = store.selectedLayer?.id else { return }
            store.editLayer(id) { $0.color = CanvasColor(NSColor(color)) }
        })
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
    private func arrange(horizontal: Bool) {
        finishGapAdjustment()
        store.arrange(horizontal: horizontal, margin: layoutMargin, gap: layoutGap)
    }
    private func startCrop(_ layer: CanvasLayer) {
        guard !layer.locked, !store.isLoading, !store.isExporting, let item = layer.photo else { return }
        store.selectedID = layer.id
        cropSession = CanvasCropSession(id: layer.id, item: item)
    }
    private func chooseReplacement(_ layer: CanvasLayer) {
        guard !layer.locked, !store.isLoading, !store.isExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择替换此照片的图片"
        panel.directoryURL = layer.photo?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.replacePhoto(with: url, layerID: layer.id)
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
        panel.nameFieldStringValue = png ? "AoiStitcher_Canvas.png" : "AoiStitcher_Canvas.jpg"
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
