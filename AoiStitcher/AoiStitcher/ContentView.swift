import SwiftUI
import UniformTypeIdentifiers
import AppKit

// ==========================================
// 0. SwiftUI 兼容性扩展
// ==========================================
extension Binding where Value == CGFloat {
    var asDouble: Binding<Double> {
        Binding<Double>(
            get: { Double(self.wrappedValue) },
            set: { self.wrappedValue = CGFloat($0) }
        )
    }
}

// ==========================================
// 1. 数据模型与基础组件
// ==========================================
struct CropInfo: Equatable {
    var uiCropRect: CGRect
    var rotation: Double
    var imageCenter: CGPoint
    var scale: CGFloat
}

struct OverlayWatermark: Identifiable, Equatable {
    let id = UUID()
    var image: NSImage
    var offset: CGSize = .zero
    var scale: CGFloat = 1.0
    var rotation: Double = 0.0
}

struct StitchItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let image: NSImage
    var cropInfo: CropInfo?
    var watermarks: [OverlayWatermark] = []
    var croppedImage: NSImage?
    var displayImage: NSImage { return croppedImage ?? image }
    
    // 💡 高性能缓存：专门为解决拖拽卡顿准备的长宽比例缓存
    var displayAspect: CGFloat {
        return displayImage.size.width / max(1, displayImage.size.height)
    }
    
    static func == (lhs: StitchItem, rhs: StitchItem) -> Bool {
        lhs.id == rhs.id && lhs.cropInfo == rhs.cropInfo && lhs.watermarks == rhs.watermarks
    }
}

enum CropRatioPreset: String, CaseIterable, Identifiable {
    case original = "原图", square = "1:1"
    case r4_3 = "4:3", r3_4 = "3:4"
    case r3_2 = "3:2", r2_3 = "2:3"
    case r16_9 = "16:9", r9_16 = "9:16"
    
    var id: String { self.rawValue }
    var ratioValue: CGFloat? {
        switch self {
        case .original: return nil
        case .square: return 1.0
        case .r4_3: return 4.0 / 3.0; case .r3_4: return 3.0 / 4.0
        case .r3_2: return 3.0 / 2.0; case .r2_3: return 2.0 / 3.0
        case .r16_9: return 16.0 / 9.0; case .r9_16: return 9.0 / 16.0
        }
    }
}

// ==========================================
// 2. 主界面
// ==========================================
struct ContentView: View {
    @State private var images: [StitchItem] = []
    @State private var spacing: CGFloat = 20.0
    @State private var bottomMargin: CGFloat = 150.0
    
    // 💡 记忆储存：外观主题仅保留 1:浅色, 2:深色 (默认浅色)
    @AppStorage("colorSchemeStyle") private var colorSchemeStyle: Int = 1
    @AppStorage("exportWidth") private var exportWidth: String = "2560"
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
    @State private var showingExportAlert = false
    @State private var exportAlertTitle = ""
    @State private var exportAlertMessage = ""

    // 强制返回指定的 ColorScheme
    var currentColorScheme: ColorScheme {
        return colorSchemeStyle == 2 ? .dark : .light
    }

