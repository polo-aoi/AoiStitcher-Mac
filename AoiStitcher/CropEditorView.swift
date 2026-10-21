import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CropEditorView: View {
    let item: StitchItem
    let onSave: (StitchItem) -> Void
    let onCancel: () -> Void
    @StateObject private var store: CropStore
    @AppStorage("colorSchemeStyle") private var theme = 1
    @AppStorage("lastLocalWatermarkDir") private var lastWatermarkDir = ""

    init(item: StitchItem, onSave: @escaping (StitchItem) -> Void, onCancel: @escaping () -> Void) {
        self.item = item; self.onSave = onSave; self.onCancel = onCancel
        _store = StateObject(wrappedValue: CropStore(item: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar {
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(store.undoCount == 0).help("撤销（⌘Z）").accessibilityLabel("撤销")
                Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(store.redoCount == 0).help("重做（⇧⌘Z）").accessibilityLabel("重做")
                Divider().frame(height: 18)
                Picker("工具", selection: $store.tool) {
                    ForEach(CropTool.allCases) { tool in Label(tool.rawValue, systemImage: tool.symbol).tag(tool) }
                }.pickerStyle(.segmented).frame(width: 270).labelsHidden()
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.escape)
                Button { save() } label: {
                    HStack(spacing: 6) { if store.isSaving { ProgressView().controlSize(.small) }; Text("应用裁剪") }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return).disabled(store.isSaving)
            }
            Divider()
            toolBar
            Divider()
            ZStack {
                HStack(spacing: 0) {
                    CropCanvas(store: store)
                    Divider()
                    inspector.frame(width: 220)
                }
                if let message = store.message {
                    Text(message).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(minWidth: 920, minHeight: 570)
        }
        .frame(width: 1060, height: 720)
        .disabled(store.isSaving)
        .preferredColorScheme(theme == 2 ? .dark : .light)
    }

    private var toolBar: some View {
        HStack(spacing: 14) {
            if store.tool == .crop {
                Label("比例", systemImage: "aspectratio")
                Picker("裁剪比例", selection: Binding(get: { store.state.preset }, set: { store.applyPreset($0) })) {
                    ForEach(CropRatioPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
                }.labelsHidden().frame(width: 100)
                Button { store.swapAspect() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("交换裁剪框横竖比例").accessibilityLabel("交换裁剪框横竖比例")
                Divider().frame(height: 20)
                Label("拉直", systemImage: "level")
                Slider(value: Binding(get: { store.state.straighten }, set: { store.setStraighten($0) }), in: -45...45,
                       onEditingChanged: continuousEdit)
                    .frame(width: 130)
                Text("\(Int(store.state.straighten.rounded()))°").font(.callout.monospacedDigit()).frame(width: 38)
                Button { store.rotateQuarter() } label: { Image(systemName: "rotate.right") }
                    .help("顺时针旋转 90°").accessibilityLabel("顺时针旋转 90 度")
            } else if store.tool == .straighten {
                Label("拉直", systemImage: "level")
                Slider(value: Binding(get: { store.state.straighten }, set: { store.setStraighten($0) }), in: -45...45,
                       onEditingChanged: continuousEdit)
                    .frame(width: 180)
                Text("\(String(format: "%.1f", store.state.straighten))°").font(.callout.monospacedDigit()).frame(width: 54)
            } else {
                Button(action: addWatermark) { Label("添加水印", systemImage: "photo.badge.plus") }
                if store.selectedWatermark != nil {
                    Button { store.deleteWatermark() } label: { Label("删除水印", systemImage: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Spacer()
            Text("\(Int(store.displayedZoom * 100))%").font(.callout.monospacedDigit()).frame(width: 48)
            Button { store.fitRequest += 1 } label: { Image(systemName: "viewfinder") }
                .help("适合窗口").accessibilityLabel("适合窗口")
            Button { store.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("重置裁剪").accessibilityLabel("重置裁剪")
        }.padding(.horizontal, 16).padding(.vertical, 8)
            .buttonStyle(.borderless)
            .background(Color(NSColor.windowBackgroundColor))
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EditorSection("裁剪") {
                    Picker("比例", selection: Binding(get: { store.state.preset }, set: { store.applyPreset($0) })) {
                        ForEach(CropRatioPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
                    }
                    HStack { Text("宽"); Spacer(); Text("\(Int(store.outputSize.width)) px").monospacedDigit() }
                    HStack { Text("高"); Spacer(); Text("\(Int(store.outputSize.height)) px").monospacedDigit() }
                    Toggle("三分网格", isOn: $store.showGrid)
                }
                Divider()
                EditorSection("照片") {
                    HStack {
                        Text("拉直")
                        TextField("角度", value: Binding(get: { Double(store.state.straighten) }, set: { store.setStraighten(CGFloat($0)) }),
                                  format: .number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder)
                        Text("°")
                    }
                    HStack { Text("缩放"); Spacer(); Text("\(Int(store.state.imageScale * 100))%").monospacedDigit() }
                    Slider(value: Binding(get: { store.state.imageScale }, set: { store.setImageScale($0) }),
                           in: store.minimumImageScale...max(8, store.state.imageScale), onEditingChanged: continuousEdit)
                    HStack {
                        Button { store.rotateQuarter() } label: { Image(systemName: "rotate.right") }
                            .help("旋转 90°").accessibilityLabel("旋转 90 度")
                        Button { store.swapAspect() } label: { Image(systemName: "arrow.left.arrow.right") }
                            .help("交换裁剪框宽高").accessibilityLabel("交换裁剪框宽高")
                    }
                }
                Divider()
                EditorSection("水印") {
                    Button(action: addWatermark) { Label("添加水印", systemImage: "photo.badge.plus") }
                    ForEach(Array(store.state.watermarks.enumerated()), id: \.element.id) { index, watermark in
                        Button {
                            store.selectedWatermarkID = watermark.id; store.tool = .watermark
                        } label: {
                            HStack {
                                Image(nsImage: watermark.image).resizable().scaledToFit().frame(width: 28, height: 28)
                                Text("水印 \(index + 1)")
                                Spacer()
                            }.padding(6).background(store.selectedWatermarkID == watermark.id ? Color.accentColor.opacity(0.14) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                    }
                    if let watermark = store.selectedWatermark {
                        HStack { Text("缩放"); Spacer(); Text("\(Int(watermark.scale * 100))%").monospacedDigit() }
                        Slider(value: watermarkValue(watermark.id, rotation: false), in: 0.05...3, onEditingChanged: continuousEdit)
                        HStack { Text("旋转"); Spacer(); Text("\(Int(watermark.rotation))°").monospacedDigit() }
                        Slider(value: watermarkValue(watermark.id, rotation: true), in: -180...180, onEditingChanged: continuousEdit)
                        Button(role: .destructive) { store.deleteWatermark() } label: { Label("删除水印", systemImage: "trash") }
                    }
                }
            }.font(.callout).padding(16)
        }.background(Color(NSColor.windowBackgroundColor))
    }

    private func watermarkValue(_ id: UUID, rotation: Bool) -> Binding<Double> {
        Binding(get: {
            guard let watermark = store.state.watermarks.first(where: { $0.id == id }) else { return 0 }
            return rotation ? watermark.rotation : Double(watermark.scale)
        }, set: { value in
            guard value.isFinite else { return }
            store.editWatermark(id) { if rotation { $0.rotation = value } else { $0.scale = CGFloat(value) } }
        })
    }
    private func continuousEdit(_ editing: Bool) { if editing { store.beginChange() } else { store.endChange() } }

    private func addWatermark() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        if !lastWatermarkDir.isEmpty { panel.directoryURL = URL(fileURLWithPath: lastWatermarkDir) }
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        lastWatermarkDir = url.deletingLastPathComponent().path
        store.addWatermark(image)
    }

    private func save() {
        guard let snapshot = CropRenderSnapshot(store) else { return }
        store.isSaving = true
        let cropStore = store
        let savedState = store.state
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let image = try CropRenderer.makeImage(snapshot)
                DispatchQueue.main.async {
                    cropStore.isSaving = false
                    onSave(cropStore.makeItem(image: image, savedState: savedState))
                }
            } catch {
                DispatchQueue.main.async { cropStore.isSaving = false; cropStore.message = error.localizedDescription }
            }
        }
    }
}

struct CropCanvas: NSViewRepresentable {
    @ObservedObject var store: CropStore
    func makeNSView(context: Context) -> CropCanvasView {
        let view = CropCanvasView(); view.store = store; return view
    }
    func updateNSView(_ view: CropCanvasView, context: Context) {
        view.store = store
        if view.lastFitRequest != store.fitRequest { view.lastFitRequest = store.fitRequest; view.resetViewport() }
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class CropCanvasView: NSView {
    weak var store: CropStore?
    var lastFitRequest = -1
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var viewportCenter = CGPoint.zero
    private var needsInitialFit = true
    private var interaction: Interaction?
    private var startPoint = CGPoint.zero
    private var initialState: CropState?
    private var spacePressed = false
    private var panStart = CGPoint.zero
    private var straighteningLine: (CGPoint, CGPoint)?
    private var gestureEndWork: DispatchWorkItem?
    private enum Interaction { case image, crop, resize(CropHandle), pan, straighten, rotate, watermark(UUID), watermarkScale(UUID), watermarkRotate(UUID) }
    private static let rotationCursor: NSCursor = {
        let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "旋转")!
        image.size = CGSize(width: 22, height: 22)
        return NSCursor(image: image, hotSpot: CGPoint(x: 11, y: 11))
    }()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("裁剪预览") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var imageSize: CGSize { store?.imageSize ?? .zero }
    private var displayScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return max(0.01, min((bounds.width - 80) / imageSize.width, (bounds.height - 100) / imageSize.height)) * zoom
    }
    private var origin: CGPoint {
        return CGPoint(x: bounds.midX - viewportCenter.x * displayScale + pan.x,
                       y: bounds.midY - viewportCenter.y * displayScale + pan.y)
    }
    private func worldPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / displayScale, y: (point.y - origin.y) / displayScale)
    }
    private func viewPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: origin.x + point.x * displayScale, y: origin.y + point.y * displayScale) }

    func resetViewport() {
        guard let store else { return }
        guard bounds.width > 100, bounds.height > 100 else { needsInitialFit = true; return }
        needsInitialFit = false
        viewportCenter = CGPoint(x: store.state.rect.midX, y: store.state.rect.midY)
        let rotated = store.state.rotation * .pi / 180
        let width = imageSize.width * abs(cos(rotated)) + imageSize.height * abs(sin(rotated))
        let height = imageSize.width * abs(sin(rotated)) + imageSize.height * abs(cos(rotated))
        let base = max(0.01, min((bounds.width - 80) / imageSize.width, (bounds.height - 100) / imageSize.height))
        zoom = max(0.1, min((bounds.width - 80) / width, (bounds.height - 100) / height) / base)
        pan = .zero; store.displayedZoom = zoom; needsDisplay = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if needsInitialFit { resetViewport() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let store, let snapshot = CropRenderSnapshot(store, preview: true) else { return }
        context.saveGState(); context.translateBy(x: origin.x, y: origin.y); context.scaleBy(x: displayScale, y: displayScale)
        CropRenderer.draw(snapshot, in: context)
        let rect = store.state.rect
        context.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor)
        let mask = CGMutablePath(); mask.addRect(CGRect(x: -imageSize.width * 2, y: -imageSize.height * 2, width: imageSize.width * 5, height: imageSize.height * 5)); mask.addRect(rect)
        context.addPath(mask); context.setBlendMode(.normal); context.drawPath(using: .eoFill)
        context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(1.5 / displayScale); context.stroke(rect)
        if store.showGrid {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor); context.setLineWidth(1 / displayScale)
            for index in 1...2 {
                let x = rect.minX + rect.width * CGFloat(index) / 3
                context.move(to: CGPoint(x: x, y: rect.minY)); context.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(index) / 3
                context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()
        }
        let handleRadius = 4 / displayScale
        for handle in CropHandle.allCases where store.tool != .watermark {
            let point = handle.point(on: rect); context.setFillColor(NSColor.white.cgColor); context.fillEllipse(in: CGRect(x: point.x - handleRadius, y: point.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2))
            context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.strokeEllipse(in: CGRect(x: point.x - handleRadius, y: point.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2))
        }
        if store.tool == .watermark, let watermark = store.selectedWatermark { drawWatermarkSelection(watermark, context: context) }
        context.restoreGState()
        if store.tool == .crop {
            let point = rotationHandlePoint
            let frame = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
            NSColor.white.setFill(); NSBezierPath(ovalIn: frame).fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(ovalIn: frame); outline.lineWidth = 1.5; outline.stroke()
            NSColor.white.setStroke()
            let stem = NSBezierPath(); stem.move(to: CGPoint(x: point.x, y: point.y + 10))
            stem.line(to: viewPoint(CGPoint(x: rect.midX, y: rect.minY))); stem.stroke()
            if let icon = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "旋转") {
                icon.draw(in: frame.insetBy(dx: 3, dy: 3), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            if case .rotate = interaction {
                let label = String(format: "%.1f°", store.state.straighten) as NSString
                label.draw(at: CGPoint(x: point.x + 16, y: point.y - 8), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white
                ])
            }
        }
        if let line = straighteningLine {
            context.setStrokeColor(NSColor.systemYellow.cgColor); context.setLineWidth(2)
            context.move(to: line.0); context.addLine(to: line.1); context.strokePath()
        }
    }

    private func handle(at point: CGPoint) -> CropHandle? {
        guard let store else { return nil }
        let rect = CGRect(origin: viewPoint(store.state.rect.origin), size: CGSize(width: store.state.rect.width * displayScale,
                                                                                height: store.state.rect.height * displayScale))
        if let handle = CropHandle.allCases.first(where: {
            let handlePoint = viewPoint($0.point(on: store.state.rect))
            return hypot(point.x - handlePoint.x, point.y - handlePoint.y) <= 12
        }) { return handle }
        if point.x >= rect.minX && point.x <= rect.maxX {
            if abs(point.y - rect.minY) <= 6 { return .top }
            if abs(point.y - rect.maxY) <= 6 { return .bottom }
        }
        if point.y >= rect.minY && point.y <= rect.maxY {
            if abs(point.x - rect.minX) <= 6 { return .left }
            if abs(point.x - rect.maxX) <= 6 { return .right }
        }
        return nil
    }
    private var rotationHandlePoint: CGPoint {
        guard let rect = store?.state.rect else { return .zero }
        let top = viewPoint(CGPoint(x: rect.midX, y: rect.minY))
        return CGPoint(x: top.x, y: top.y - 30)
    }
    private func rotationArea(at point: CGPoint) -> Bool {
        guard let rect = store?.state.rect else { return false }
        let rotationPoint = rotationHandlePoint
        if hypot(point.x - rotationPoint.x, point.y - rotationPoint.y) <= 13 { return true }
        let frame = CGRect(origin: viewPoint(rect.origin), size: CGSize(width: rect.width * displayScale, height: rect.height * displayScale))
        return frame.insetBy(dx: -32, dy: -32).contains(point) && !frame.insetBy(dx: -8, dy: -8).contains(point)
    }
    private func pointInCrop(_ point: CGPoint) -> Bool { store?.state.rect.contains(worldPoint(point)) ?? false }

    override func mouseDown(with event: NSEvent) {
        guard let store, !store.isSaving else { return }
        window?.makeFirstResponder(self); startPoint = eventPoint(event)
        gestureEndWork?.cancel(); store.endChange(); store.beginChange()
        if event.modifierFlags.contains(.option) || spacePressed { interaction = .pan; panStart = pan; return }
        initialState = store.state
        if store.tool == .straighten { interaction = .straighten; straighteningLine = (startPoint, startPoint); return }
        if store.tool == .watermark {
            let world = worldPoint(startPoint)
            if let selected = store.selectedWatermark, let transform = watermarkHandle(at: world, watermark: selected) {
                interaction = transform; return
            }
            let selected = store.state.watermarks.reversed().first { watermark in
                let local = watermarkPoint(world, watermark: watermark)
                let size = watermarkSize(watermark)
                return abs(local.x) <= size.width / 2 && abs(local.y) <= size.height / 2
            }
            store.selectedWatermarkID = selected?.id
            interaction = selected.map { .watermark($0.id) }; needsDisplay = true; return
        }
        if let handle = handle(at: startPoint) { interaction = .resize(handle); initialState = store.state; store.beginChange(); return }
        if rotationArea(at: startPoint) { interaction = .rotate; Self.rotationCursor.set(); return }
        if pointInCrop(startPoint) { interaction = event.modifierFlags.contains(.command) ? .crop : .image }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let store, !store.isSaving, let interaction else { return }
        let point = eventPoint(event); let delta = CGPoint(x: (point.x - startPoint.x) / displayScale, y: (point.y - startPoint.y) / displayScale)
        switch interaction {
        case .pan: pan = CGPoint(x: panStart.x + point.x - startPoint.x, y: panStart.y + point.y - startPoint.y)
        case .image: if let initialState { store.moveImage(to: CGPoint(x: initialState.imageCenter.x + delta.x, y: initialState.imageCenter.y + delta.y)) }
        case .crop: if let initialState { store.moveCrop(from: initialState, delta: delta) }
        case .resize(let handle): if let initialState { store.resizeCrop(from: initialState, handle: handle, delta: delta, minimum: 24 / displayScale, keepAspect: event.modifierFlags.contains(.shift)) }
        case .straighten: straighteningLine = (startPoint, point)
        case .rotate:
            if let initialState {
                let pivot = viewPoint(CGPoint(x: initialState.rect.midX, y: initialState.rect.midY))
                let startAngle = atan2(startPoint.y - pivot.y, startPoint.x - pivot.x)
                let endAngle = atan2(point.y - pivot.y, point.x - pivot.x)
                let delta = atan2(sin(endAngle - startAngle), cos(endAngle - startAngle)) * 180 / .pi
                var angle = initialState.straighten + delta
                if event.modifierFlags.contains(.shift) { angle = (angle / 15).rounded() * 15 }
                store.setStraighten(angle)
            }
        case .watermark(let id):
            if let initialState, let watermark = initialState.watermarks.first(where: { $0.id == id }) {
                let localDelta = CanvasGeometry.rotate(delta, by: -initialState.rotation)
                store.editWatermark(id) { $0.offset = CGSize(width: watermark.offset.width + localDelta.x / initialState.imageScale,
                                                           height: watermark.offset.height + localDelta.y / initialState.imageScale) }
            }
        case .watermarkScale(let id):
            if let initialState, let watermark = initialState.watermarks.first(where: { $0.id == id }) {
                let local = watermarkPoint(worldPoint(point), watermark: watermark)
                let width = imageSize.width * 0.3
                store.editWatermark(id) { $0.scale = min(5, max(0.02, hypot(local.x, local.y) * 2 / hypot(width, width * watermark.image.size.height / watermark.image.size.width))) }
            }
        case .watermarkRotate(let id):
            if let initialState, let watermark = initialState.watermarks.first(where: { $0.id == id }) {
                let start = watermarkPoint(worldPoint(startPoint), watermark: watermark)
                let end = watermarkPoint(worldPoint(point), watermark: watermark)
                let angle = watermark.rotation + Double(atan2(end.y, end.x) - atan2(start.y, start.x)) * 180 / .pi
                store.editWatermark(id) { $0.rotation = ((angle + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180 }
            }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if case .straighten = interaction, let line = straighteningLine, hypot(line.1.x - line.0.x, line.1.y - line.0.y) > 12,
           let initialState {
            var angle = atan2(line.1.y - line.0.y, line.1.x - line.0.x) * 180 / .pi
            angle = ((angle + 45).truncatingRemainder(dividingBy: 90) + 90).truncatingRemainder(dividingBy: 90) - 45
            store?.setStraighten(initialState.straighten - angle)
        }
        store?.endChange(); straighteningLine = nil
        interaction = nil; initialState = nil; needsDisplay = true
    }
    private func eventPoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    override func keyDown(with event: NSEvent) {
        guard let store, !store.isSaving else { return }
        if event.keyCode == 49 { spacePressed = true; NSCursor.openHand.set(); return }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "z" { event.modifierFlags.contains(.shift) ? store.redo() : store.undo(); needsDisplay = true; return }
        }
        if event.keyCode == 51 || event.keyCode == 117 { store.deleteWatermark(); return }
        if event.charactersIgnoringModifiers?.lowercased() == "q" { resetViewport(); return }
        if [123,124,125,126].contains(event.keyCode) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta = CGPoint(x: event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0),
                                y: event.keyCode == 126 ? -step : (event.keyCode == 125 ? step : 0))
            if store.tool == .watermark, let id = store.selectedWatermarkID {
                store.editWatermark(id) { $0.offset.width += delta.x; $0.offset.height += delta.y }
            } else { store.moveCrop(from: store.state, delta: delta) }
            needsDisplay = true; return
        }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spacePressed = false; NSCursor.arrow.set() } else { super.keyUp(with: event) } }
    override func scrollWheel(with event: NSEvent) {
        guard let store, !store.isSaving else { return }
        if event.modifierFlags.contains(.option) { zoomAround(point: eventPoint(event), factor: 1 + max(-0.25, min(0.25, event.scrollingDeltaY * 0.01))); return }
        if spacePressed { pan.x -= event.scrollingDeltaX; pan.y -= event.scrollingDeltaY }
        else {
            beginTimedGesture()
            store.moveImage(to: CGPoint(x: store.state.imageCenter.x - event.scrollingDeltaX / displayScale,
                                        y: store.state.imageCenter.y - event.scrollingDeltaY / displayScale))
        }
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard let store, !store.isSaving else { return }
        beginTimedGesture()
        store.setImageScale(store.state.imageScale * max(0.5, 1 + event.magnification), around: worldPoint(eventPoint(event)))
        needsDisplay = true
    }
    private func beginTimedGesture() {
        store?.beginChange(); gestureEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.store?.endChange() }
        gestureEndWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func zoomAround(point: CGPoint, factor: CGFloat) {
        let world = worldPoint(point); zoom = min(12, max(0.2, zoom * factor)); let newOrigin = CGPoint(x: point.x - world.x * displayScale, y: point.y - world.y * displayScale)
        pan = CGPoint(x: newOrigin.x - (bounds.midX - viewportCenter.x * displayScale), y: newOrigin.y - (bounds.midY - viewportCenter.y * displayScale)); store?.displayedZoom = zoom; needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        spacePressed = false; interaction = nil; straighteningLine = nil
        gestureEndWork?.cancel(); store?.endChange(); NSCursor.arrow.set()
        return super.resignFirstResponder()
    }
    override func resetCursorRects() {
        guard let store else { return }
        if spacePressed { addCursorRect(bounds, cursor: .openHand); return }
        addCursorRect(bounds, cursor: store.tool == .straighten ? .crosshair : .openHand)
        if store.tool == .crop {
            let rect = store.state.rect
            let frame = CGRect(origin: viewPoint(rect.origin), size: CGSize(width: rect.width * displayScale, height: rect.height * displayScale))
            for region in [CGRect(x: frame.minX - 32, y: frame.minY - 32, width: frame.width + 64, height: 24),
                           CGRect(x: frame.minX - 32, y: frame.maxY + 8, width: frame.width + 64, height: 24),
                           CGRect(x: frame.minX - 32, y: frame.minY - 8, width: 24, height: frame.height + 16),
                           CGRect(x: frame.maxX + 8, y: frame.minY - 8, width: 24, height: frame.height + 16)] {
                addCursorRect(region.intersection(bounds), cursor: Self.rotationCursor)
            }
            addCursorRect(CGRect(x: frame.minX - 6, y: frame.minY - 6, width: frame.width + 12, height: 12), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: frame.minX - 6, y: frame.maxY - 6, width: frame.width + 12, height: 12), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: frame.minX - 6, y: frame.minY - 6, width: 12, height: frame.height + 12), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: frame.maxX - 6, y: frame.minY - 6, width: 12, height: frame.height + 12), cursor: .resizeLeftRight)
            let rotationPoint = rotationHandlePoint
            addCursorRect(CGRect(x: rotationPoint.x - 13, y: rotationPoint.y - 13, width: 26, height: 26), cursor: Self.rotationCursor)
            for handle in CropHandle.allCases {
                let point = viewPoint(handle.point(on: store.state.rect))
                let direction = handle.direction
                addCursorRect(CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24),
                              cursor: direction.x == 0 ? .resizeUpDown : (direction.y == 0 ? .resizeLeftRight : .crosshair))
            }
        }
    }
    private func watermarkSize(_ watermark: OverlayWatermark) -> CGSize {
        let width = imageSize.width * 0.3 * watermark.scale
        return CGSize(width: width, height: width * watermark.image.size.height / max(1, watermark.image.size.width))
    }
    private func watermarkPoint(_ world: CGPoint, watermark: OverlayWatermark) -> CGPoint {
        guard let store else { return .zero }
        let local = CanvasGeometry.localPoint(world, center: store.state.imageCenter, rotation: store.state.rotation)
        return CanvasGeometry.localPoint(CGPoint(x: local.x / store.state.imageScale, y: local.y / store.state.imageScale),
                                         center: CGPoint(x: watermark.offset.width, y: watermark.offset.height), rotation: CGFloat(watermark.rotation))
    }
    private func watermarkHandle(at world: CGPoint, watermark: OverlayWatermark) -> Interaction? {
        let point = watermarkPoint(world, watermark: watermark), size = watermarkSize(watermark)
        let tolerance = 12 / displayScale / (store?.state.imageScale ?? 1)
        if hypot(point.x - size.width / 2, point.y - size.height / 2) < tolerance { return .watermarkScale(watermark.id) }
        if hypot(point.x, point.y + size.height / 2 + 26 / displayScale / (store?.state.imageScale ?? 1)) < tolerance { return .watermarkRotate(watermark.id) }
        return nil
    }
    private func drawWatermarkSelection(_ watermark: OverlayWatermark, context: CGContext) {
        guard let store else { return }
        context.saveGState()
        context.translateBy(x: store.state.imageCenter.x, y: store.state.imageCenter.y)
        context.rotate(by: store.state.rotation * .pi / 180); context.scaleBy(x: store.state.imageScale, y: store.state.imageScale)
        context.translateBy(x: watermark.offset.width, y: watermark.offset.height); context.rotate(by: CGFloat(watermark.rotation) * .pi / 180)
        let size = watermarkSize(watermark), scale = displayScale * store.state.imageScale
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1.5 / scale)
        context.stroke(CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        let rotationY = -size.height / 2 - 26 / scale
        context.move(to: CGPoint(x: 0, y: -size.height / 2)); context.addLine(to: CGPoint(x: 0, y: rotationY)); context.strokePath()
        for point in [CGPoint(x: size.width / 2, y: size.height / 2), CGPoint(x: 0, y: rotationY)] {
            context.setFillColor(NSColor.white.cgColor)
            let radius = 5 / scale
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        context.restoreGState()
    }
}
