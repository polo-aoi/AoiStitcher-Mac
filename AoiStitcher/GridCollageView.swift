import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct GridCollageCropSession: Identifiable {
    let id = UUID()
    let slotID: String
    let item: StitchItem
}

/// macOS workspace for standard split-tree collages. The view owns only
/// interaction and presentation; image loading, layout state, and rendering
/// remain in the shared collage model and renderer.
struct GridCollageView: View {
    @ObservedObject var store: GridCollageStore
    var isActive: Bool

    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme
    @State private var showingExportSettings = false
    @State private var isExporting = false
    @State private var outputWidth = 3000
    @State private var outputFormat: GridCollageExportFormat = .jpeg
    @State private var resultMessage: String?
    @State private var exportedURL: URL?
    @State private var alertMessage: String?
    @State private var cropSession: GridCollageCropSession?
    @State private var isPreparingCrop = false
    @State private var swapSourceID: String?
    @State private var pendingSlotRemoval: (targetCount: Int, photos: [GridCollagePhotoRemoval])?

    private var canInteract: Bool {
        isActive && !isExporting && !store.isLoading && !isPreparingCrop && cropSession == nil
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
        .onChange(of: isActive) { _, active in
            if !active {
                swapSourceID = nil
                showingExportSettings = false
            }
        }
        .onChange(of: store.state.activeTemplateId) { _, _ in swapSourceID = nil }
        .onChange(of: store.state.rootNode.slotIDs) { _, _ in swapSourceID = nil }
        .onChange(of: store.isLoading) { _, loading in
            if loading { swapSourceID = nil }
        }
        .onChange(of: store.status) { _, _ in
            if !isExporting {
                resultMessage = nil
                exportedURL = nil
            }
        }
        .sheet(item: $cropSession) { session in
            CropEditorView(item: session.item) { updated in
                store.applyCrop(updated, for: session.slotID)
                cropSession = nil
            } onCancel: {
                cropSession = nil
            }
            .id(session.id)
        }
        .alert("标准拼图", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("确定") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog("减少拼图格数？", isPresented: Binding(
            get: { pendingSlotRemoval != nil },
            set: { if !$0 { pendingSlotRemoval = nil } }
        ), titleVisibility: .visible) {
            if let pendingSlotRemoval {
                Button("移除照片并减少到 \(pendingSlotRemoval.targetCount) 个格子", role: .destructive) {
                    confirmSlotCountChange(pendingSlotRemoval)
                }
            }
            Button("取消", role: .cancel) { pendingSlotRemoval = nil }
        } message: {
            if let pendingSlotRemoval {
                let names = pendingSlotRemoval.photos.map(\.name).joined(separator: "、")
                Text("将移除末尾格子中的 \(pendingSlotRemoval.photos.count) 张照片：\(names)。此操作不会修改原始图片文件。")
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            EditorSidebarHeader(theme: $theme) {
                Button { store.importPhotos() } label: {
                    Label(store.isLoading ? "正在添加…" : "添加照片", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInteract)
                .keyboardShortcut("o", modifiers: .command)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    templateSelector
                    Divider()
                    styleControls
                }
                .padding(EditorStyle.padding)
            }
            .disabled(!canInteract)
            Divider()
            EditorActionBar(isExporting: isExporting,
                            disabled: !canInteract || store.photoCount == 0,
                            clearTitle: "清空拼图",
                            clear: {
                                guard canInteract else { return }
                                swapSourceID = nil
                                store.clearAll()
                                resultMessage = nil
                                exportedURL = nil
                            },
                            export: beginExport,
                            settings: {
                                guard canInteract else { return }
                                showingExportSettings = true
                            })
                .disabled(!canInteract)
                .popover(isPresented: $showingExportSettings) {
                    exportSettings
                }
        }
    }

    private var styleControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("画布样式").font(.callout.weight(.semibold))
                Spacer()
                Button("恢复默认") { store.resetStyleToDefaults() }
                    .buttonStyle(.borderless)
                    .disabled(!canInteract)
                    .accessibilityLabel("恢复画布样式默认值")
            }
            styleSlider("格子间距", value: styleBinding(\.gap), range: 0...48)
            styleSlider("画布留白", value: styleBinding(\.padding), range: 0...80)
            styleSlider("格子圆角", value: styleBinding(\.borderRadius), range: 0...48)
            ColorPicker("背景颜色", selection: Binding(
                get: { Color(nsColor: store.state.style.backgroundColor.nsColor) },
                set: { color in
                    var style = store.state.style
                    style.backgroundColor = CollageColor(NSColor(color))
                    store.setStyle(style)
                }
            ), supportsOpacity: false)
            .disabled(!canInteract)
            HStack(spacing: 8) {
                Button { store.importBackgroundImage() } label: {
                    Label(store.state.style.backgroundImage == nil ? "添加背景图" : "更换背景图", systemImage: "photo")
                }
                .disabled(!canInteract)
                Spacer()
                if store.state.style.backgroundImage != nil {
                    Button { store.clearBackgroundImage() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(!canInteract)
                        .help("移除背景图")
                }
            }
        }
    }