    var body: some View {
        HStack(spacing: 0) {
            // ================== 左侧固定参数面板 ==================
            VStack(alignment: .leading, spacing: 0) {
                // 1. 顶部 Header 区
                VStack(spacing: 12) {
                    HStack {
                        Text("AoiStitcher").font(.title2).bold().frame(maxWidth: .infinity, alignment: .leading)
                        
                        // 💡 彻底移除自动模式，仅保留深浅切换，杜绝卡死
                        Picker("", selection: $colorSchemeStyle) {
                            Image(systemName: "sun.max.fill").tag(1)           // 浅色
                            Image(systemName: "moon.fill").tag(2)              // 深色
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 70)
                        .help("切换深浅色模式")
                    }
                    
                    HStack {
                        Button(action: importPhotos) { Label("添加照片 [A]", systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).tint(.blue)
                            .keyboardShortcut("a", modifiers: [])
                            .help("导入多张照片 (快捷键: A)")
                        
                        Button(action: fitToScreen) { Label("全局预览 [Q]", systemImage: "viewfinder").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                            .keyboardShortcut("q", modifiers: [])
                            .help("自适应屏幕大小 (快捷键: Q)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 16)
                
                Divider()
                
                // 2. 中间卡片参数区
                ScrollView {
                    VStack(spacing: 16) {
                        GroupBox("🎛️ 画布设置") {
                            VStack(spacing: 12) {
                                HStack {
                                    Text("导出宽度").foregroundColor(.secondary)
                                    Spacer()
                                    TextField("2560", text: $exportWidth).textFieldStyle(.roundedBorder).frame(width: 80)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("图片间距").foregroundColor(.secondary)
                                        Spacer()
                                        TextField("", value: $spacing.asDouble, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
                                        Text("px").font(.caption).foregroundColor(.secondary)
                                    }
                                    Slider(value: $spacing, in: 0.0...300.0)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("底部留白").foregroundColor(.secondary)
                                        Spacer()
                                        TextField("", value: $bottomMargin.asDouble, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
                                        Text("px").font(.caption).foregroundColor(.secondary)
                                    }
                                    Slider(value: $bottomMargin, in: 0.0...1000.0)
                                }
                            }.padding(.top, 8)
                        }
                        
                        GroupBox("💧 全局水印") {
                            VStack(spacing: 12) {
                                HStack {
                                    Button(action: selectGlobalWatermark) {
                                        Label(globalWatermark == nil ? "选择水印 [S]" : "更换水印 [S]", systemImage: "photo")
                                    }
                                    .buttonStyle(.bordered)
                                    .keyboardShortcut("s", modifiers: [])
                                    .help("选择或更换底部全局水印 (快捷键: S)")
                                    
                                    Spacer()
                                    if globalWatermark != nil {
                                        Button(action: { globalWatermark = nil }) {
                                            Image(systemName: "trash").foregroundColor(.red)
                                        }.buttonStyle(.plain)
                                    }
                                }
                                
                                if globalWatermark != nil {
                                    Divider()
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text("缩放比例").font(.caption).foregroundColor(.secondary); Spacer(); TextField("", value: $globalWmScale.asDouble, format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).controlSize(.mini).frame(width: 45) }
                                        Slider(value: $globalWmScale, in: 0.1...3.0)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text("水平偏移 (X)").font(.caption).foregroundColor(.secondary); Spacer(); TextField("", value: $globalWmOffsetX.asDouble, format: .number).textFieldStyle(.roundedBorder).controlSize(.mini).frame(width: 45) }
                                        Slider(value: $globalWmOffsetX, in: -1000.0...1000.0)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text("垂直偏移 (Y)").font(.caption).foregroundColor(.secondary); Spacer(); TextField("", value: $globalWmOffsetY.asDouble, format: .number).textFieldStyle(.roundedBorder).controlSize(.mini).frame(width: 45) }
                                        Slider(value: $globalWmOffsetY, in: -500.0...500.0)
                                    }
                                }
                            }.padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                
                Divider()
                
                // 3. 底部 Action 区
                VStack(spacing: 12) {
                    Button(action: {
                        guard editingItem == nil else { return } // 防误触
                        withAnimation { images.removeAll(); hostingScrollView?.animator().magnification = 1.0 }
                    }) {
                        Label("清空全部照片 [W]", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.red).disabled(images.isEmpty)
                    .keyboardShortcut("w", modifiers: [])
                    .help("清空当前所有照片 (快捷键: W)")
                    
                    Button(action: exportFinalImage) {
                        if isExporting {
                            ProgressView().controlSize(.regular)
                        } else {
                            Label("导出最终长图 [E]", systemImage: "square.and.arrow.up.on.square.fill")
                                .font(.title3.bold()).padding(.vertical, 6).frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.blue)
                    .disabled(images.isEmpty || isExporting).shadow(radius: 2, y: 2)
                    .keyboardShortcut("e", modifiers: [])
                    .help("将当前画卷导出为长图 (快捷键: E)")
                }
                .padding(16)
            }
            .frame(width: 280) // 💡 左侧宽度彻底定死
            .background(Color(NSColor.windowBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
            
            Divider()
            
            // ================== 右侧全局工作区 ==================
            ZStack {
                // 💡 优化动态背景色：直接绑定主题变量，绝对不卡死
                (colorSchemeStyle == 2 ? Color(white: 0.12) : Color(white: 0.94)).ignoresSafeArea()
                
                ScrollView([.vertical, .horizontal]) {
                    VStack(spacing: 0) {
                        if !images.isEmpty {
                            VStack(spacing: 0) {
                                // 💡 性能核心优化：通过 item 自身 ID 进行 SwiftUI 循环渲染，杜绝重建
                                ForEach(images) { item in
                                    Image(nsImage: item.displayImage).resizable().scaledToFit().frame(maxWidth: .infinity)
                                        .shadow(color: draggedItem == item ? .black.opacity(0.6) : .clear, radius: draggedItem == item ? 15 : 0, y: draggedItem == item ? 10 : 0)
                                        .scaleEffect(draggedItem == item ? 1.02 : 1.0).opacity(draggedItem == item ? 0.9 : 1.0).zIndex(draggedItem == item ? 1000 : 0)
                                        .offset(y: draggedItem == item ? dragOffset : 0).contentShape(Rectangle())
                                        .padding(.bottom, item.id == images.last?.id ? 0 : spacing)
                                }
                                
                                if bottomMargin > 0 {
                                    ZStack {
                                        Color.white
                                        if let wm = globalWatermark {
                                            let wmAspect = wm.size.width / max(1, wm.size.height); let actualWidth = 800 * 0.3 * globalWmScale; let actualHeight = actualWidth / wmAspect
                                            Image(nsImage: wm).resizable().scaledToFit().frame(width: actualWidth, height: actualHeight).offset(x: globalWmOffsetX, y: -globalWmOffsetY)
                                        } else { Text("底部留白区域").foregroundColor(Color(white: 0.9)) }
                                    }.frame(height: bottomMargin).frame(maxWidth: .infinity).clipped()
                                }
                            }
                            .frame(width: 800).padding(.vertical, 60).fixedSize(horizontal: true, vertical: true).animation(.spring(response: 0.35, dampingFraction: 0.8), value: images)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).background(ScrollViewConfigurator(scrollViewProxy: $hostingScrollView, currentScale: $canvasScale))
                }
                
                // 💡 居中空状态提示
                if images.isEmpty {
                    ContentUnavailableView("暂无照片", systemImage: "photo.on.rectangle.angled", description: Text("支持 Option+滚轮 或 双指捏合 指哪打哪\n按住空格键可平移画布\n拖拽照片排序，双击进入【裁剪】"))
                }
            }
            .dropDestination(for: URL.self) { items, _ in
                let group = DispatchGroup()
                for url in items {
                    group.enter()
                    loadAndAddImage(from: url) { group.leave() }
                }
                group.notify(queue: .main) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.fitToScreen() }
                }
                return true
            }
            .onAppear(perform: setupEventMonitor).onDisappear { if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) } }
        }
        .preferredColorScheme(currentColorScheme) // 💡 强制应用主题外观
        .sheet(item: $editingItem) { item in
            CropEditorView(item: item) { updatedItem in
                if let index = images.firstIndex(where: { $0.id == updatedItem.id }) { images[index] = updatedItem }
                editingItem = nil
            } onCancel: { editingItem = nil }.id(item.id)
        }
        .alert(isPresented: $showingExportAlert) {
            Alert(
                title: Text(exportAlertTitle),
                message: Text(exportAlertMessage),
                primaryButton: .default(Text("确定")),
                secondaryButton: .destructive(Text("清空画布")) {
                    withAnimation {
                        images.removeAll()
                        hostingScrollView?.animator().magnification = 1.0
                    }
                }
            )
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
        let savePanel = NSSavePanel(); savePanel.allowedContentTypes = [.jpeg, .png]; savePanel.nameFieldStringValue = "AoiStitcher_Output.jpg"
        if !lastExportDir.isEmpty { savePanel.directoryURL = URL(fileURLWithPath: lastExportDir) }
        
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }; isExporting = true
            self.lastExportDir = url.deletingLastPathComponent().path
            
            let safeImages = self.images; let safeExportWidth = CGFloat(Double(self.exportWidth) ?? 2560); let safeSpacing = self.spacing; let safeBottomMargin = self.bottomMargin; let safeGlobalWM = self.globalWatermark; let safeWmScale = self.globalWmScale; let safeWmOffsetX = self.globalWmOffsetX; let safeWmOffsetY = self.globalWmOffsetY
            
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
                            let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]); try data?.write(to: url)
                            DispatchQueue.main.async { self.exportAlertTitle = "导出成功"; self.exportAlertMessage = "长图已成功保存！"; self.showingExportAlert = true; self.isExporting = false }
                        } else { throw NSError(domain: "WriteError", code: 3, userInfo: nil) }
                    } catch {
                        DispatchQueue.main.async { self.exportAlertTitle = "导出失败"; self.exportAlertMessage = "内存不足或处理超大分辨率失败。"; self.showingExportAlert = true; self.isExporting = false }
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
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .keyUp, .magnify]) { event in
            
            guard editingItem == nil else { return event }
            
            if event.type == .keyDown || event.type == .keyUp {
                if event.keyCode == 49 {
                    if event.type == .keyDown && !event.isARepeat { isSpacePressed = true; NSCursor.openHand.push(); return nil }
                    else if event.type == .keyUp { isSpacePressed = false; NSCursor.pop(); return nil }
                }
            }
            guard let scrollView = hostingScrollView, let win = scrollView.window, event.window == win else { return event }
            
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
                guard let documentView = scrollView.documentView else { return event }
                let clickY = documentView.convert(event.locationInWindow, from: nil).y
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

// ==========================================
// 💡 AppKit 透明事件侦听器
// ==========================================
struct ZoomPanCatcher: NSViewRepresentable {
    @Binding var zoom: CGFloat
    var minZoom: CGFloat = 0.2
    var maxZoom: CGFloat = 5.0
    
    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.onZoom = { factor in
            DispatchQueue.main.async { self.zoom = max(self.minZoom, min(self.maxZoom, self.zoom * factor)) }
        }
        view.onMagnify = { mag in
            DispatchQueue.main.async { self.zoom = max(self.minZoom, min(self.maxZoom, self.zoom + mag)) }
        }
        return view
    }
    func updateNSView(_ nsView: EventView, context: Context) {}
    
    class EventView: NSView {
        var onZoom: ((CGFloat) -> Void)?
        var onMagnify: ((CGFloat) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.option) {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.5 : event.scrollingDeltaY * 5.0
                let zoomFactor = 1.0 - (delta * 0.01)
                onZoom?(zoomFactor)
            } else {
                super.scrollWheel(with: event)
            }
        }
        override func magnify(with event: NSEvent) {
            onMagnify?(event.magnification)
        }
    }
}

// ==========================================
// 4. 二次裁剪与盖印工作台
// ==========================================
enum EditMode: String, CaseIterable { case crop = "📐 裁剪"; case watermark = "💧 水印" }
enum DragHandle { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, center }

struct CropEditorView: View {
    var item: StitchItem
    var onSave: (StitchItem) -> Void
    var onCancel: () -> Void
    
