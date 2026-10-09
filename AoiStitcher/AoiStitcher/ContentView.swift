import SwiftUI
import UniformTypeIdentifiers
import AppKit

// ==========================================
// 2. 主界面
// ==========================================
struct LongStitchView: View {
    var isActive: Bool = true
    @State private var images: [StitchItem] = []
    @State private var spacing: CGFloat = 20.0
    @State private var bottomMargin: CGFloat = 150.0

    // 💡 记忆储存：外观主题仅保留 1:浅色, 2:深色 (默认浅色)
    @AppStorage("colorSchemeStyle") private var colorSchemeStyle: Int = 1
    @AppStorage("exportWidth") private var exportWidth = AppPreferences.defaultExportWidth
    @AppStorage("exportPNG") private var exportPNG = AppPreferences.defaultExportPNG
    @AppStorage("lastGlobalWatermarkDir") private var lastGlobalWatermarkDir: String = ""
    @AppStorage("lastExportDir") private var lastExportDir: String = ""

    @State private var editingItem: StitchItem?
    @State private var hostingScrollView: NSScrollView?
    @State private var canvasScale: CGFloat = 1.0

    @State private var isSpacePressed = false
    @State private var eventMonitor: Any?
    @State private var draggedItem: StitchItem?
    @State private var dragOffset: CGFloat = 0
    @State private var dragClickOffsetError: CGFloat = 0

    @State private var globalWatermark: NSImage?
    @State private var globalWmScale: CGFloat = 1.0
    @State private var globalWmOffsetX: CGFloat = 0
    @State private var globalWmOffsetY: CGFloat = 0

    @State private var isExporting = false
    @State private var showingExportSettings = false
    @State private var exportSucceeded = false
    @State private var showingExportAlert = false
    @State private var exportAlertTitle = ""
    @State private var exportAlertMessage = ""