    private func styleSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
                .disabled(!canInteract)
        }
    }

    private func styleBinding(_ keyPath: WritableKeyPath<CollageStyle, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: { store.state.style[keyPath: keyPath] },
            set: { value in
                var style = store.state.style
                style[keyPath: keyPath] = value
                store.setStyle(style)
            }
        )
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            EditorToolbar {
                if swapSourceID != nil {
                    Label("点击另一格，交换照片", systemImage: "arrow.left.arrow.right")
                        .font(.callout).foregroundStyle(Color.accentColor)
                    Button("取消") { swapSourceID = nil }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!canInteract)
                } else {
                    HStack(spacing: 5) {
                        Text("\(store.photoCount) 张照片 · \(store.slotCount) 个格子")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize()
                        Button { requestSlotCountChange(store.slotCount - 1) } label: {
                            Image(systemName: "minus")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .disabled(!canInteract || store.slotCount <= GridCollageTemplates.supportedCounts.lowerBound)
                        .help("减少一个拼图格")
                        .accessibilityLabel("减少一个拼图格")
                        Button { requestSlotCountChange(store.slotCount + 1) } label: {
                            Image(systemName: "plus")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .disabled(!canInteract || store.slotCount >= GridCollageTemplates.supportedCounts.upperBound)
                        .help("增加一个空白拼图格")
                        .accessibilityLabel("增加一个拼图格")
                    }
                }
                if store.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Menu {
                    ForEach(CollageAspectRatio.allCases) { ratio in
                        Button {
                            store.setAspectRatio(ratio)
                        } label: {
                            if store.state.aspectRatio == ratio {
                                Label(ratio.rawValue, systemImage: "checkmark")
                            } else {
                                Text(ratio.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(store.state.aspectRatio.rawValue, systemImage: "aspectratio")
                }
                .help("切换画布比例")
                .disabled(!canInteract)
            }
            Divider()
            canvas
            if store.isLoading || isExporting || resultMessage != nil || store.pendingStatus != nil || store.status != nil {
                Divider()
                resultBar
            }
        }
    }

    private var canvas: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
            GeometryReader { proxy in
                let viewport = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 34, dy: 30)
                let fitted = GridCollageLayoutEngine.fittedRect(
                    aspectRatio: store.state.aspectRatio.value,
                    in: viewport
                )
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canInteract else { return }
                            swapSourceID = nil
                            store.selectSlot(nil)
                        }
                    GridCollageCanvas(store: store,
                                      isActive: canInteract,
                                      swapSourceID: $swapSourceID)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)

                    if canInteract,
                       let slot = store.selectedSlot, slot.hasImage,
                       let rect = GridCollageLayoutEngine.layout(
                        state: store.state,
                        in: CGRect(origin: .zero, size: fitted.size)
                       ).slotRects[slot.id] {
                        selectedImageToolbar(slot)
                            .fixedSize()
                            .position(toolbarPosition(for: rect.offsetBy(dx: fitted.minX, dy: fitted.minY),
                                                      in: proxy.size))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard canInteract, !urls.isEmpty else { return false }
            store.importDroppedURLs(urls)
            return true
        }
        .overlay {
            if store.photoCount == 0 {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("添加照片，开始拼图")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("拖入多张照片，或使用左上角的添加按钮。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .padding(22)
                .frame(maxWidth: 380)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .allowsHitTesting(false)
            }
        }
    }

    private func selectedImageToolbar(_ slot: CollageSlot) -> some View {
        HStack(spacing: 7) {
            Button { beginCrop(slot) } label: { Image(systemName: "crop") }
                .accessibilityLabel("裁剪 / 水印")
                .help(isPreparingCrop ? "正在读取完整图片…" : "编辑这张照片的裁剪和水印")
            Button {
                swapSourceID = nil
                store.replacePhoto(for: slot.id)
            } label: { Image(systemName: "photo.badge.arrow.down") }
                .accessibilityLabel("替换照片")
                .help("替换这格的照片")
            Button { beginSwap(slot) } label: { Image(systemName: "arrow.left.arrow.right") }
                .foregroundStyle(swapSourceID == slot.id ? Color.accentColor : Color.primary)
                .accessibilityLabel(swapSourceID == slot.id ? "取消交换" : "交换位置")
                .disabled(store.slotCount < 2)
                .help("点击后选择另一格，或拖动到另一格，交换照片")
                .onDrag {
                    guard canInteract, store.slotCount > 1 else { return NSItemProvider() }
                    swapSourceID = nil
                    store.selectSlot(slot.id)
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(forTypeIdentifier: GridCollageDropContent.slotType,
                                                        visibility: .ownProcess) { completion in
                        completion(Data(slot.id.utf8), nil)
                        return nil
                    }
                    return provider
                }
            Button { store.resetTransform(for: slot.id) } label: { Image(systemName: "arrow.counterclockwise") }
                .accessibilityLabel("重置取景")
                .help("重置图片取景")
            Button(role: .destructive) {
                swapSourceID = nil
                store.removePhoto(slot.id)
            } label: { Image(systemName: "trash") }
                .accessibilityLabel("删除照片")
                .help("删除照片，保留这个拼图格")
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(width: 1, height: 19)
                .padding(.horizontal, 2)
            Picker("填充方式", selection: Binding(
                get: { slot.fill },
                set: { store.setFill($0, for: slot.id) }
            )) {
                ForEach(CollageImageFill.allCases) { fill in
                    Text(fill.rawValue).tag(fill)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 118)
            .accessibilityLabel("照片填充方式")
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .font(.callout.weight(.medium))
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("所选照片快捷操作")
    }

    private func toolbarPosition(for rect: CGRect, in size: CGSize) -> CGPoint {
        let horizontalInset = min(174, size.width / 2)
        let x = min(max(rect.midX, horizontalInset), max(horizontalInset, size.width - horizontalInset))
        let y: CGFloat
        if rect.minY >= 22 {
            // Prefer the space above the selected cell to keep the photo visible.
            y = max(18, rect.minY - 23)
        } else if rect.maxY + 44 <= size.height {
            y = rect.maxY + 23
        } else {
            y = rect.minY + 23
        }
        return CGPoint(x: x, y: min(max(18, y), max(18, size.height - 18)))
    }

    private func beginSwap(_ slot: CollageSlot) {
        guard canInteract, slot.hasImage, store.slotCount > 1 else { return }
        if swapSourceID == slot.id {
            swapSourceID = nil
        } else {
            store.selectSlot(slot.id)
            swapSourceID = slot.id
        }
    }

    private func selectSlot(_ id: String) {
        if let sourceID = swapSourceID {
            if sourceID != id { store.swapImages(sourceID, id) }
            swapSourceID = nil
        }
        store.selectSlot(id)
    }

    private func requestSlotCountChange(_ count: Int) {
        switch store.setSlotCount(count) {
        case .changed, .unchanged:
            break
        case .confirmationRequired(let targetCount, let photos):
            pendingSlotRemoval = (targetCount, photos)
        case .rejected(let message):
            alertMessage = message
        }
    }

    private func confirmSlotCountChange(_ request: (targetCount: Int, photos: [GridCollagePhotoRemoval])) {
        let photoIDs = Set(request.photos.map(\.id))
        switch store.setSlotCount(request.targetCount, confirmingRemovalOf: photoIDs) {
        case .changed, .unchanged:
            pendingSlotRemoval = nil
            swapSourceID = nil
        case .confirmationRequired(let targetCount, let photos):
            pendingSlotRemoval = (targetCount, photos)
        case .rejected(let message):
            pendingSlotRemoval = nil
            alertMessage = message
        }
    }

    private var templateSelector: some View {
        EditorSection("布局模板") {
            HStack {
                Text("\(store.slotCount) 格")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                ForEach(store.availableTemplates) { template in
                    Button { store.selectTemplate(template) } label: {
                        VStack(spacing: 4) {
                            GridCollageTemplateThumbnail(rootNode: template.rootNode)
                                .frame(height: 54)
                            Text(template.name)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(GridCollageTemplateButtonStyle(
                        selected: store.state.activeTemplateId == template.id
                    ))
                    .disabled(!canInteract)
                    .accessibilityLabel("拼图模板：\(template.name)")
                }
            }
            Text("拖动分割线可调整格子大小。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resultBar: some View {
        HStack(spacing: 10) {
            if store.isLoading || isExporting {
                ProgressView().controlSize(.small)
            } else if resultMessage != nil {
                Image(systemName: exportedURL == nil ? "info.circle" : "checkmark.circle.fill")
                    .foregroundStyle(exportedURL == nil ? Color.secondary : Color.green)
            }
            Text(store.pendingStatus ?? resultMessage ?? store.status ?? "")
                .font(.callout).lineLimit(2).textSelection(.enabled)
            Spacer()
            if let exportedURL {
                Button("在访达中查看") {
                    NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var exportSettings: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("导出设置").font(.headline)
            Picker("图片格式", selection: $outputFormat) {
                ForEach(GridCollageExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("输出宽度")
                Spacer()
                TextField("3000", value: $outputWidth, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(outputWidth) },
                set: { outputWidth = Int($0.rounded()) }
            ), in: 500...8192, step: 100)
            Text("保持画布比例；最大尺寸 16384 px。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
    }

    private func beginExport() {
        guard canInteract, store.photoCount > 0 else { return }
        swapSourceID = nil
        do {
            _ = try GridCollageRenderer.outputSize(for: store.state, width: outputWidth)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出标准拼图"
        panel.prompt = "导出"
        panel.allowedContentTypes = [outputFormat.type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "aoipic-拼图.\(outputFormat.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            export(to: url)
        }
    }

    private func beginCrop(_ slot: CollageSlot) {
        guard canInteract, slot.hasImage else { return }
        let photoID = slot.photoID
        swapSourceID = nil
        showingExportSettings = false
        isPreparingCrop = true
        Task { @MainActor in
            defer { isPreparingCrop = false }
            do {
                let item = try await store.makeCropItem(for: slot.id)
                guard isActive, store.state.slots[slot.id]?.photoID == photoID else { return }
                cropSession = GridCollageCropSession(slotID: slot.id, item: item)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func export(to url: URL) {
        guard !isExporting else { return }
        let snapshot = store.state
        let width = outputWidth
        let format = outputFormat
        isExporting = true
        resultMessage = "正在导出拼图…"
        exportedURL = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<Void, Error> {
                try GridCollageRenderer.export(state: snapshot, width: width, format: format, to: url)
            }
            DispatchQueue.main.async {
                isExporting = false
                switch result {
                case .success:
                    exportedURL = url
                    resultMessage = "已导出：\(url.lastPathComponent)"
                case .failure(let error):
                    resultMessage = nil
                    alertMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct GridCollageCanvas: View {
    @ObservedObject var store: GridCollageStore
    var isActive: Bool
    @Binding var swapSourceID: String?

    var body: some View {
        GeometryReader { proxy in
            let state = store.state
            let factor = proxy.size.width / 1000
            let layout = GridCollageLayoutEngine.layout(
                state: state,
                in: CGRect(origin: .zero, size: proxy.size)
            )
            ZStack(alignment: .topLeading) {
                Color(nsColor: state.style.backgroundColor.nsColor)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isActive else { return }
                        swapSourceID = nil
                        store.selectSlot(nil)
                    }
                if let background = state.style.backgroundImage {
                    Image(nsImage: NSImage(cgImage: background, size: .zero))
                        .resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                }
                ForEach(state.rootNode.slotIDs, id: \.self) { slotID in
                    if let slot = state.slots[slotID], let rect = layout.slotRects[slotID] {
                        GridCollageSlotView(
                            store: store,
                            slot: slot,
                            viewport: rect.size,
                            radius: min(state.style.borderRadius * factor, min(rect.width, rect.height) / 2),
                            isActive: isActive,
                            swapSourceID: $swapSourceID
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    }
                }
                ForEach(layout.dividers) { divider in
                    GridCollageDividerHandle(
                        store: store,
                        divider: divider,
                        isActive: isActive && swapSourceID == nil,
                        onBackgroundTap: clearSelection
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color(nsColor: state.style.backgroundColor.nsColor))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.14), radius: 13, y: 5)
            .background(GridCollageScrollReader(store: store, isActive: isActive && swapSourceID == nil))
            .coordinateSpace(name: "aoipic-grid-canvas")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标准拼图画布")
    }

    private func clearSelection() {
        guard isActive else { return }
        swapSourceID = nil
        store.selectSlot(nil)
    }
}

/// Observe wheel and trackpad magnification only inside this canvas. Keeping
/// the monitor on a background NSView lets SwiftUI retain ordinary pointer
/// gestures and native drag-and-drop above it.
private struct GridCollageScrollReader: NSViewRepresentable {
    @ObservedObject var store: GridCollageStore
    var isActive: Bool

    func makeNSView(context: Context) -> GridCollageScrollView {
        let view = GridCollageScrollView()
        view.store = store
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: GridCollageScrollView, context: Context) {
        view.store = store
        view.isActive = isActive
    }
}

private final class GridCollageScrollView: NSView {
    weak var store: GridCollageStore?
    var isActive = true
    private var monitor: Any?
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, self.isActive, self.window == event.window,
                  let store = self.store, !store.isLoading else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            let layout = GridCollageLayoutEngine.layout(state: store.state, in: self.bounds)
            guard let slotID = store.state.rootNode.slotIDs.first(where: {
                layout.slotRects[$0]?.contains(point) == true
            }), let slot = store.state.slots[slotID], slot.hasImage,
                  let viewport = layout.slotRects[slotID]?.size else { return event }

            let zoomFactor: CGFloat
            if event.type == .magnify {
                zoomFactor = max(0.1, 1 + event.magnification)
            } else {
                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.04
                zoomFactor = exp(event.scrollingDeltaY * sensitivity)
            }
            store.selectSlot(slotID)
            store.setScale(slot.transform.scale * zoomFactor, for: slotID, viewport: viewport)
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

private struct GridCollageSlotView: View {
    @ObservedObject var store: GridCollageStore
    let slot: CollageSlot
    let viewport: CGSize
    let radius: CGFloat
    let isActive: Bool
    @Binding var swapSourceID: String?

    @State private var isHovered = false
    @State private var isDropTarget = false
    @State private var panStart: CollageImageTransform?
    @State private var dropGeneration = UUID()
    @State private var acceptsDrops = false

    private var isSelected: Bool { store.state.selectedSlotId == slot.id }
    private var isSwapTarget: Bool { swapSourceID != nil && swapSourceID != slot.id }
    private var image: CGImage? { slot.previewImage ?? slot.image }

    var body: some View {
        ZStack {
            if !slot.hasImage {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.55))
            }

            if let image {
                let imageRect = GridCollageLayoutEngine.imageRect(
                    imageSize: CGSize(width: image.width, height: image.height),
                    viewport: CGRect(origin: .zero, size: viewport),
                    transform: slot.transform,
                    fill: slot.fill
                )
                Image(nsImage: NSImage(cgImage: image, size: .zero))
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
            } else if store.photoCount > 0 {
                VStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                    Text("添加照片")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            if isDropTarget || (isSwapTarget && isHovered) {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.accentColor, lineWidth: 2))
                    .allowsHitTesting(false)
            }

            if isSwapTarget && isHovered {
                Label("交换到这里", systemImage: "arrow.left.arrow.right")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
            }

            if isSelected {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            } else if isHovered {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Color.accentColor.opacity(0.62), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: viewport.width, height: viewport.height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .contentShape(Rectangle())
        .onTapGesture {
            guard isActive else { return }
            if let sourceID = swapSourceID {
                if sourceID != slot.id { store.swapImages(sourceID, slot.id) }
                swapSourceID = nil
                store.selectSlot(slot.id)
                return
            }
            store.selectSlot(slot.id)
            if !slot.hasImage && isActive && !store.isLoading {
                store.importPhotos(into: slot.id)
            }
        }
        .simultaneousGesture(panGesture)
        .onDrop(of: [GridCollageDropContent.slotType, UTType.fileURL.identifier],
                isTargeted: $isDropTarget, perform: receiveDrop)
        .onHover { hovering in
            isHovered = hovering
            guard isActive else { return }
            if hovering {
                swapSourceID == nil ? NSCursor.openHand.set() : NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onAppear { acceptsDrops = isActive }
        .onDisappear {
            acceptsDrops = false
            dropGeneration = UUID()
        }
        .onChange(of: isActive) { _, active in
            acceptsDrops = active
            dropGeneration = UUID()
            if !active { panStart = nil }
        }
        .onChange(of: store.state.activeTemplateId) { _, _ in dropGeneration = UUID() }
        .onChange(of: slot.photoID) { _, _ in dropGeneration = UUID() }
        .onChange(of: swapSourceID) { _, _ in panStart = nil }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(slot.hasImage ? slot.name : "空白图片格")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard isActive, swapSourceID == nil, slot.imageSize != nil,
                      viewport.width > 0, viewport.height > 0 else { return }
                if panStart == nil {
                    panStart = slot.transform
                    store.selectSlot(slot.id)
                }
                guard let start = panStart else { return }
                let translation = CGPoint(
                    x: start.translateX + value.translation.width / viewport.width,
                    y: start.translateY + value.translation.height / viewport.height
                )
                store.setPan(translation, for: slot.id, viewport: viewport)
            }
            .onEnded { _ in panStart = nil }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isActive, acceptsDrops, !store.isLoading,
              let targetPhotoID = store.state.slots[slot.id]?.photoID else { return false }
        let generation = UUID()
        dropGeneration = generation
        let templateID = store.state.activeTemplateId
        let photoIDs = store.state.slots.mapValues(\.photoID)
        swapSourceID = nil
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(GridCollageDropContent.slotType)
        }) {
            provider.loadDataRepresentation(forTypeIdentifier: GridCollageDropContent.slotType) { data, _ in
                guard let data, let sourceID = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    guard isCurrentDrop(generation, templateID: templateID, targetPhotoID: targetPhotoID),
                          sourceID != slot.id, let sourcePhotoID = photoIDs[sourceID],
                          store.state.slots[sourceID]?.photoID == sourcePhotoID,
                          store.state.slots[sourceID]?.hasImage == true else { return }
                    store.swapImages(sourceID, slot.id)
                    store.selectSlot(slot.id)
                }
            }
            return true
        }
        return GridCollageDropContent.loadFileURLs(from: providers) { urls in
            guard isCurrentDrop(generation, templateID: templateID, targetPhotoID: targetPhotoID),
                  !urls.isEmpty else { return }
            store.selectSlot(slot.id)
            store.importDroppedURLs(urls, into: slot.id)
        }
    }

    private func isCurrentDrop(_ generation: UUID, templateID: String, targetPhotoID: UUID) -> Bool {
        // State-backed lifetime and identity checks remain current even when
        // a provider finishes after the originating View value is obsolete.
        acceptsDrops && dropGeneration == generation && !store.isLoading &&
            store.state.activeTemplateId == templateID &&
            store.state.slots[slot.id]?.photoID == targetPhotoID
    }
}

private struct GridCollageDividerHandle: View {
    @ObservedObject var store: GridCollageStore
    let divider: GridCollageDivider
    let isActive: Bool
    let onBackgroundTap: () -> Void

    @State private var isHovered = false
    @State private var lastTranslation: CGFloat = 0
    @State private var didDrag = false

    private var isHorizontalSplit: Bool { divider.direction == .horizontal }

    var body: some View {
        let hitWidth = isHorizontalSplit ? 22 : divider.containerRect.width
        let hitHeight = isHorizontalSplit ? divider.containerRect.height : 22
        ZStack {
            Rectangle().fill(Color.clear)
            Capsule()
                .fill(isHovered ? Color.accentColor : Color.white.opacity(0.82))
                .frame(width: isHorizontalSplit ? 3 : min(52, max(24, hitWidth * 0.12)),
                       height: isHorizontalSplit ? min(52, max(24, hitHeight * 0.12)) : 3)
                .shadow(color: .black.opacity(0.24), radius: 2)
                .opacity(isHovered || lastTranslation != 0 ? 1 : 0)
        }
        .frame(width: max(1, hitWidth), height: max(1, hitHeight))
        // Keep interactions on this narrow hit area. Positioning first would
        // expose the surrounding canvas-sized layout frame to hit testing.
        .contentShape(Rectangle())
        .allowsHitTesting(isActive)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("aoipic-grid-canvas"))
            .onChanged { value in
                guard isActive else { return }
                let translation = isHorizontalSplit ? value.translation.width : value.translation.height
                guard didDrag || abs(translation) > 3 else { return }
                didDrag = true
                let delta = translation - lastTranslation
                if abs(delta) > 0.05 {
                    store.resizeDivider(divider, delta: delta)
                    lastTranslation = translation
                }
            }
            .onEnded { _ in
                if !didDrag { onBackgroundTap() }
                didDrag = false
                lastTranslation = 0
            })
        .onHover { hovering in
            isHovered = hovering
            guard isActive else { return }
            if hovering {
                isHorizontalSplit ? NSCursor.resizeLeftRight.set() : NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(isHorizontalSplit ? "左右拖动以调整分割线" : "上下拖动以调整分割线")
        .position(x: divider.rect.midX, y: divider.rect.midY)
    }
}

private struct GridCollageTemplateThumbnail: View {
    let rootNode: SplitNode

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let layout = GridCollageLayoutEngine.layout(rootNode: rootNode, in: bounds, gap: 2)
            Canvas { context, size in
                let colors: [Color] = [
                    Color.accentColor.opacity(0.72),
                    Color.accentColor.opacity(0.48),
                    Color.secondary.opacity(0.4),
                    Color.accentColor.opacity(0.3)
                ]
                for (index, slotID) in rootNode.slotIDs.enumerated() {
                    guard let rect = layout.slotRects[slotID] else { continue }
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    context.fill(path, with: .color(colors[index % colors.count]))
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityHidden(true)
    }
}

private struct GridCollageTemplateButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.1) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private extension CollageColor {
    init(_ color: NSColor) {
        let color = color.usingColorSpace(.deviceRGB) ?? .white
        self.init(red: color.redComponent, green: color.greenComponent,
                  blue: color.blueComponent, alpha: color.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private enum GridCollageDropContent {
    static let slotType = "com.aoipic.grid-slot"

    /// Collect a multi-file drop before importing, preserving the drag order.
    /// One coordinated import avoids replacing the same target repeatedly.
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