    @State private var currentMode: EditMode = .crop
    
    @State private var uiCropRect: CGRect = .zero
    @State private var dragStartRect: CGRect = .zero
    @State private var rotation: Double = 0
    @State private var dragStartRotation: Double = 0
    @State private var imageCenter: CGPoint = .zero
    @State private var dragStartCenter: CGPoint = .zero
    @State private var baseScale: CGFloat = 1.0
    
    @State private var canvasZoom: CGFloat = 1.0
    @State private var canvasOffset: CGSize = .zero
    @State private var lastCanvasOffset: CGSize = .zero
    @State private var isSpacePressed: Bool = false
    @State private var localEventMonitor: Any? = nil
    
    @State private var initCropRect: CGRect = .zero
    @State private var initCenter: CGPoint = .zero
    @State private var initScale: CGFloat = 1.0
    
    @State private var selectedPreset: CropRatioPreset = .original
    @State private var localWatermarks: [OverlayWatermark] = []
    @State private var selectedWatermarkID: UUID?
    
    // 💡 读取主界面传递的深浅色变量，保证颜色统一
    @AppStorage("colorSchemeStyle") private var colorSchemeStyle: Int = 1
    @AppStorage("lastLocalWatermarkDir") private var lastLocalWatermarkDir: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.escape)
                Spacer()
                Picker("", selection: $currentMode) { ForEach(EditMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) } }.pickerStyle(.segmented).frame(width: 250)
                Spacer()
                Button("保存", action: save).keyboardShortcut(.return).buttonStyle(.borderedProminent)
            }.padding().background(Color(NSColor.windowBackgroundColor)).zIndex(100)
            Divider()
            
            Group {
                if currentMode == .crop {
                    HStack(spacing: 15) {
                        HStack {
                            Text("比例:").foregroundColor(.secondary)
                            Picker("", selection: $selectedPreset) { ForEach(CropRatioPreset.allCases) { p in Text(p.rawValue).tag(p) } }
                                .pickerStyle(.menu).labelsHidden().frame(width: 80)
                                .onChange(of: selectedPreset) { _ in applyPreset() }
                        }
                        Divider().frame(height: 20)
                        HStack {
                            Text("旋转:").foregroundColor(.secondary)
                            Slider(value: $rotation, in: -45.0...45.0).frame(width: 80)
                                .onChange(of: rotation) { _ in ensureCropBoxInsideImage() }
                            Text(String(format: "%.1f°", rotation)).frame(width: 45, alignment: .leading)
                        }
                        Divider().frame(height: 20)
                        HStack {
                            Text("缩放预览:").foregroundColor(.secondary)
                            Slider(value: $canvasZoom, in: 0.2...5.0).frame(width: 80)
                            Button(action: { withAnimation { canvasZoom = 1.0; canvasOffset = .zero } }) { Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left") }.buttonStyle(.plain).help("重置画布位置")
                        }
                        Spacer()
                        Button(action: resetToInitial) { Label("重置", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }.padding(.horizontal).padding(.vertical, 8).background(Color(NSColor.controlBackgroundColor))
                } else {
                    HStack {
                        Button(action: addWatermark) { Label("添加水印", systemImage: "plus.square.on.square") }.buttonStyle(.bordered)
                        if let selectedID = selectedWatermarkID, let idx = localWatermarks.firstIndex(where: { $0.id == selectedID }) {
                            Divider().frame(height: 20).padding(.horizontal)
                            Text("缩放:").font(.caption)
                            Slider(value: $localWatermarks[idx].scale, in: 0.1...3.0).frame(width: 100)
                            Text("旋转:").font(.caption)
                            Slider(value: $localWatermarks[idx].rotation, in: -180.0...180.0).frame(width: 100)
                            Button(action: { localWatermarks.remove(at: idx); selectedWatermarkID = nil }) { Image(systemName: "trash").foregroundColor(.red) }.buttonStyle(.plain).padding(.leading)
                        }
                        Spacer()
                    }.padding(.horizontal).padding(.vertical, 8).background(Color(NSColor.controlBackgroundColor))
                }
            }.zIndex(100)
            Divider()
            
            GeometryReader { geo in
                ZStack {
                    ZoomPanCatcher(zoom: $canvasZoom).ignoresSafeArea()
                    
                    // 💡 同步统一裁剪工作台背景色
                    (colorSchemeStyle == 2 ? Color(white: 0.12) : Color(white: 0.94)).ignoresSafeArea()
                        .gesture(currentMode == .crop && !isSpacePressed ? rotationGesture(center: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)) : nil)
                        .onTapGesture { if currentMode == .watermark { selectedWatermarkID = nil } }
                    
                    ZStack {
                        ZStack {
                            Image(nsImage: item.image).resizable().aspectRatio(contentMode: .fit)
                            ForEach(localWatermarks.indices, id: \.self) { index in
                                WatermarkLayerView(
                                    index: index, watermark: $localWatermarks[index],
                                    isSelected: .init(get: { selectedWatermarkID == localWatermarks[index].id }, set: { if $0 { selectedWatermarkID = localWatermarks[index].id } }),
                                    canvasSize: item.image.size, isWorkAreaActive: currentMode == .watermark, canvasZoom: canvasZoom
                                )
                            }
                        }
                        .frame(width: item.image.size.width, height: item.image.size.height).coordinateSpace(name: "ImageSpace")
                        .scaleEffect(baseScale).rotationEffect(.degrees(rotation)).position(x: imageCenter.x, y: imageCenter.y)
                        .gesture(currentMode == .crop && !isSpacePressed ? imageDragGesture() : nil)
                        
                        if uiCropRect != .zero {
                            Path { path in
                                path.addRect(CGRect(x: -10000, y: -10000, width: 20000, height: 20000))
                                path.addRect(uiCropRect)
                            }
                            .fill(Color.black.opacity(0.75), style: FillStyle(eoFill: true))
                            .allowsHitTesting(false)
                        }
                        
                        if currentMode == .crop && uiCropRect != .zero {
                            CropBoxOverlay(rect: $uiCropRect, preset: selectedPreset, canvasZoom: canvasZoom) { handle, val in
                                if !isSpacePressed { handleCropDrag(handle: handle, val: val) }
                            } onDragEnd: { dragStartRect = .zero }
                            
                            Path { p in p.move(to: CGPoint(x: uiCropRect.midX, y: uiCropRect.minY)); p.addLine(to: CGPoint(x: uiCropRect.midX, y: uiCropRect.minY - 30)) }.stroke(Color.white, lineWidth: 1.5).allowsHitTesting(false)
                            Circle().fill(Color.white).frame(width: 12, height: 12).shadow(radius: 2).overlay(Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 6)).foregroundColor(.black))
                                .position(x: uiCropRect.midX, y: uiCropRect.minY - 30)
                                .gesture(!isSpacePressed ? rotationGesture(center: CGPoint(x: uiCropRect.midX, y: uiCropRect.midY)) : nil)
                                .onHover { h in if h && !isSpacePressed { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        }
                    }
                    .scaleEffect(canvasZoom).offset(canvasOffset)
                    
                    if isSpacePressed {
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { val in canvasOffset = CGSize(width: lastCanvasOffset.width + val.translation.width, height: lastCanvasOffset.height + val.translation.height) }.onEnded { _ in lastCanvasOffset = canvasOffset })
                            .onHover { h in if h { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    }
                }
                .onAppear { setupCanvas(size: geo.size) }
                .onChange(of: geo.size) { newSize in setupCanvas(size: newSize) }
            }
            .clipped()
        }
        .frame(width: 1000, height: 800)
        .onAppear {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                if event.keyCode == 49 {
                    isSpacePressed = (event.type == .keyDown)
                    if isSpacePressed { NSCursor.openHand.push() } else { NSCursor.pop() }
                    return nil
                }
                return event
            }
        }
        .onDisappear { if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor) } }
    }
    
    // MARK: - 核心算法逻辑
    
    private func setupCanvas(size: CGSize) {
        if uiCropRect != .zero { return }
        let pad: CGFloat = 80
        imageCenter = CGPoint(x: size.width / 2, y: size.height / 2 + 20)
        let drawW = size.width - pad; let drawH = size.height - pad - 40
        baseScale = min(drawW / item.image.size.width, drawH / item.image.size.height)
        
        if let info = item.cropInfo {
            self.uiCropRect = info.uiCropRect
            self.rotation = info.rotation
            self.imageCenter = info.imageCenter
            self.baseScale = info.scale
        } else {
            let imgW = item.image.size.width * baseScale
            let imgH = item.image.size.height * baseScale
            self.uiCropRect = CGRect(x: imageCenter.x - imgW/2, y: imageCenter.y - imgH/2, width: imgW, height: imgH)
        }
        self.initCropRect = CGRect(x: imageCenter.x - (item.image.size.width * baseScale)/2, y: imageCenter.y - (item.image.size.height * baseScale)/2, width: item.image.size.width * baseScale, height: item.image.size.height * baseScale)
        self.initScale = self.baseScale
        self.initCenter = self.imageCenter
        self.localWatermarks = item.watermarks
    }
    
    private func resetToInitial() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            uiCropRect = initCropRect
            rotation = 0
            baseScale = initScale
            imageCenter = initCenter
            selectedPreset = .original
            canvasZoom = 1.0
            canvasOffset = .zero
            lastCanvasOffset = .zero
        }
    }
    
    private func applyPreset() {
        guard let ratio = selectedPreset.ratioValue else { return }
        let center = CGPoint(x: uiCropRect.midX, y: uiCropRect.midY)
        let w = uiCropRect.width; let h = w / ratio
        withAnimation(.spring()) { uiCropRect = CGRect(x: center.x - w/2, y: center.y - h/2, width: w, height: h) }
        ensureCropBoxInsideImage()
    }
    
    private func isRectValid(_ rect: CGRect, testCenter: CGPoint? = nil) -> Bool {
        let imgW = item.image.size.width; let imgH = item.image.size.height
        let rad = -rotation * .pi / 180.0; let cosR = cos(rad); let sinR = sin(rad)
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        let cCenter = testCenter ?? imageCenter
        let limitX = (imgW * baseScale) / 2.0 + 0.5; let limitY = (imgH * baseScale) / 2.0 + 0.5
        for c in corners {
            let dx = c.x - cCenter.x; let dy = c.y - cCenter.y
            let lx = abs(dx * cosR - dy * sinR); let ly = abs(dx * sinR + dy * cosR)
            if lx > limitX || ly > limitY { return false }
        }
        return true
    }
    
    private func clampImageCenter() {
        let imgW = item.image.size.width; let imgH = item.image.size.height
        let rad = -rotation * .pi / 180.0; let cosR = cos(rad); let sinR = sin(rad)
        let dx = imageCenter.x - uiCropRect.midX; let dy = imageCenter.y - uiCropRect.midY
        let localX = dx * cosR - dy * sinR; let localY = dx * sinR + dy * cosR
        
        let limitX = max(0, (imgW * baseScale - uiCropRect.width * abs(cosR) - uiCropRect.height * abs(sinR)) / 2.0)
        let limitY = max(0, (imgH * baseScale - uiCropRect.width * abs(sinR) - uiCropRect.height * abs(cosR)) / 2.0)
        let clampedX = min(max(localX, -limitX), limitX); let clampedY = min(max(localY, -limitY), limitY)
        
        let finalDx = clampedX * cos(-rad) - clampedY * sin(-rad)
        let finalDy = clampedX * sin(-rad) + clampedY * cos(-rad)
        imageCenter = CGPoint(x: uiCropRect.midX + finalDx, y: uiCropRect.midY + finalDy)
    }
    
    private func ensureCropBoxInsideImage() {
        let imgW = item.image.size.width; let imgH = item.image.size.height
        let rad = -rotation * .pi / 180.0; let cosR = cos(rad); let sinR = sin(rad)
        let projectedW = uiCropRect.width * abs(cosR) + uiCropRect.height * abs(sinR)
        let projectedH = uiCropRect.width * abs(sinR) + uiCropRect.height * abs(cosR)
        let reqScale = max(projectedW / imgW, projectedH / imgH)
        if baseScale < reqScale { baseScale = reqScale }
        clampImageCenter()
    }
    
    private func handleCropDrag(handle: DragHandle, val: DragGesture.Value) {
        if dragStartRect == .zero { dragStartRect = uiCropRect }
        let start = dragStartRect; let dX = val.translation.width / canvasZoom; let dY = val.translation.height / canvasZoom
        var newRect = start; let minS: CGFloat = 50
        switch handle {
        case .topLeft: newRect.origin.x = min(start.maxX - minS, start.minX + dX); newRect.origin.y = min(start.maxY - minS, start.minY + dY); newRect.size.width = start.maxX - newRect.minX; newRect.size.height = start.maxY - newRect.minY
        case .topRight: newRect.size.width = max(minS, start.width + dX); newRect.origin.y = min(start.maxY - minS, start.minY + dY); newRect.size.height = start.maxY - newRect.minY
        case .bottomLeft: newRect.origin.x = min(start.maxX - minS, start.minX + dX); newRect.size.width = start.maxX - newRect.minX; newRect.size.height = max(minS, start.height + dY)
        case .bottomRight: newRect.size.width = max(minS, start.width + dX); newRect.size.height = max(minS, start.height + dY)
        case .top: newRect.origin.y = min(start.maxY - minS, start.minY + dY); newRect.size.height = start.maxY - newRect.minY
        case .bottom: newRect.size.height = max(minS, start.height + dY)
        case .left: newRect.origin.x = min(start.maxX - minS, start.minX + dX); newRect.size.width = start.maxX - newRect.minX
        case .right: newRect.size.width = max(minS, start.width + dX)
        case .center:
            newRect.origin.x = start.minX + dX; newRect.origin.y = start.minY + dY
            if isRectValid(newRect) { uiCropRect = newRect }
            return
        }
        
        if selectedPreset != .original, let ratio = selectedPreset.ratioValue, handle != .center {
            newRect.size.height = newRect.size.width / ratio
            if handle == .topLeft || handle == .top || handle == .topRight { newRect.origin.y = start.maxY - newRect.size.height }
        }
        uiCropRect = newRect
        ensureCropBoxInsideImage()
    }
    
    private func imageDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { val in
            if dragStartCenter == .zero { dragStartCenter = imageCenter }
            imageCenter = CGPoint(x: dragStartCenter.x + val.translation.width / canvasZoom, y: dragStartCenter.y + val.translation.height / canvasZoom)
            clampImageCenter()
        }.onEnded { _ in dragStartCenter = .zero }
    }
    
    private func rotationGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { val in
            let angle = atan2(val.location.y - center.y, val.location.x - center.x) * 180.0 / .pi
            if dragStartRect == .zero { dragStartRect = CGRect(x: 1, y: 1, width: 1, height: 1); dragStartRotation = angle }
            var delta = angle - dragStartRotation
            if delta > 180.0 { delta -= 360.0 } else if delta < -180.0 { delta += 360.0 }
            rotation += delta
            dragStartRotation = angle
            ensureCropBoxInsideImage()
        }.onEnded { _ in dragStartRect = .zero }
    }
    
    private func addWatermark() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        if !lastLocalWatermarkDir.isEmpty { panel.directoryURL = URL(fileURLWithPath: lastLocalWatermarkDir) }
        
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            let new = OverlayWatermark(image: img); localWatermarks.append(new); selectedWatermarkID = new.id
            lastLocalWatermarkDir = url.deletingLastPathComponent().path
        }
    }
    
    private func save() {
        let info = CropInfo(uiCropRect: uiCropRect, rotation: rotation, imageCenter: imageCenter, scale: baseScale)
        var newItem = item; newItem.cropInfo = info; newItem.watermarks = localWatermarks; newItem.croppedImage = generateCroppedImage(item: newItem)
        onSave(newItem)
    }
}