    // 强制返回指定的 ColorScheme
    var currentColorScheme: ColorScheme {
        return colorSchemeStyle == 2 ? .dark : .light
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                EditorSidebarHeader(theme: $colorSchemeStyle) {
                    Button(action: importPhotos) {
                        Label("添加照片", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).help("添加照片")
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        EditorSection("排版") {
                            VStack(spacing: 10) {
                                HStack {
                                    Text("图片间距")
                                    Spacer()
                                    TextField("间距", value: $spacing.asDouble, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 64)
                                    Text("px").foregroundStyle(.secondary)
                                }
                                Slider(value: $spacing, in: 0...300)
                                HStack {
                                    Text("底部留白")
                                    Spacer()
                                    TextField("留白", value: $bottomMargin.asDouble, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 64)
                                    Text("px").foregroundStyle(.secondary)
                                }
                                Slider(value: $bottomMargin, in: 0...1000)
                            }
                        }
                        Divider()
                        EditorSection("全局水印") {
                            HStack {
                                Button(action: selectGlobalWatermark) {
                                    Label(globalWatermark == nil ? "添加水印" : "更换水印", systemImage: "photo.badge.plus")
                                }
                                Spacer()
                                if globalWatermark != nil {
                                    Button { globalWatermark = nil } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless).help("删除水印")
                                }
                            }
                            if globalWatermark != nil {
                                VStack(spacing: 10) {
                                    HStack {
                                        Text("缩放")
                                        Spacer()
                                        TextField("缩放", value: $globalWmScale.asDouble,
                                                  format: .number.precision(.fractionLength(0...2)))
                                            .textFieldStyle(.roundedBorder).frame(width: 64)
                                    }
                                    Slider(value: $globalWmScale, in: 0.1...3)
                                    HStack {
                                        Text("X")
                                        Spacer()
                                        TextField("X", value: $globalWmOffsetX.asDouble, format: .number)
                                            .textFieldStyle(.roundedBorder).frame(width: 64)
                                    }
                                    Slider(value: $globalWmOffsetX, in: -1000...1000)
                                    HStack {
                                        Text("Y")
                                        Spacer()
                                        TextField("Y", value: $globalWmOffsetY.asDouble, format: .number)
                                            .textFieldStyle(.roundedBorder).frame(width: 64)
                                    }
                                    Slider(value: $globalWmOffsetY, in: -500...500)
                                }
                            }
                        }
                        Divider()
                        EditorSection("素材") {
                            ForEach(images) { item in
                                HStack(spacing: 8) {
                                    Image(nsImage: item.displayImage).resizable().scaledToFit().frame(width: 30, height: 30)
                                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button { editingItem = item } label: { Image(systemName: "crop") }
                                        .buttonStyle(.borderless).help("裁剪与水印")
                                    Button { images.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless).help("删除照片")
                                }.padding(.vertical, 4)
                            }
                        }
                    }.padding(16)
                }
                Divider()
                EditorActionBar(isExporting: isExporting, disabled: images.isEmpty,
                                clear: clearCanvas, export: exportFinalImage,
                                settings: { showingExportSettings = true })
                    .popover(isPresented: $showingExportSettings) { ExportSettingsView() }
            }
            .frame(width: EditorStyle.sidebarWidth)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                EditorToolbar {
                    Text("\(images.count) 张照片").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: fitToScreen) { Label("适合窗口", systemImage: "viewfinder") }.help("适合窗口")
                    Text("\(Int(canvasScale * 100))%").font(.callout.monospacedDigit()).frame(width: 48)
                }
                Divider()
                ZStack {
                    Color(NSColor.controlBackgroundColor)
                    ScrollView([.vertical, .horizontal]) {
                        VStack(spacing: 0) {
                            if !images.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(images) { item in
                                        Image(nsImage: item.displayImage).resizable().scaledToFit().frame(maxWidth: .infinity)
                                            .shadow(color: draggedItem == item ? .black.opacity(0.3) : .clear, radius: 10)
                                            .opacity(draggedItem == item ? 0.9 : 1)
                                            .zIndex(draggedItem == item ? 1 : 0)
                                            .offset(y: draggedItem == item ? dragOffset : 0).contentShape(Rectangle())
                                            .padding(.bottom, item.id == images.last?.id ? 0 : spacing)
                                    }
                                    if bottomMargin > 0 {
                                        ZStack {
                                            Color.white
                                            if let wm = globalWatermark {
                                                let width = 800 * 0.3 * globalWmScale
                                                Image(nsImage: wm).resizable().scaledToFit()
                                                    .frame(width: width, height: width / (wm.size.width / max(1, wm.size.height)))
                                                    .offset(x: globalWmOffsetX, y: -globalWmOffsetY)
                                            }
                                        }.frame(height: bottomMargin).frame(maxWidth: .infinity).clipped()
                                    }
                                }.frame(width: 800).padding(.vertical, 60).fixedSize(horizontal: true, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .background(ScrollViewConfigurator(scrollViewProxy: $hostingScrollView, currentScale: $canvasScale))
                    }
                    if images.isEmpty { EditorEmptyState() }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let group = DispatchGroup()
                    for url in urls {
                        group.enter()
                        loadAndAddImage(from: url) { group.leave() }
                    }
                    group.notify(queue: .main) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { fitToScreen() }
                    }
                    return true
                }
            }
            .onAppear { if isActive { setupEventMonitor() } }
            .onDisappear(perform: removeEventMonitor)
            .onChange(of: isActive) { _, active in
                if active { setupEventMonitor() } else { removeEventMonitor() }
            }
        }
        .preferredColorScheme(currentColorScheme)
        .sheet(item: $editingItem) { item in
            CropEditorView(item: item) { updated in
                if let index = images.firstIndex(where: { $0.id == updated.id }) { images[index] = updated }
                editingItem = nil
            } onCancel: { editingItem = nil }.id(item.id)
        }
        .alert(exportAlertTitle, isPresented: $showingExportAlert) {
            if exportSucceeded {
                Button("保留画布", role: .cancel) {}
                Button("清空画布", role: .destructive, action: clearCanvas)
            } else { Button("确定") {} }
        } message: { Text(exportAlertMessage) }
    }

    private func clearCanvas() {
        images.removeAll()
        draggedItem = nil; dragOffset = 0
        hostingScrollView?.magnification = 1
    }

    private func importPhotos() {
        guard editingItem == nil else { return } // 弹窗时禁用快捷键
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            let group = DispatchGroup()
            for url in panel.urls {
                group.enter()
                loadAndAddImage(from: url) { group.leave() }
            }
            group.notify(queue: .main) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.fitToScreen() }
            }
        }
    }

    private func fitToScreen() {
        guard editingItem == nil else { return } // 弹窗时禁用快捷键
        guard !images.isEmpty, let scrollView = hostingScrollView else { return }; let canvasWidth: CGFloat = 800; var totalHeight: CGFloat = 0
        for item in images { totalHeight += canvasWidth / item.displayAspect }
        if images.count > 1 { totalHeight += CGFloat(images.count - 1) * spacing }; totalHeight += bottomMargin + 120
        let targetScale = min(1.0, max(0.05, min((scrollView.contentSize.width - 40) / canvasWidth, (scrollView.contentSize.height - 40) / totalHeight)))
        if let docRect = scrollView.documentView?.bounds { scrollView.animator().setMagnification(targetScale, centeredAt: NSPoint(x: docRect.midX, y: docRect.midY)) }
    }

    private func selectGlobalWatermark() {
        guard editingItem == nil else { return } // 弹窗时禁用快捷键
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.image]
        if !lastGlobalWatermarkDir.isEmpty { panel.directoryURL = URL(fileURLWithPath: lastGlobalWatermarkDir) }

        if panel.runModal() == .OK, let url = panel.url {
            globalWatermark = NSImage(contentsOf: url)
            lastGlobalWatermarkDir = url.deletingLastPathComponent().path
        }
    }

    private func exportFinalImage() {
        guard editingItem == nil else { return } // 弹窗时禁用快捷键
        guard !images.isEmpty else { return }
        guard let width = AppPreferences.exportWidth(exportWidth) else {
            exportSucceeded = false; exportAlertTitle = "导出设置有误"
            exportAlertMessage = "导出宽度需为 1 到 16384 的整数。"
            showingExportAlert = true; return
        }
        let png = exportPNG
        let savePanel = NSSavePanel(); savePanel.allowedContentTypes = [png ? .png : .jpeg]
        savePanel.nameFieldStringValue = png ? "AoiStitcher_Output.png" : "AoiStitcher_Output.jpg"
        if !lastExportDir.isEmpty { savePanel.directoryURL = URL(fileURLWithPath: lastExportDir) }

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }; isExporting = true
            self.lastExportDir = url.deletingLastPathComponent().path

            let safeImages = self.images; let safeExportWidth = CGFloat(width); let safeSpacing = self.spacing; let safeBottomMargin = self.bottomMargin; let safeGlobalWM = self.globalWatermark; let safeWmScale = self.globalWmScale; let safeWmOffsetX = self.globalWmOffsetX; let safeWmOffsetY = self.globalWmOffsetY

            // ---- 根据预览画布基准 (800) 计算等比例缩放系数 ----
            let canvasBaseWidth: CGFloat = 800.0
            let scaleRatio = safeExportWidth / canvasBaseWidth
            let exportSpacing = safeSpacing * scaleRatio
            let exportBottomMargin = safeBottomMargin * scaleRatio
            let exportWmOffsetX = safeWmOffsetX * scaleRatio
            let exportWmOffsetY = safeWmOffsetY * scaleRatio

            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        var totalHeight: CGFloat = 0; var drawFrames: [(NSImage, CGRect)] = []
                        for item in safeImages {
                            let img = item.displayImage; let targetHeight = safeExportWidth / (img.size.width / max(1, img.size.height))
                            drawFrames.append((img, CGRect(x: 0, y: 0, width: safeExportWidth, height: targetHeight))); totalHeight += targetHeight
                        }
                        if safeImages.count > 1 { totalHeight += CGFloat(safeImages.count - 1) * exportSpacing }; totalHeight += exportBottomMargin

                        let colorSpace = CGColorSpaceCreateDeviceRGB()
                        guard let ctx = CGContext(data: nil, width: Int(safeExportWidth), height: Int(totalHeight), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NSError(domain: "OOM", code: 1, userInfo: nil) }
                        ctx.setFillColor(CGColor.white); ctx.fill(CGRect(x: 0, y: 0, width: safeExportWidth, height: totalHeight))

                        var currentY = totalHeight
                        for (i, frame) in drawFrames.enumerated() {
                            let (img, rect) = frame; currentY -= rect.height
                            let drawRect = CGRect(x: 0, y: currentY, width: rect.width, height: rect.height)
                            if let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { ctx.draw(cgImage, in: drawRect) }
                            if i < drawFrames.count - 1 { currentY -= exportSpacing }
                        }

                        if let wm = safeGlobalWM {
                            let wmAspect = wm.size.width / max(1, wm.size.height); let actualWidth = safeExportWidth * 0.3 * safeWmScale; let actualHeight = actualWidth / wmAspect
                            let wmX = (safeExportWidth - actualWidth) / 2 + exportWmOffsetX; let wmY = (exportBottomMargin - actualHeight) / 2 + exportWmOffsetY
                            if let cgWM = wm.cgImage(forProposedRect: nil, context: nil, hints: nil) { ctx.draw(cgWM, in: CGRect(x: wmX, y: wmY, width: actualWidth, height: actualHeight)) }
                        }

                        guard let finalCGImage = ctx.makeImage() else { throw NSError(domain: "RenderError", code: 2, userInfo: nil) }
                        let finalNSImage = NSImage(cgImage: finalCGImage, size: NSSize(width: safeExportWidth, height: totalHeight))
                        if let tiff = finalNSImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                            guard let data = bitmap.representation(using: png ? .png : .jpeg, properties: [.compressionFactor: 0.95]) else {
                                throw NSError(domain: "WriteError", code: 3)
                            }
                            try data.write(to: url, options: .atomic)
                            DispatchQueue.main.async { self.exportSucceeded = true; self.exportAlertTitle = "导出成功"; self.exportAlertMessage = "图片已保存：\(url.lastPathComponent)"; self.showingExportAlert = true; self.isExporting = false }
                        } else { throw NSError(domain: "WriteError", code: 3, userInfo: nil) }
                    } catch {
                        DispatchQueue.main.async { self.exportSucceeded = false; self.exportAlertTitle = "导出失败"; self.exportAlertMessage = "内存不足或处理超大分辨率失败。"; self.showingExportAlert = true; self.isExporting = false }
                    }
                }
            }
        }
    }

    // 💡 性能核心优化：通过缓存属性进行 O(1) 的高度测算
    private func getCenters(for currentImages: [StitchItem]) -> [CGFloat] {
        var currentY: CGFloat = 60
        var centers: [CGFloat] = []
        for item in currentImages {
            let h = 800 / item.displayAspect
            centers.append(currentY + h / 2)
            currentY += h + spacing
        }
        return centers
    }

    private func setupEventMonitor() {
        guard eventMonitor == nil else { return }
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .keyUp, .magnify]) { event in
            guard isActive else { return event }

            guard editingItem == nil else { return event }
            guard let scrollView = hostingScrollView, let win = scrollView.window, event.window == win,
                  let documentView = scrollView.documentView else { return event }
            if event.type == .keyDown || event.type == .keyUp {
                guard win.firstResponder as? NSTextView == nil else { return event }
            } else if [.leftMouseDown, .scrollWheel, .magnify].contains(event.type) {
                let point = scrollView.convert(event.locationInWindow, from: nil)
                guard scrollView.bounds.contains(point) else { return event }
            }

            if event.type == .keyDown || event.type == .keyUp {
                if event.keyCode == 49 {
                    if event.type == .keyDown && !event.isARepeat { isSpacePressed = true; NSCursor.openHand.push(); return nil }
                    else if event.type == .keyUp { isSpacePressed = false; NSCursor.pop(); return nil }
                }
            }

            if event.type == .magnify {
                let newMag = max(0.05, min(scrollView.magnification + event.magnification, 4.0))
                scrollView.setMagnification(newMag, centeredAt: scrollView.documentView!.convert(event.locationInWindow, from: nil))
                return nil
            }
            if event.type == .scrollWheel && event.modifierFlags.contains(.option) {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.5 : event.scrollingDeltaY * 5.0
                let zoomFactor = 1.0 + (delta * 0.01)
                let newMag = max(0.05, min(scrollView.magnification * zoomFactor, 4.0))
                scrollView.setMagnification(newMag, centeredAt: scrollView.documentView!.convert(event.locationInWindow, from: nil))
                return nil
            }

            if isSpacePressed {
                if event.type == .leftMouseDragged { NSCursor.closedHand.set(); scrollView.documentView?.scroll(NSPoint(x: scrollView.contentView.bounds.origin.x - event.deltaX, y: scrollView.contentView.bounds.origin.y - event.deltaY)); return nil }
                else if event.type == .leftMouseUp { NSCursor.openHand.set(); return nil } else if event.type == .leftMouseDown { return nil }
            }

            if event.type == .leftMouseDown {
                let click = documentView.convert(event.locationInWindow, from: nil)
                let imageX = documentView.bounds.midX - 400
                guard click.x >= imageX, click.x <= imageX + 800 else { return event }
                let clickY = click.y
                if event.clickCount == 2 {
                    draggedItem = nil; dragOffset = 0; dragClickOffsetError = 0; var currentY: CGFloat = 60
                    for item in images {
                        let itemHeight = 800 / item.displayAspect
                        if clickY >= currentY && clickY <= (currentY + itemHeight) { DispatchQueue.main.async { self.editingItem = item }; return event }
                        currentY += itemHeight + spacing
                    }; return event
                }
                if event.clickCount == 1 && !isSpacePressed {
                    var currentY: CGFloat = 60
                    for item in images {
                        let itemHeight = 800 / item.displayAspect
                        if clickY >= currentY && clickY <= (currentY + itemHeight) { withAnimation(.spring(response: 0.2)) { draggedItem = item }; dragClickOffsetError = clickY - (currentY + itemHeight / 2); dragOffset = 0; break }
                        currentY += itemHeight + spacing
                    }
                }
            }

            if event.type == .leftMouseDragged {
                if let item = draggedItem, !isSpacePressed {
                    guard let documentView = scrollView.documentView else { return event }
                    let visualCenterY = documentView.convert(event.locationInWindow, from: nil).y - dragClickOffsetError
                    var currentCenters = getCenters(for: images)
                    guard let currentIndex = images.firstIndex(where: { $0.id == item.id }) else { return nil }

                    var closestIndex = currentIndex; var minDistance: CGFloat = .infinity
                    for (index, center) in currentCenters.enumerated() { let dist = abs(center - visualCenterY); if dist < minDistance { minDistance = dist; closestIndex = index } }

                    if closestIndex != currentIndex {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            let moved = images.remove(at: currentIndex)
                            images.insert(moved, at: closestIndex)
                        }
                        currentCenters = getCenters(for: images)
                    }
                    dragOffset = visualCenterY - currentCenters[closestIndex]
                    return nil
                }
            }
            if event.type == .leftMouseUp { if draggedItem != nil { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { draggedItem = nil; dragOffset = 0; dragClickOffsetError = 0 } } }
            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        eventMonitor = nil
        if isSpacePressed { NSCursor.pop() }
        isSpacePressed = false
        draggedItem = nil
        dragOffset = 0
    }

    private func loadAndAddImage(from url: URL, completion: (() -> Void)? = nil) {
        let accessing = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            if let nsImage = NSImage(contentsOf: url) {
                DispatchQueue.main.async {
                    withAnimation { self.images.append(StitchItem(url: url, image: nsImage)) }
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    completion?()
                }
            }
            else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async { completion?() }
            }
        }
    }
}

struct ScrollViewConfigurator: NSViewRepresentable {
    @Binding var scrollViewProxy: NSScrollView?
    @Binding var currentScale: CGFloat
    class Coordinator: NSObject { var observer: NSKeyValueObservation?; deinit { observer?.invalidate() } }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView {
                scrollView.allowsMagnification = true; scrollView.minMagnification = 0.05; scrollView.maxMagnification = 4.0
                DispatchQueue.main.async { self.scrollViewProxy = scrollView }
                context.coordinator.observer = scrollView.observe(\.magnification, options: [.new]) { sv, _ in DispatchQueue.main.async { self.currentScale = sv.magnification } }
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
