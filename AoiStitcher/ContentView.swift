import SwiftUI
import UniformTypeIdentifiers
import AppKit

// ==========================================
// 2. 主界面
// ==========================================
struct LongStitchView: View {
    var isActive: Bool = true
    @State private var images: [StitchItem] = []
    @ObservedObject private var preferences = LongStitchPreferences.shared

    // 💡 记忆储存：外观主题仅保留 1:浅色, 2:深色 (默认浅色)
    @AppStorage("colorSchemeStyle") private var colorSchemeStyle: Int = 1
    @AppStorage("lastExportDir") private var lastExportDir: String = ""
    @AppStorage("longStitchPanHintSeen.v1") private var panHintSeen = false

    @State private var editingItem: StitchItem?
    @State private var hostingScrollView: NSScrollView?
    @State private var viewportCoordinateView: NSView?
    @State private var canvasCoordinateView: NSView?
    @State private var canvasScale: CGFloat = 1.0
    @State private var pendingContentAnchor: CGPoint?
    @State private var settingsViewportUpdateScheduled = false

    @State private var isPanKeyPressed = false
    @State private var isPanMouseSequenceActive = false
    @State private var panStartPoint: NSPoint?
    @State private var panStartOrigin: NSPoint?
    @State private var isRightMousePanning = false
    @State private var rightPanStartPoint: NSPoint?
    @State private var rightPanStartOrigin: NSPoint?
    @State private var isPanHintHighlighted = false
    @State private var eventMonitor: Any?
    @State private var dragCandidateID: UUID?
    @State private var dragStartLocation: NSPoint?
    @State private var draggedItemID: UUID?
    @State private var dragClickOffsetInCanvas: CGFloat = 0
    @State private var dragPointerOffset: CGSize = .zero
    @State private var dragInsertionIndex: Int?
    @State private var dragPreviewCenter: CGPoint = .zero
    @State private var dragPreviewSize: CGSize = .zero
    @State private var dragPointerLocation: NSPoint?
    @State private var dragAutoScrollTimer: Timer?
    @State private var selectedImageID: UUID?
    @State private var selectedWatermarkEdge: LongStitchEdge?
    @State private var watermarkEditorRequestID: UUID?
    @State private var watermarkFrames: [LongStitchEdge: CGRect] = [:]
    @State private var watermarkDrag: LongStitchWatermarkDrag?
    @State private var photoFrames: [UUID: CGRect] = [:]
    @State private var toolbarFrameInViewport = CGRect.zero
    @State private var selectedToolbarSize = CGSize(width: 80, height: 34)

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
                LongStitchSidebar(preferences: preferences,
                                  selectedWatermarkEdge: $selectedWatermarkEdge,
                                  canvasLayout: images.isEmpty ? nil : canvasLayout,
                                  onLocateWatermark: locateWatermark,
                                  watermarkEditorRequestID: watermarkEditorRequestID)
                    .frame(maxHeight: .infinity)
                Divider()
                EditorActionBar(isExporting: isExporting, disabled: images.isEmpty,
                                clear: clearCanvas, export: exportFinalImage,
                                settings: { showingExportSettings = true })
                    .popover(isPresented: $showingExportSettings) {
                        LongStitchExportSettingsView(preferences: preferences, outputSize: outputSizeDescription)
                    }
            }
            .frame(width: EditorStyle.sidebarWidth)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                EditorToolbar {
                    Text("\(images.count) 张照片").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(canvasInteractionHint)
                        .font(.caption.weight(isPanHintHighlighted ? .semibold : .regular))
                        .foregroundStyle(isPanHintHighlighted ? Color.accentColor : Color.secondary)
                        .animation(.easeInOut(duration: 0.25), value: isPanHintHighlighted)
                        .help(canvasInteractionHelp)
                        .task(id: images.isEmpty) {
                            guard !images.isEmpty, !panHintSeen else { return }
                            panHintSeen = true
                            isPanHintHighlighted = true
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled else { return }
                            isPanHintHighlighted = false
                        }
                    Button(action: fitToScreen) { Label("适合窗口", systemImage: "viewfinder") }.help("适合窗口")
                    Text(canvasScale < 0.01 ? String(format: "%.1f%%", canvasScale * 100) : "\(Int(canvasScale * 100))%").font(.callout.monospacedDigit()).frame(width: 48)
                }
                Divider()
                GeometryReader { viewport in
                    let entries = canvasEntries
                    let layout = canvasLayout
                    ZStack(alignment: .topLeading) {
                        Color(NSColor.controlBackgroundColor)
                        LongStitchViewport(canvasSize: layout.canvasSize,
                                           scrollView: $hostingScrollView,
                                           scale: $canvasScale,
                                           onViewportChange: refreshCanvasGeometry) {
                            ZStack {
                                if !images.isEmpty {
                                    stitchCanvas(entries: entries, layout: layout)
                                        .animation(.easeOut(duration: 0.14), value: dragInsertionIndex)
                                }
                            }
                        }
                        if images.isEmpty {
                            EditorEmptyState()
                                .frame(width: viewport.size.width, height: viewport.size.height)
                        }

                        if draggedItemID == nil,
                           let item = images.first(where: { $0.id == selectedImageID }),
                           let frame = photoFrames[item.id],
                           frame.intersects(CGRect(origin: .zero, size: viewport.size)) {
                            selectedImageToolbar(item)
                                .fixedSize()
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear
                                            .preference(key: SelectedImageToolbarSizePreferenceKey.self,
                                                        value: geometry.size)
                                            .preference(key: LongStitchToolbarFramePreferenceKey.self,
                                                        value: geometry.frame(in: .named("long-stitch-viewport")))
                                    }
                                }
                                .position(SelectedImageToolbarPlacement.position(
                                    for: frame,
                                    in: viewport.size,
                                    toolbarSize: selectedToolbarSize
                                ))
                        }

                        if let edge = selectedWatermarkEdge,
                           let frame = watermarkFrames[edge],
                           frame.intersects(CGRect(origin: .zero, size: viewport.size)) {
                            LongStitchWatermarkSelection(rect: frame)
                        }

                        if let draggedItemID,
                           let item = images.first(where: { $0.id == draggedItemID }),
                           dragPreviewSize.width > 0 {
                            dragPreview(item)
                                .frame(width: dragPreviewSize.width, height: dragPreviewSize.height)
                                .position(dragPreviewCenter)
                                .zIndex(10)
                                .allowsHitTesting(false)
                                .transaction { $0.animation = nil }
                        }
                    }
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .clipped()
                    .coordinateSpace(name: "long-stitch-viewport")
                    .background { LongStitchViewportReader(view: $viewportCoordinateView) }
                    .onPreferenceChange(LongStitchToolbarFramePreferenceKey.self) { toolbarFrameInViewport = $0 }
                    .onPreferenceChange(SelectedImageToolbarSizePreferenceKey.self) { size in
                        if size.width > 0, size.height > 0 { selectedToolbarSize = size }
                    }
                    .onChange(of: viewport.size) { _, _ in refreshCanvasGeometry() }
                    .onChange(of: canvasCoordinateView) { _, _ in refreshCanvasGeometry() }
                    .onChange(of: viewportCoordinateView) { _, _ in refreshCanvasGeometry() }
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            finishCanvasDrag()
            finishWatermarkDrag()
            finishRightMousePan()
            setPanKeyPressed(false)
            isPanMouseSequenceActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === hostingScrollView?.window else { return }
            finishCanvasDrag()
            finishWatermarkDrag()
            finishRightMousePan()
            setPanKeyPressed(false)
            isPanMouseSequenceActive = false
        }
        .onReceive(preferences.$settings) { next in
            captureContentAnchor(before: next)
        }
        .onChange(of: preferences.settings) { old, new in
            let aspects = images.map(\.displayAspect)
            let oldLayout = LongStitchLayout(aspects: aspects, settings: old)
            let newLayout = LongStitchLayout(aspects: aspects, settings: new)
            let layoutChanged = oldLayout.photoRects != newLayout.photoRects || oldLayout.canvasSize != newLayout.canvasSize
            if layoutChanged, dragCandidateID != nil { finishCanvasDrag() }
            if layoutChanged { finishWatermarkDrag() }
            if let edge = selectedWatermarkEdge,
               (!new[edge].isEnabled || !new[edge].usesWatermark || new[edge].watermarkID == nil || new[edge].size <= 0) {
                selectedWatermarkEdge = nil
                finishWatermarkDrag()
            }
            if old.panKey != new.panKey { setPanKeyPressed(false) }
            if !new.keyboardPanEnabled { setPanKeyPressed(false) }
            if !new.rightMousePanEnabled { finishRightMousePan() }
            if old.direction != new.direction ||
                (new.validatedExportShortEdge != nil && old.validatedExportShortEdge != new.validatedExportShortEdge) {
                finishCanvasDrag()
                setPanKeyPressed(false)
                pendingContentAnchor = nil
                DispatchQueue.main.async { fitToScreen() }
                return
            }
            guard layoutChanged, !settingsViewportUpdateScheduled else { return }
            settingsViewportUpdateScheduled = true
            DispatchQueue.main.async {
                settingsViewportUpdateScheduled = false
                restoreContentAnchor()
            }
        }
        .onChange(of: selectedWatermarkEdge) { _, new in
            if let drag = watermarkDrag, drag.edge != new { finishWatermarkDrag() }
            if new != nil {
                selectedImageID = nil
                toolbarFrameInViewport = .zero
            }
        }
        .onChange(of: editingItem?.id) { _, new in
            if new != nil {
                finishCanvasDrag()
                finishWatermarkDrag()
                finishRightMousePan()
                setPanKeyPressed(false)
                isPanMouseSequenceActive = false
            }
        }
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

    private var canvasEntries: [LongStitchCanvasEntry] {
        guard let draggedItemID,
              let item = images.first(where: { $0.id == draggedItemID }),
              let dragInsertionIndex else {
            return images.map { LongStitchCanvasEntry(item: $0, isPlaceholder: false) }
        }
        var entries = images.filter { $0.id != draggedItemID }
            .map { LongStitchCanvasEntry(item: $0, isPlaceholder: false) }
        entries.insert(LongStitchCanvasEntry(item: item, isPlaceholder: true),
                       at: min(max(0, dragInsertionIndex), entries.count))
        return entries
    }

    private var settings: LongStitchSettings { preferences.settings.sanitized() }

    private var canvasInteractionHint: String {
        var actions = [settings.wheelMode == .zoom ? "滚轮缩放" : "滚动平移 · \(settings.zoomModifier.title)+滚轮缩放"]
        switch settings.panMode {
        case .rightMouse: actions.append("右键拖动平移")
        case .keyboard: actions.append("\(settings.panKey.title)+左键拖动平移")
        }
        return actions.joined(separator: " · ")
    }

    private var canvasInteractionHelp: String {
        "\(canvasInteractionHint)。可在软件设置 → 长图拼接中更改；触控板双指捏合可缩放。"
    }

    private var canvasLayout: LongStitchLayout {
        LongStitchLayout(aspects: canvasEntries.map { $0.item.displayAspect }, settings: settings)
    }

    private var outputSizeDescription: String {
        guard !images.isEmpty else { return "" }
        let size = canvasLayout.canvasSize
        return "最终尺寸（含留白）：\(Int(ceil(size.width))) × \(Int(ceil(size.height))) px"
    }

    private func axisCoordinate(_ point: CGPoint) -> CGFloat {
        settings.direction.isVertical ? point.y : point.x
    }

    private func axisLength(_ size: CGSize) -> CGFloat {
        settings.direction.isVertical ? size.height : size.width
    }

    private func stitchCanvas(entries: [LongStitchCanvasEntry], layout: LongStitchLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let rect = layout.photoRects[index]
                canvasEntryView(entry, size: rect.size)
                    .position(x: rect.midX, y: rect.midY)
            }
            ForEach(LongStitchEdge.allCases) { edge in
                if settings[edge].isEnabled, settings[edge].usesWatermark,
                   let watermark = preferences.watermark(for: edge),
                   let region = layout.marginRects[edge], region.width > 0, region.height > 0 {
                    let rect = LongStitchLayout.watermarkRect(
                        imageSize: watermark.size, in: region,
                        contentShortEdge: min(layout.contentRect.width, layout.contentRect.height),
                        margin: settings[edge]
                    )
                    Image(nsImage: watermark).resizable().scaledToFit()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
        .clipped()
        .overlay { Rectangle().stroke(Color.black.opacity(0.12), lineWidth: 1 / max(0.001, canvasScale)) }
        .shadow(color: .black.opacity(0.14), radius: 13, y: 5)
        .background { LongStitchViewportReader(view: $canvasCoordinateView) }
    }

    @ViewBuilder private func canvasEntryView(_ entry: LongStitchCanvasEntry, size: CGSize) -> some View {
        if entry.isPlaceholder {
            Rectangle()
                .fill(Color.accentColor.opacity(0.08))
                .overlay {
                    Rectangle().strokeBorder(Color.accentColor.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2 / max(0.001, canvasScale),
                                           dash: [8 / max(0.001, canvasScale)]))
                }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        } else {
            ZStack {
                Image(nsImage: entry.item.displayImage).resizable().scaledToFit()
                if selectedImageID == entry.id {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2 / max(0.001, canvasScale))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        }
    }

    private func dragPreview(_ item: StitchItem) -> some View {
        Image(nsImage: item.displayImage)
            .resizable()
            .scaledToFit()
            .opacity(0.96)
            .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) }
            .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
    }

    private func selectedImageToolbar(_ item: StitchItem) -> some View {
        HStack(spacing: 7) {
            Button { editingItem = item } label: { Image(systemName: "crop") }
                .accessibilityLabel("裁剪与水印")
                .help("编辑这张照片的裁剪和水印")
            Button { replacePhoto(item) } label: { Image(systemName: "photo.badge.arrow.down") }
                .accessibilityLabel("替换照片")
                .help("替换这张照片")
            Button(role: .destructive) { removePhoto(item) } label: { Image(systemName: "trash") }
                .accessibilityLabel("删除照片")
                .help("删除这张照片")
        }
        .modifier(SelectedImageToolbarChrome())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("所选照片快捷操作")
    }

    private func clearCanvas() {
        finishCanvasDrag()
        finishWatermarkDrag()
        selectedWatermarkEdge = nil
        watermarkFrames = [:]
        images.removeAll()
        selectedImageID = nil
        photoFrames = [:]
        toolbarFrameInViewport = .zero
        hostingScrollView?.magnification = 1
    }

    private func finishCanvasDrag(commit: Bool = false) {
        stopDragAutoScroll()
        // The real order changes only on release. The preview already reserves this exact slot.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if commit, let draggedItemID,
               let from = images.firstIndex(where: { $0.id == draggedItemID }),
               let insertionIndex = dragInsertionIndex {
                let target = min(max(0, insertionIndex), images.count - 1)
                if from != target {
                    let item = images.remove(at: from)
                    images.insert(item, at: target)
                }
            }
            dragCandidateID = nil
            dragStartLocation = nil
            draggedItemID = nil
            dragInsertionIndex = nil
            dragClickOffsetInCanvas = 0
            dragPointerOffset = .zero
            dragPreviewSize = .zero
            dragPointerLocation = nil
        }
    }

    private func removePhoto(_ item: StitchItem) {
        finishCanvasDrag()
        images.removeAll { $0.id == item.id }
        if selectedImageID == item.id { selectedImageID = nil }
    }

    private func replacePhoto(_ item: StitchItem) {
        guard editingItem == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.directoryURL = item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            let image = NSImage(contentsOf: url)
            DispatchQueue.main.async {
                if accessing { url.stopAccessingSecurityScopedResource() }
                guard let image, let index = images.firstIndex(where: { $0.id == item.id }) else { return }
                let replacement = StitchItem(url: url, image: image)
                withAnimation { images[index] = replacement }
                selectedImageID = replacement.id
            }
        }
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
        guard editingItem == nil, draggedItemID == nil, watermarkDrag == nil,
              !images.isEmpty, let scrollView = hostingScrollView else { return }
        let size = canvasLayout.canvasSize
        let target = min(1, max(0.001, min((scrollView.contentSize.width - 48) / size.width,
                                          (scrollView.contentSize.height - 48) / size.height)))
        if let docRect = scrollView.documentView?.bounds {
            LongStitchViewportNavigation.setScale(target, in: scrollView,
                                                  anchor: CGPoint(x: docRect.midX, y: docRect.midY))
        }
    }

    private func locateWatermark(_ edge: LongStitchEdge) {
        guard let scrollView = hostingScrollView, let document = scrollView.documentView,
              let canvasCoordinateView, let geometry = watermarkGeometry(for: edge) else { return }
        finishCanvasDrag()
        finishWatermarkDrag()
        selectedWatermarkEdge = edge
        selectedImageID = nil
        // A deliberate focus action fits the logo with enough context to manipulate its handles.
        let rect = geometry.rect
        let target = min(4, max(0.001, min((scrollView.contentSize.width - 120) / max(1, rect.width),
                                          (scrollView.contentSize.height - 120) / max(1, rect.height))))
        let anchor = canvasCoordinateView.convert(CGPoint(x: rect.midX, y: rect.midY), to: document)
        LongStitchViewportNavigation.setScale(target, in: scrollView, anchor: anchor)
        refreshCanvasGeometry()
    }

    private func watermarkGeometry(for edge: LongStitchEdge) -> (rect: CGRect, region: CGRect, imageSize: CGSize)? {
        let margin = settings[edge]
        let layout = canvasLayout
        guard !images.isEmpty, margin.isEnabled, margin.usesWatermark,
              let image = preferences.watermark(for: edge),
              let region = layout.marginRects[edge], region.width > 0, region.height > 0 else { return nil }
        let rect = LongStitchLayout.watermarkRect(imageSize: image.size, in: region,
            contentShortEdge: min(layout.contentRect.width, layout.contentRect.height), margin: margin)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return (rect, region, image.size)
    }

    private func beginWatermarkDrag(edge: LongStitchEdge, corner: LongStitchWatermarkCorner?,
                                    event: NSEvent) {
        guard let canvasCoordinateView, let geometry = watermarkGeometry(for: edge) else { return }
        finishCanvasDrag()
        selectedImageID = nil
        selectedWatermarkEdge = edge
        watermarkEditorRequestID = UUID()
        toolbarFrameInViewport = .zero
        watermarkDrag = LongStitchWatermarkDrag(edge: edge, corner: corner,
            originalMargin: settings[edge], startRect: geometry.rect, region: geometry.region,
            imageSize: geometry.imageSize,
            startPoint: canvasCoordinateView.convert(event.locationInWindow, from: nil))
        NSCursor.closedHand.set()
    }

    private func updateWatermarkDrag(atWindowPoint point: CGPoint) {
        guard var drag = watermarkDrag, let canvasCoordinateView,
              preferences.settings[drag.edge].watermarkID == drag.originalMargin.watermarkID else { return }
        let current = canvasCoordinateView.convert(point, from: nil)
        if !drag.hasMoved {
            let distance = hypot(current.x - drag.startPoint.x, current.y - drag.startPoint.y)
                * (hostingScrollView?.magnification ?? 1)
            guard distance >= 2 else { return }
            drag.hasMoved = true
            watermarkDrag = drag
        }
        let rect: CGRect
        if let corner = drag.corner {
            rect = LongStitchWatermarkGeometry.resizedRect(from: drag.startRect, corner: corner,
                startPoint: drag.startPoint, currentPoint: current, in: drag.region)
        } else {
            rect = LongStitchWatermarkGeometry.movedRect(from: drag.startRect,
                startPoint: drag.startPoint, currentPoint: current, in: drag.region)
        }
        let values = LongStitchWatermarkGeometry.parameters(for: rect, imageSize: drag.imageSize, in: drag.region)
        var next = preferences.settings
        next[drag.edge].watermarkScale = values.scale
        next[drag.edge].offsetX = drag.region.width - rect.width > 0.000_001
            ? values.offsetX : drag.originalMargin.offsetX
        next[drag.edge].offsetY = drag.region.height - rect.height > 0.000_001
            ? values.offsetY : drag.originalMargin.offsetY
        if next != preferences.settings { preferences.settings = next }
        refreshCanvasGeometry()
    }

    private func finishWatermarkDrag(cancelled: Bool = false) {
        guard let drag = watermarkDrag else { return }
        if cancelled, preferences.settings[drag.edge].watermarkID == drag.originalMargin.watermarkID {
            var next = preferences.settings
            next[drag.edge] = drag.originalMargin
            preferences.settings = next
        }
        watermarkDrag = nil
        NSCursor.arrow.set()
    }

    /// Published settings arrive before assignment, while the native view tree
    /// still represents the old layout. Capture once for a coalesced update.
    private func captureContentAnchor(before next: LongStitchSettings) {
        guard pendingContentAnchor == nil, !images.isEmpty,
              let canvasCoordinateView, let scrollView = hostingScrollView,
              canvasCoordinateView.window === scrollView.window else { return }
        let current = preferences.settings
        guard current.direction == next.direction,
              current.validatedExportShortEdge == next.validatedExportShortEdge else { return }
        let aspects = images.map(\.displayAspect)
        let oldLayout = LongStitchLayout(aspects: aspects, settings: current)
        let nextLayout = LongStitchLayout(aspects: aspects, settings: next)
        guard oldLayout.photoRects != nextLayout.photoRects || oldLayout.canvasSize != nextLayout.canvasSize else { return }
        let clip = scrollView.contentView
        let center = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        let anchor = canvasCoordinateView.convert(center, from: clip)
        pendingContentAnchor = CGPoint(x: anchor.x - oldLayout.contentRect.minX,
                                       y: anchor.y - oldLayout.contentRect.minY)
    }

    private func restoreContentAnchor() {
        defer { pendingContentAnchor = nil }
        guard let anchor = pendingContentAnchor,
              let scrollView = hostingScrollView, let canvasCoordinateView else { return }
        scrollView.layoutSubtreeIfNeeded()
        let origin = canvasLayout.contentRect.origin
        let point = canvasCoordinateView.convert(NSPoint(x: origin.x + anchor.x, y: origin.y + anchor.y),
                                                to: scrollView.contentView)
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.x += point.x - bounds.midX
        bounds.origin.y += point.y - bounds.midY
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        refreshCanvasGeometry()
    }

    private func exportFinalImage() {
        guard editingItem == nil, !images.isEmpty, !isExporting else { return }
        guard AppPreferences.exportWidth(settings.exportShortEdge) != nil else {
            exportSucceeded = false; exportAlertTitle = "导出设置有误"
            exportAlertMessage = "短边像素需为 1 到 16384 的整数，不包含四边留白。"
            showingExportAlert = true; return
        }
        finishCanvasDrag()
        let snapshot = settings
        let safeImages = images.map(\.displayImage)
        let layout = canvasLayout
        var watermarks: [LongStitchEdge: NSImage] = [:]
        for edge in LongStitchEdge.allCases where snapshot[edge].isEnabled && snapshot[edge].usesWatermark && snapshot[edge].watermarkID != nil {
            guard let watermark = preferences.watermark(for: edge) else {
                exportSucceeded = false; exportAlertTitle = "水印无法读取"
                exportAlertMessage = "请重新选择\(edge.title)水印，或取消该边水印后再导出。"
                showingExportAlert = true
                return
            }
            watermarks[edge] = watermark
        }
        let watermarkSnapshot = watermarks
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [snapshot.exportPNG ? .png : .jpeg]
        savePanel.nameFieldStringValue = snapshot.exportPNG ? "aoipic_Output.png" : "aoipic_Output.jpg"
        if !lastExportDir.isEmpty { savePanel.directoryURL = URL(fileURLWithPath: lastExportDir) }
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            isExporting = true
            lastExportDir = url.deletingLastPathComponent().path
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<Void, Error> = Result {
                    try autoreleasepool {
                        let image = try LongStitchRenderer.render(images: safeImages, layout: layout,
                                                                 settings: snapshot, watermarks: watermarkSnapshot)
                        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let data = NSBitmapImageRep(cgImage: cgImage).representation(
                                using: snapshot.exportPNG ? .png : .jpeg,
                                properties: [.compressionFactor: 0.95]) else {
                            throw NSError(domain: "aoipic", code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "无法编码导出图片。"])
                        }
                        try data.write(to: url, options: .atomic)
                    }
                }
                DispatchQueue.main.async {
                    isExporting = false
                    switch result {
                    case .success:
                        exportSucceeded = true; exportAlertTitle = "导出成功"
                        exportAlertMessage = "图片已保存：\(url.lastPathComponent)"
                    case .failure(let error):
                        exportSucceeded = false; exportAlertTitle = "导出失败"
                        exportAlertMessage = error.localizedDescription
                    }
                    showingExportAlert = true
                }
            }
        }
    }

    private func refreshCanvasGeometry() {
        guard let canvasCoordinateView, let viewportCoordinateView,
              canvasCoordinateView.window != nil,
              canvasCoordinateView.window === viewportCoordinateView.window else { return }
        var frames: [UUID: CGRect] = [:]
        let entries = canvasEntries
        let layout = canvasLayout
        if !images.isEmpty { preferences.resolveWatermarkScales(in: layout) }
        for (index, entry) in entries.enumerated() where !entry.isPlaceholder {
            frames[entry.id] = canvasCoordinateView.convert(layout.photoRects[index], to: viewportCoordinateView)
        }
        if photoFrames != frames { photoFrames = frames }
        var nextWatermarkFrames: [LongStitchEdge: CGRect] = [:]
        for edge in LongStitchEdge.allCases {
            if let geometry = watermarkGeometry(for: edge) {
                nextWatermarkFrames[edge] = canvasCoordinateView.convert(geometry.rect, to: viewportCoordinateView)
            }
        }
        if watermarkFrames != nextWatermarkFrames { watermarkFrames = nextWatermarkFrames }
        if draggedItemID != nil, let dragPointerLocation {
            updateCanvasDrag(atWindowPoint: dragPointerLocation)
        }
    }

    private func setupEventMonitor() {
        guard eventMonitor == nil else { return }
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .keyDown, .keyUp, .flagsChanged, .magnify]) { event in
            handleCanvasEvent(event)
        }
    }

    private func handleCanvasEvent(_ event: NSEvent) -> NSEvent? {
        let isKeyboardEvent = [.keyDown, .keyUp, .flagsChanged].contains(event.type)
        guard isActive, editingItem == nil,
              let scrollView = hostingScrollView, let window = scrollView.window,
              event.window === window || (isKeyboardEvent && event.window == nil && window.isKeyWindow)
        else { return event }
        // Key events do not contain a reliable mouse location. Hit-testing their
        // locationInWindow (often zero) prevented Space from arming canvas panning.
        let pointerLocation = isKeyboardEvent ? window.mouseLocationOutsideOfEventStream : event.locationInWindow
        let pointerInClip = scrollView.contentView.convert(pointerLocation, from: nil)
        let pointerIsInCanvas = scrollView.contentView.bounds.contains(pointerInClip)
        let isTextInput = window.firstResponder is NSTextView || window.firstResponder is NSTextField
        if isKeyboardEvent, isTextInput {
            setPanKeyPressed(false)
            return event
        }
        if event.type == .keyDown, event.keyCode == 53, !isTextInput,
           watermarkDrag != nil || selectedWatermarkEdge != nil {
            if watermarkDrag != nil { finishWatermarkDrag(cancelled: true) }
            else { selectedWatermarkEdge = nil }
            return nil
        }
        if event.type == .keyDown, event.keyCode == 53, dragCandidateID != nil {
            finishCanvasDrag()
            return nil
        }
        if event.type == .keyUp, event.keyCode == settings.panKey.keyCode, isPanKeyPressed {
            setPanKeyPressed(false)
            return nil
        }
        if event.type == .flagsChanged, settings.panKey.keyCode == nil {
            let pressed = event.modifierFlags.contains(settings.panKey.modifierFlags)
            if !settings.keyboardPanEnabled { setPanKeyPressed(false); return event }
            if !pressed || (pointerIsInCanvas && watermarkDrag == nil && dragCandidateID == nil && !isRightMousePanning) {
                setPanKeyPressed(pressed)
            }
            return event
        }
        if event.type == .keyDown, settings.keyboardPanEnabled, !isTextInput,
           event.keyCode == settings.panKey.keyCode, pointerIsInCanvas || isPanKeyPressed {
            // Consume repeats as well: passing repeated Space to AppKit causes the alert sound.
            if watermarkDrag == nil && dragCandidateID == nil && !isRightMousePanning { setPanKeyPressed(true) }
            return nil
        }
        // Releasing the key stops panning immediately, but the mouse sequence
        // still belongs to us until mouse-up because its mouse-down was consumed.
        if isPanMouseSequenceActive {
            if event.type == .leftMouseDragged, isPanKeyPressed,
               let viewportCoordinateView, let panStartPoint, let panStartOrigin {
                let clipView = scrollView.contentView
                let start = clipView.convert(panStartPoint, from: viewportCoordinateView)
                let current = clipView.convert(event.locationInWindow, from: nil)
                var bounds = clipView.bounds
                bounds.origin = NSPoint(x: panStartOrigin.x + start.x - current.x,
                                        y: panStartOrigin.y + start.y - current.y)
                clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
                scrollView.reflectScrolledClipView(clipView)
                return nil
            }
            if event.type == .leftMouseDragged { return nil }
            if event.type == .leftMouseUp {
                isPanMouseSequenceActive = false
                panStartPoint = nil
                panStartOrigin = nil
                if isPanKeyPressed { NSCursor.openHand.set() }
                return nil
            }
            if event.type == .leftMouseDown {
                isPanMouseSequenceActive = false
                panStartPoint = nil
                panStartOrigin = nil
            }
        }
        if [.leftMouseDown, .rightMouseDown, .scrollWheel, .magnify].contains(event.type), !pointerIsInCanvas {
            if event.type == .leftMouseDown || event.type == .rightMouseDown { setPanKeyPressed(false) }
            return event
        }

        if event.type == .rightMouseDown, settings.rightMousePanEnabled,
           let viewportCoordinateView {
            finishCanvasDrag()
            finishWatermarkDrag()
            setPanKeyPressed(false)
            isRightMousePanning = true
            window.makeFirstResponder(scrollView.documentView)
            rightPanStartPoint = viewportCoordinateView.convert(event.locationInWindow, from: nil)
            rightPanStartOrigin = scrollView.contentView.bounds.origin
            NSCursor.closedHand.set()
            return nil
        }
        if isRightMousePanning, let viewportCoordinateView {
            if event.type == .rightMouseDragged,
               let rightPanStartPoint, let rightPanStartOrigin {
                let clip = scrollView.contentView
                let start = clip.convert(rightPanStartPoint, from: viewportCoordinateView)
                let current = clip.convert(viewportCoordinateView.convert(event.locationInWindow, from: nil),
                                           from: viewportCoordinateView)
                var bounds = clip.bounds
                bounds.origin = CGPoint(x: rightPanStartOrigin.x + start.x - current.x,
                                        y: rightPanStartOrigin.y + start.y - current.y)
                clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                scrollView.reflectScrolledClipView(clip)
                return nil
            }
            if event.type == .rightMouseUp {
                finishRightMousePan()
                return nil
            }
        }

        let modifierZoom = event.modifierFlags.contains(settings.zoomModifier.flags)
        // Precise scrolling is the native two-finger pan gesture. A modifier can
        // still request zoom; ordinary mouse wheel notches zoom by default.
        let wheelZoom = modifierZoom || (settings.wheelMode == .zoom && !event.hasPreciseScrollingDeltas)
        if event.type == .magnify || (event.type == .scrollWheel && wheelZoom) {
            guard dragCandidateID == nil, watermarkDrag == nil, panStartPoint == nil else { return nil }
            let factor: CGFloat
            if event.type == .magnify {
                factor = exp(event.magnification)
            } else {
                // Bound unusually large wheel events while keeping the response proportional.
                let unit: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.06
                let delta = max(-0.22, min(0.22, event.scrollingDeltaY * unit * settings.zoomSensitivity))
                factor = exp(delta)
            }
            LongStitchViewportNavigation.zoom(factor, in: scrollView, atWindowPoint: event.locationInWindow)
            return nil
        }

        if watermarkDrag != nil {
            if event.type == .leftMouseDragged {
                updateWatermarkDrag(atWindowPoint: event.locationInWindow)
                return nil
            }
            if event.type == .leftMouseUp {
                updateWatermarkDrag(atWindowPoint: event.locationInWindow)
                finishWatermarkDrag()
                return nil
            }
            if event.type == .scrollWheel { return nil }
        }

        if event.type == .leftMouseDown, settings.keyboardPanEnabled, settings.panKey.keyCode == nil {
            setPanKeyPressed(event.modifierFlags.contains(settings.panKey.modifierFlags))
        }
        if event.type == .leftMouseDown, isPanKeyPressed, let viewportCoordinateView {
            let point = viewportCoordinateView.convert(event.locationInWindow, from: nil)
            let clipView = scrollView.contentView
            window.makeFirstResponder(scrollView.documentView)
            isPanMouseSequenceActive = true
            panStartPoint = point
            panStartOrigin = clipView.bounds.origin
            NSCursor.closedHand.set()
            return nil
        }

        if event.type == .leftMouseDown {
            guard let canvasCoordinateView, let viewportCoordinateView,
                  canvasCoordinateView.window === window else { return event }
            let viewportPoint = viewportCoordinateView.convert(event.locationInWindow, from: nil)
            if selectedImageID != nil, toolbarFrameInViewport.contains(viewportPoint) { return event }
            finishCanvasDrag()
            window.makeFirstResponder(scrollView.documentView)
            let click = canvasCoordinateView.convert(event.locationInWindow, from: nil)
            let layout = canvasLayout
            if let edge = selectedWatermarkEdge, let geometry = watermarkGeometry(for: edge) {
                let frame = canvasCoordinateView.convert(geometry.rect, to: viewportCoordinateView)
                if let corner = LongStitchWatermarkGeometry.handle(at: viewportPoint, in: frame) {
                    beginWatermarkDrag(edge: edge, corner: corner, event: event)
                    return nil
                }
            }
            for edge in LongStitchEdge.allCases.reversed() {
                if let geometry = watermarkGeometry(for: edge), geometry.rect.contains(click) {
                    beginWatermarkDrag(edge: edge, corner: nil, event: event)
                    return nil
                }
            }
            selectedWatermarkEdge = nil
            for (index, item) in images.enumerated() {
                let rect = layout.photoRects[index]
                if rect.contains(click) {
                    let viewportRect = canvasCoordinateView.convert(rect, to: viewportCoordinateView)
                    selectedImageID = item.id
                    dragCandidateID = item.id
                    dragStartLocation = event.locationInWindow
                    dragClickOffsetInCanvas = axisCoordinate(click) - axisCoordinate(CGPoint(x: rect.midX, y: rect.midY))
                    dragPointerOffset = CGSize(width: viewportPoint.x - viewportRect.midX,
                                               height: viewportPoint.y - viewportRect.midY)
                    dragPreviewSize = viewportRect.size
                    dragPreviewCenter = CGPoint(x: viewportRect.midX, y: viewportRect.midY)
                    return nil
                }
            }
            selectedImageID = nil
            toolbarFrameInViewport = .zero
        }

        if event.type == .leftMouseDragged, let candidateID = dragCandidateID {
            if draggedItemID == nil, let start = dragStartLocation {
                let distance = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
                guard distance >= 6,
                      let index = images.firstIndex(where: { $0.id == candidateID }) else { return nil }
                dragInsertionIndex = index
                draggedItemID = candidateID
                toolbarFrameInViewport = .zero
                startDragAutoScroll()
            }
            updateCanvasDrag(atWindowPoint: event.locationInWindow)
            return nil
        }

        if event.type == .leftMouseUp, dragCandidateID != nil {
            if draggedItemID != nil { updateCanvasDrag(atWindowPoint: event.locationInWindow) }
            finishCanvasDrag(commit: true)
            return nil
        }
        return event
    }

    private func updateCanvasDrag(atWindowPoint point: NSPoint) {
        guard let canvasCoordinateView, let viewportCoordinateView,
              let draggedItemID,
              let item = images.first(where: { $0.id == draggedItemID }),
              let currentIndex = dragInsertionIndex else { return }
        if dragPointerLocation != point { dragPointerLocation = point }
        let viewportPoint = viewportCoordinateView.convert(point, from: nil)
        let center = CGPoint(x: viewportPoint.x - dragPointerOffset.width,
                             y: viewportPoint.y - dragPointerOffset.height)
        if dragPreviewCenter != center { dragPreviewCenter = center }

        // Use fixed insertion-slot centers, independent of placeholder animation.
        let layout = LongStitchLayout(aspects: images.map(\.displayAspect), settings: settings)
        guard let sourceIndex = images.firstIndex(where: { $0.id == item.id }) else { return }
        let origin = settings.direction.isVertical ? layout.contentRect.minY : layout.contentRect.minX
        let visualCenter = axisCoordinate(canvasCoordinateView.convert(point, from: nil)) - dragClickOffsetInCanvas
        var centers: [CGFloat] = [origin + axisLength(layout.photoRects[sourceIndex].size) / 2]
        for (index, other) in images.enumerated() where other.id != draggedItemID {
            centers.append(centers.last! + axisLength(layout.photoRects[index].size) + CGFloat(settings.spacing))
        }
        var index = currentIndex
        let hysteresis = 8 / max(0.001, hostingScrollView?.magnification ?? 1)
        while index > 0 {
            let distance = centers[index] - centers[index - 1]
            let threshold = (centers[index - 1] + centers[index]) / 2 - min(hysteresis, distance * 0.2)
            guard visualCenter < threshold else { break }
            index -= 1
        }
        while index + 1 < centers.count {
            let distance = centers[index + 1] - centers[index]
            let threshold = (centers[index] + centers[index + 1]) / 2 + min(hysteresis, distance * 0.2)
            guard visualCenter > threshold else { break }
            index += 1
        }
        if index != currentIndex {
            withAnimation(.easeOut(duration: 0.14)) { dragInsertionIndex = index }
        }
    }

    private func startDragAutoScroll() {
        guard dragAutoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            guard self.draggedItemID != nil,
                  let point = self.dragPointerLocation,
                  let viewportCoordinateView = self.viewportCoordinateView,
                  let scrollView = self.hostingScrollView,
                  scrollView.documentView != nil else { return }
            let clipView = scrollView.contentView
            let localPoint = viewportCoordinateView.convert(point, from: nil)
            let viewport = clipView.convert(clipView.bounds, to: viewportCoordinateView)
            let vertical = self.settings.direction.isVertical
            let cross = vertical ? localPoint.x : localPoint.y
            guard cross >= (vertical ? viewport.minX : viewport.minY),
                  cross <= (vertical ? viewport.maxX : viewport.maxY) else { return }
            let position = vertical ? localPoint.y : localPoint.x
            let leadingDistance = position - (vertical ? viewport.minY : viewport.minX)
            let trailingDistance = (vertical ? viewport.maxY : viewport.maxX) - position
            let edgeSize: CGFloat = 64
            let distance: CGFloat
            let direction: CGFloat
            if leadingDistance < edgeSize {
                distance = leadingDistance; direction = -1
            } else if trailingDistance < edgeSize {
                distance = trailingDistance; direction = 1
            } else { return }

            let intensity = pow(max(0, min(1, (edgeSize - distance) / edgeSize)), 2)
            let step = direction * (1 + 17 * intensity)
            let start = clipView.convert(localPoint, from: viewportCoordinateView)
            let target = NSPoint(x: localPoint.x + (vertical ? 0 : step),
                                 y: localPoint.y + (vertical ? step : 0))
            let end = clipView.convert(target, from: viewportCoordinateView)
            var bounds = clipView.bounds
            bounds.origin.x += end.x - start.x
            bounds.origin.y += end.y - start.y
            let constrained = clipView.constrainBoundsRect(bounds)
            guard abs(constrained.minY - clipView.bounds.minY) > 0.01 ||
                  abs(constrained.minX - clipView.bounds.minX) > 0.01 else { return }
            clipView.scroll(to: constrained.origin)
            scrollView.reflectScrolledClipView(clipView)
            self.updateCanvasDrag(atWindowPoint: point)
        }
        RunLoop.main.add(timer, forMode: .common)
        dragAutoScrollTimer = timer
    }

    private func stopDragAutoScroll() {
        dragAutoScrollTimer?.invalidate()
        dragAutoScrollTimer = nil
    }

    private func setPanKeyPressed(_ pressed: Bool) {
        guard settings.keyboardPanEnabled || !pressed else { return }
        if !pressed {
            panStartPoint = nil
            panStartOrigin = nil
        }
        guard pressed != isPanKeyPressed else { return }
        if pressed {
            finishCanvasDrag()
            finishWatermarkDrag()
            NSCursor.openHand.push()
        } else {
            NSCursor.pop()
        }
        isPanKeyPressed = pressed
    }

    private func finishRightMousePan() {
        guard isRightMousePanning else { return }
        isRightMousePanning = false
        rightPanStartPoint = nil
        rightPanStartOrigin = nil
        NSCursor.arrow.set()
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        eventMonitor = nil
        finishCanvasDrag()
        finishWatermarkDrag()
        finishRightMousePan()
        setPanKeyPressed(false)
        isPanMouseSequenceActive = false
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

private struct LongStitchCanvasEntry: Identifiable {
    let item: StitchItem
    let isPlaceholder: Bool
    var id: UUID { item.id }
}

private struct LongStitchToolbarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct LongStitchViewportReader: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let coordinateView = LongStitchCoordinateNSView()
        DispatchQueue.main.async { view = coordinateView }
        return coordinateView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if view !== nsView { DispatchQueue.main.async { view = nsView } }
    }
}

private final class LongStitchCoordinateNSView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct LongStitchWatermarkDrag {
    let edge: LongStitchEdge
    let corner: LongStitchWatermarkCorner?
    let originalMargin: LongStitchMargin
    let startRect: CGRect
    let region: CGRect
    let imageSize: CGSize
    let startPoint: CGPoint
    var hasMoved = false
}