// 8向拖拽遮罩 UI
struct CropBoxOverlay: View {
    @Binding var rect: CGRect
    var preset: CropRatioPreset
    var canvasZoom: CGFloat
    var onDrag: (DragHandle, DragGesture.Value) -> Void
    var onDragEnd: () -> Void
    let handleSize: CGFloat = 16
    
    var body: some View {
        ZStack {
            Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            Path { p in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3.0; p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                    let y = rect.minY + rect.height * CGFloat(i) / 3.0; p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }.stroke(Color.white.opacity(0.5), lineWidth: 1)
            
            Color.clear.contentShape(Rectangle()).frame(width: max(1, rect.width - 40), height: max(1, rect.height - 40)).position(x: rect.midX, y: rect.midY)
                .gesture(DragGesture(minimumDistance: 0).onChanged { onDrag(.center, $0) }.onEnded { _ in onDragEnd() })
                .onHover { h in if h { NSCursor.openHand.push() } else { NSCursor.pop() } }
            
            if preset == .original {
                edgeHandle(.top, x: rect.midX, y: rect.minY, w: rect.width - 40, h: 20, cursor: .resizeUpDown)
                edgeHandle(.bottom, x: rect.midX, y: rect.maxY, w: rect.width - 40, h: 20, cursor: .resizeUpDown)
                edgeHandle(.left, x: rect.minX, y: rect.midY, w: 20, h: rect.height - 40, cursor: .resizeLeftRight)
                edgeHandle(.right, x: rect.maxX, y: rect.midY, w: 20, h: rect.height - 40, cursor: .resizeLeftRight)
            }
            cornerHandle(.topLeft, x: rect.minX, y: rect.minY)
            cornerHandle(.topRight, x: rect.maxX, y: rect.minY)
            cornerHandle(.bottomLeft, x: rect.minX, y: rect.maxY)
            cornerHandle(.bottomRight, x: rect.maxX, y: rect.maxY)
        }
    }
    private func cornerHandle(_ handle: DragHandle, x: CGFloat, y: CGFloat) -> some View {
        Rectangle().fill(Color.white).frame(width: handleSize, height: handleSize).shadow(radius: 2)
            .position(x: x, y: y).gesture(DragGesture(minimumDistance: 0).onChanged { onDrag(handle, $0) }.onEnded { _ in onDragEnd() }).onHover { h in if h { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }
    private func edgeHandle(_ handle: DragHandle, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, cursor: NSCursor) -> some View {
        Color.clear.contentShape(Rectangle()).frame(width: max(10, w), height: max(10, h)).position(x: x, y: y)
            .gesture(DragGesture(minimumDistance: 0).onChanged { onDrag(handle, $0) }.onEnded { _ in onDragEnd() }).onHover { hv in if hv { cursor.push() } else { NSCursor.pop() } }
    }
}

// 水印图层
struct WatermarkLayerView: View {
    let index: Int; @Binding var watermark: OverlayWatermark; @Binding var isSelected: Bool; let canvasSize: CGSize; let isWorkAreaActive: Bool; var canvasZoom: CGFloat
    @State private var dragOffset: CGSize = .zero; @State private var scaleDelta: CGFloat = 0; @State private var rotDelta: Double = 0; @State private var startRot: Double? = nil
    var body: some View {
        let aspect = watermark.image.size.width / max(1, watermark.image.size.height)
        let currentW = canvasSize.width * 0.3 * max(0.05, (watermark.scale + (isSelected ? scaleDelta : 0))); let currentH = currentW / aspect
        ZStack {
            Image(nsImage: watermark.image).resizable().scaledToFit()
            if isSelected && isWorkAreaActive {
                Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5])).padding(-2)
                Path { p in p.move(to: CGPoint(x: currentW / 2, y: 0)); p.addLine(to: CGPoint(x: currentW / 2, y: -30)) }.stroke(Color.accentColor, lineWidth: 1.5)
                Circle().fill(Color.white).frame(width: 12, height: 12).overlay(Circle().stroke(Color.accentColor)).position(x: currentW / 2, y: -30).gesture(rotGesture())
                Circle().fill(Color.white).frame(width: 12, height: 12).overlay(Circle().stroke(Color.accentColor)).position(x: currentW, y: currentH).gesture(scaleGesture())
            }
        }.frame(width: currentW, height: currentH).coordinateSpace(name: "WMLocal_\(watermark.id)")
        .rotationEffect(.degrees(watermark.rotation + (isSelected ? rotDelta : 0)))
        .offset(x: watermark.offset.width + (isSelected ? dragOffset.width : 0), y: watermark.offset.height + (isSelected ? dragOffset.height : 0))
        .onTapGesture { if isWorkAreaActive { isSelected = true } }
        .gesture(isWorkAreaActive ? DragGesture(minimumDistance: 0, coordinateSpace: .named("ImageSpace")).onChanged { v in if !isSelected { isSelected = true }; dragOffset = CGSize(width: v.translation.width / canvasZoom, height: v.translation.height / canvasZoom) }.onEnded { _ in watermark.offset.width += dragOffset.width; watermark.offset.height += dragOffset.height; dragOffset = .zero } : nil)
    }
    private func scaleGesture() -> some Gesture { DragGesture(minimumDistance: 0, coordinateSpace: .named("WMLocal_\(watermark.id)")).onChanged { v in scaleDelta = ((v.translation.width + v.translation.height) / canvasZoom) * 0.002 }.onEnded { _ in watermark.scale = max(0.05, watermark.scale + scaleDelta); scaleDelta = 0 } }
    private func rotGesture() -> some Gesture { DragGesture(minimumDistance: 0, coordinateSpace: .named("ImageSpace")).onChanged { v in let c = CGPoint(x: canvasSize.width / 2 + watermark.offset.width, y: canvasSize.height / 2 + watermark.offset.height); let a = atan2(v.location.y - c.y, v.location.x - c.x) * 180.0 / .pi; if startRot == nil { startRot = a }; var d = a - startRot!; if d > 180.0 { d -= 360.0 } else if d < -180.0 { d += 360.0 }; rotDelta = d }.onEnded { _ in watermark.rotation += rotDelta; rotDelta = 0; startRot = nil } }
}

// ==========================================
// 5. 底层渲染引擎 (无损画质输出)
// ==========================================
func generateCroppedImage(item: StitchItem) -> NSImage? {
    guard let info = item.cropInfo else { return nil }
    let img = item.image
    let physicalW = info.uiCropRect.width / info.scale; let physicalH = info.uiCropRect.height / info.scale
    let outputSize = CGSize(width: physicalW, height: physicalH)
    
    let result = NSImage(size: outputSize)
    result.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { result.unlockFocus(); return nil }
    
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(origin: .zero, size: outputSize))
    
    ctx.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
    let offsetUI_X = info.imageCenter.x - info.uiCropRect.midX
    let offsetUI_Y = info.uiCropRect.midY - info.imageCenter.y
    ctx.translateBy(x: offsetUI_X / info.scale, y: offsetUI_Y / info.scale)
    ctx.rotate(by: CGFloat(-info.rotation * .pi / 180.0))
    
    let drawRect = CGRect(x: -img.size.width/2, y: -img.size.height/2, width: img.size.width, height: img.size.height)
    img.draw(in: drawRect)
    
    for wm in item.watermarks {
        ctx.saveGState()
        ctx.translateBy(x: wm.offset.width, y: -wm.offset.height)
        ctx.rotate(by: CGFloat(-wm.rotation * .pi / 180.0))
        let wmWidth = img.size.width * 0.3 * wm.scale
        let wmAspect = wm.image.size.height / max(1, wm.image.size.width)
        let wmHeight = wmWidth * wmAspect
        wm.image.draw(in: CGRect(x: -wmWidth/2, y: -wmHeight/2, width: wmWidth, height: wmHeight))
        ctx.restoreGState()
    }
    
    result.unlockFocus()
    return result
}
