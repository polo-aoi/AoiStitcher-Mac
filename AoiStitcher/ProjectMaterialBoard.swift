import AppKit
import SwiftUI

/// The document view uses saved, absolute positions; filtering never reflows the library.
struct ProjectMaterialBoard: NSViewRepresentable {
    static let assetPasteboardType = NSPasteboard.PasteboardType("com.aoipic.project-assets")

    var assets: [ProjectAsset]
    @Binding var selection: Set<UUID>
    var thumbnailSize: CGFloat
    @Binding var viewZoom: Double
    var fitRequest: Int
    var thumbnails: [UUID: NSImage]
    var badges: [UUID: String]
    var onMove: ([UUID: CGPoint]) -> Void
    var onImport: ([URL], CGPoint) -> Void
    var onActivate: (UUID) -> Void
    var onVisibleAssets: (Set<UUID>) -> Void = { _ in }
    var onViewportChange: (CGSize) -> Void = { _ in }
    var showsRatingsAndColors: Bool = true
    var operations: [ProjectOperation] = ProjectOperation.allCases
    var onSend: (ProjectOperation, Set<UUID>) -> Void = { _, _ in }
    var onRate: (Set<UUID>, Int) -> Void = { _, _ in }
    var onColor: (Set<UUID>, ProjectColorLabel) -> Void = { _, _ in }
    var onRemove: (Set<UUID>) -> Void = { _ in }
    var onImportPanel: () -> Void = {}
    var onUndo: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ProjectMaterialScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.masksToBounds = true
        scroll.documentView = ProjectMaterialDocumentView(frame: .zero)
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let board = scroll.documentView as? ProjectMaterialDocumentView else { return }
        let selectionBinding = $selection
        let zoomBinding = $viewZoom
        board.onSelectionChange = { selectionBinding.wrappedValue = $0 }
        board.onMove = onMove
        board.onImport = onImport
        board.onActivate = onActivate
        board.onVisibleAssets = onVisibleAssets
        board.onViewportChange = onViewportChange
        board.onSend = onSend
        board.onRate = onRate
        board.onColor = onColor
        board.onRemove = onRemove
        board.onImportPanel = onImportPanel
        board.onUndo = onUndo
        board.onZoomChange = { zoomBinding.wrappedValue = Double($0) }
        board.configure(assets: assets, selection: selection, thumbnailSize: thumbnailSize,
                        viewZoom: viewZoom, fitRequest: fitRequest, thumbnails: thumbnails, badges: badges,
                        showsRatingsAndColors: showsRatingsAndColors, operations: operations)
    }
}

private final class ProjectMaterialScrollView: NSScrollView {
    override func tile() {
        super.tile()
        (documentView as? ProjectMaterialDocumentView)?.updateDocumentSize()
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        (documentView as? ProjectMaterialDocumentView)?.scheduleVisibleAssetsReport()
    }
}

private final class ProjectMaterialDocumentView: NSView, NSDraggingSource {
    var onSelectionChange: ((Set<UUID>) -> Void)?
    var onMove: (([UUID: CGPoint]) -> Void)?
    var onImport: (([URL], CGPoint) -> Void)?
    var onActivate: ((UUID) -> Void)?
    var onVisibleAssets: ((Set<UUID>) -> Void)?
    var onViewportChange: ((CGSize) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?
    var onSend: ((ProjectOperation, Set<UUID>) -> Void)?
    var onRate: ((Set<UUID>, Int) -> Void)?
    var onColor: ((Set<UUID>, ProjectColorLabel) -> Void)?
    var onRemove: ((Set<UUID>) -> Void)?
    var onImportPanel: (() -> Void)?
    var onUndo: (() -> Void)?

    private var assets: [ProjectAsset] = []
    private var selectedIDs: Set<UUID> = []
    private var thumbnails: [UUID: NSImage] = [:]
    private var badges: [UUID: String] = [:]
    private var showsRatingsAndColors = true
    private var operations: [ProjectOperation] = []
    private var contextMenuSelection: Set<UUID> = []
    private var thumbnailSize: CGFloat = 120
    private var zoom: CGFloat = 1
    private let contentMargin: CGFloat = 24
    private var lastConfiguredZoom: CGFloat?
    private var lastFitRequest = 0
    private var pendingFit = false
    private var isUpdatingDocumentSize = false
    private var zoomReportScheduled = false
    private var lastReportedViewport: CGSize?
    private var tooltipOwners: [NSString] = []
    private var mouseDownPoint = CGPoint.zero
    private var mouseDownAssetID: UUID?
    private var selectOnMouseUp: UUID?
    private var marqueeStart: CGPoint?
    private var marqueeRect: CGRect?
    private var marqueeBaseSelection: Set<UUID> = []
    private var dragContext: MaterialDrag?
    private var dropPreview: [UUID: CGPoint] = [:]
    private var extraDragExtent = CGSize.zero
    private var acceptsFileDrop = false
    private var lastVisibleIDs: Set<UUID>?
    private var visibleAssetsReportScheduled = false

    private struct MaterialDrag {
        var ids: [UUID]
        var positions: [UUID: CGPoint]
        var startPoint: CGPoint
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([ProjectMaterialBoard.assetPasteboardType, .fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("项目素材库")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(assets: [ProjectAsset], selection: Set<UUID>, thumbnailSize: CGFloat,
                   viewZoom: Double, fitRequest: Int, thumbnails: [UUID: NSImage], badges: [UUID: String],
                   showsRatingsAndColors: Bool, operations: [ProjectOperation]) {
        self.assets = assets
        selectedIDs = selection
        self.thumbnailSize = min(320, max(60, thumbnailSize))
        self.thumbnails = thumbnails
        self.badges = badges
        self.showsRatingsAndColors = showsRatingsAndColors
        self.operations = operations
        if dragContext == nil { dropPreview = [:] }
        setAccessibilityValue("显示 \(assets.count) 张图片，已选 \(selection.count) 张")
        let requestedZoom = clampedZoom(CGFloat(viewZoom))
        // A fit/pinch can change the AppKit viewport before its asynchronous binding update arrives.
        // Repeated configuration with that old binding value must not undo the new viewport.
        if lastConfiguredZoom != requestedZoom {
            lastConfiguredZoom = requestedZoom
            applyZoom(requestedZoom)
        }
        if lastFitRequest != fitRequest {
            lastFitRequest = fitRequest
            pendingFit = true
        }
        updateDocumentSize()
        needsDisplay = true
    }

    private var cardSize: CGSize { CGSize(width: thumbnailSize + 16, height: thumbnailSize + 62) }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(2, max(0.02, value)) : 1
    }

    private func logicalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - contentMargin) / zoom, y: (point.y - contentMargin) / zoom)
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * zoom + contentMargin, y: rect.minY * zoom + contentMargin,
               width: rect.width * zoom, height: rect.height * zoom)
    }

    private func logicalCardRect(_ asset: ProjectAsset, at position: CGPoint? = nil) -> CGRect {
        CGRect(origin: position ?? asset.position, size: cardSize)
    }

    private func cardRect(_ asset: ProjectAsset, at position: CGPoint? = nil) -> CGRect {
        viewRect(logicalCardRect(asset, at: position))
    }

    func updateDocumentSize() {
        guard !isUpdatingDocumentSize else { return }
        isUpdatingDocumentSize = true
        defer { isUpdatingDocumentSize = false }
        let viewport = enclosingScrollView?.contentView.bounds.size ?? .zero
        var size = CGSize(width: max(1, viewport.width), height: max(1, viewport.height))
        for asset in assets {
            var rect = cardRect(asset)
            if let preview = dropPreview[asset.id] { rect = rect.union(cardRect(asset, at: preview)) }
            size.width = max(size.width, rect.maxX + contentMargin)
            size.height = max(size.height, rect.maxY + contentMargin)
        }
        size.width = max(size.width, extraDragExtent.width)
        size.height = max(size.height, extraDragExtent.height)
        if frame.size != size { setFrameSize(size) }
        scheduleVisibleAssetsReport()
    }

    private func scroll(to point: CGPoint) {
        guard let scroll = enclosingScrollView else { return }
        let viewport = scroll.contentView.bounds.size
        let origin = CGPoint(x: min(max(0, point.x), max(0, frame.width - viewport.width)),
                             y: min(max(0, point.y), max(0, frame.height - viewport.height)))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func applyZoom(_ requestedZoom: CGFloat, anchoredAt point: CGPoint? = nil) {
        let target = clampedZoom(requestedZoom)
        guard abs(target - zoom) > 0.000001 else { return }
        let visible = enclosingScrollView?.contentView.bounds ?? visibleRect
        let anchor = point ?? CGPoint(x: visible.midX, y: visible.midY)
        let logicalAnchor = logicalPoint(anchor)
        let viewportAnchor = CGPoint(x: anchor.x - visible.minX, y: anchor.y - visible.minY)
        zoom = target
        updateDocumentSize()
        scroll(to: CGPoint(x: logicalAnchor.x * zoom + contentMargin - viewportAnchor.x,
                           y: logicalAnchor.y * zoom + contentMargin - viewportAnchor.y))
        needsDisplay = true
    }

    private func fitVisibleAssets() {
        guard let viewport = enclosingScrollView?.contentView.bounds.size,
              viewport.width > 1, viewport.height > 1 else { return }
        pendingFit = false
        guard let first = assets.first else {
            applyZoom(1)
            scroll(to: .zero)
            scheduleZoomReport()
            return
        }
        let bounds = assets.dropFirst().reduce(logicalCardRect(first)) { $0.union(logicalCardRect($1)) }
        let margin = contentMargin
        let available = CGSize(width: max(1, viewport.width - margin * 2),
                               height: max(1, viewport.height - margin * 2))
        zoom = clampedZoom(min(available.width / max(1, bounds.width),
                              available.height / max(1, bounds.height)))
        updateDocumentSize()
        scroll(to: CGPoint(x: bounds.midX * zoom + contentMargin - viewport.width / 2,
                           y: bounds.midY * zoom + contentMargin - viewport.height / 2))
        scheduleZoomReport()
        needsDisplay = true
    }

    private func scheduleZoomReport() {
        guard !zoomReportScheduled else { return }
        zoomReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.zoomReportScheduled = false
            self.onZoomChange?(self.zoom)
        }
    }

    override func magnify(with event: NSEvent) {
        guard dragContext == nil, marqueeStart == nil else { return }
        applyZoom(zoom * (1 + event.magnification), anchoredAt: convert(event.locationInWindow, from: nil))
        scheduleZoomReport()
    }

    func scheduleVisibleAssetsReport() {
        guard !visibleAssetsReportScheduled else { return }
        visibleAssetsReportScheduled = true
        // Read geometry after SwiftUI's update and AppKit's layout. No binding is mutated inside updateNSView.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibleAssetsReportScheduled = false
            if self.pendingFit { self.fitVisibleAssets() }
            let viewport = self.enclosingScrollView?.contentView.bounds.size ?? .zero
            if self.lastReportedViewport != viewport {
                self.lastReportedViewport = viewport
                self.onViewportChange?(viewport)
            }
            let visible = self.visibleRect
            let prefetchRect = visible.insetBy(dx: -80, dy: -80)
            let candidates = self.assets.filter { self.cardRect($0).intersects(prefetchRect) }
            // The library selects a thumbnail resolution for the current zoom. Keep every visible
            // asset eligible so a fit-to-all overview does not turn its outer photos into placeholders.
            let ids = Set(candidates.map(\.id))
            self.updateTooltips(for: candidates.filter { self.cardRect($0).intersects(visible) })
            guard self.lastVisibleIDs != ids else { return }
            self.lastVisibleIDs = ids
            self.onVisibleAssets?(ids)
        }
    }

    private func updateTooltips(for visibleAssets: [ProjectAsset]) {
        removeAllToolTips()
        tooltipOwners = visibleAssets.map { asset in
            var lines = [asset.name, badges[asset.id] ?? "尚未导出"]
            if asset.rating > 0 { lines.append("评分：\(asset.rating) 星") }
            if asset.colorLabel != .none { lines.append("颜色标签：\(asset.colorLabel.title)") }
            return lines.joined(separator: "\n") as NSString
        }
        for (asset, tooltip) in zip(visibleAssets, tooltipOwners) {
            addToolTip(cardRect(asset), owner: tooltip, userData: nil)
        }
    }

    private func asset(at point: CGPoint) -> ProjectAsset? {
        assets.reversed().first { cardRect($0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let draggedIDs = Set(dragContext?.ids ?? [])
        for asset in assets where cardRect(asset).intersects(dirtyRect) {
            drawCard(asset, at: asset.position, alpha: draggedIDs.contains(asset.id) ? 0.35 : 1)
        }
        for asset in assets {
            if let position = dropPreview[asset.id], cardRect(asset, at: position).intersects(dirtyRect) {
                drawCard(asset, at: position, alpha: 0.8)
            }
        }
        if let marqueeRect {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            marqueeRect.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let outline = NSBezierPath(rect: marqueeRect)
            outline.lineWidth = 1
            outline.stroke()
        }
        if acceptsFileDrop {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(roundedRect: visibleRect.insetBy(dx: 8, dy: 8), xRadius: 12, yRadius: 12)
            outline.lineWidth = 2
            outline.setLineDash([6, 4], count: 2, phase: 0)
            outline.stroke()
        }
    }

    private func drawCard(_ asset: ProjectAsset, at position: CGPoint, alpha: CGFloat) {
        guard let graphics = NSGraphicsContext.current else { return }
        graphics.saveGraphicsState()
        defer { graphics.restoreGraphicsState() }
        graphics.cgContext.setAlpha(alpha)
        let rect = cardRect(asset, at: position)
        // Keep all drawing inside the same scaled hit region, including minimum-size labels.
        graphics.cgContext.clip(to: rect)
        if selectedIDs.contains(asset.id) {
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: min(1, rect.width / 8), dy: min(1, rect.height / 8)),
                                    xRadius: min(8, rect.width / 8), yRadius: min(8, rect.height / 8))
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            card.fill()
            NSColor.controlAccentColor.setStroke()
            card.lineWidth = 1.5
            card.stroke()
        }
        let imageRect = viewRect(CGRect(x: position.x + 8, y: position.y + 8,
                                       width: thumbnailSize, height: thumbnailSize))
        if let image = thumbnails[asset.id], image.size.width > 0, image.size.height > 0 {
            let scale = min(imageRect.width / image.size.width, imageRect.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let destination = CGRect(x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2,
                                     width: size.width, height: size.height)
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else if let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) {
            let side = min(36 * zoom, imageRect.width)
            let symbolRect = CGRect(x: imageRect.midX - side / 2, y: imageRect.midY - side / 2, width: side, height: side)
            placeholder.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 0.4,
                             respectFlipped: true, hints: nil)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let titleFont = max(9, min(16, 12 * zoom))
        let titleY = imageRect.maxY + max(2, 7 * zoom)
        guard rect.width >= 36, rect.maxY - titleY >= titleFont + 2 else { return }
        let titleRect = CGRect(x: rect.minX + 3 * zoom, y: titleY,
                               width: rect.width - 6 * zoom, height: titleFont + 5)
        (asset.name as NSString).draw(in: titleRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: titleFont), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        drawRatingAndColor(asset, below: titleRect, in: rect)
    }

    private func drawRatingAndColor(_ asset: ProjectAsset, below titleRect: CGRect, in cardRect: CGRect) {
        guard showsRatingsAndColors, asset.rating > 0 || asset.colorLabel != .none else { return }
        let font = NSFont.systemFont(ofSize: max(9, min(13, 10 * zoom)))
        let rowY = titleRect.maxY + 2 * zoom
        guard cardRect.maxY - rowY >= font.pointSize + 3 else { return }
        let rating = String(repeating: "★", count: min(5, max(0, asset.rating))) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor
        ]
        let ratingWidth = rating.size(withAttributes: attributes).width
        let colorSize = asset.colorLabel == .none ? 0 : min(10, max(7, 8 * zoom))
        let gap: CGFloat = ratingWidth > 0 && colorSize > 0 ? 6 : 0
        let rowWidth = ratingWidth + colorSize + gap
        guard rowWidth <= cardRect.width - 6 else { return }
        let rowX = cardRect.midX - rowWidth / 2
        rating.draw(at: CGPoint(x: rowX, y: rowY), withAttributes: attributes)
        if let color = displayColor(asset.colorLabel) {
            color.setFill()
            NSBezierPath(roundedRect: CGRect(x: rowX + ratingWidth + gap,
                                             y: rowY + (font.pointSize + 2 - colorSize) / 2,
                                             width: colorSize, height: colorSize),
                         xRadius: 2, yRadius: 2).fill()
        }
    }

    private func displayColor(_ label: ProjectColorLabel) -> NSColor? {
        switch label {
        case .none: return nil
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        }
    }

    private func updateSelection(_ ids: Set<UUID>) {
        guard selectedIDs != ids else { return }
        selectedIDs = ids
        onSelectionChange?(ids)
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        clearMouseInteraction()
        let menu = NSMenu(title: "项目素材")
        menu.autoenablesItems = false
        let point = convert(event.locationInWindow, from: nil)
        if let hit = asset(at: point) {
            if !selectedIDs.contains(hit.id) { updateSelection([hit.id]) }
            contextMenuSelection = selectedIDs
            let selectedAssets = assets.filter { contextMenuSelection.contains($0.id) }

            let sendItem = NSMenuItem(title: "发送到", action: nil, keyEquivalent: "")
            let sendMenu = NSMenu(title: sendItem.title)
            sendMenu.autoenablesItems = false
            for operation in operations {
                let item = actionItem(operation.title, action: #selector(sendFromMenu(_:)))
                item.representedObject = operation.rawValue
                item.image = NSImage(systemSymbolName: operation.systemImage, accessibilityDescription: nil)
                sendMenu.addItem(item)
            }
            sendItem.submenu = sendMenu
            menu.addItem(sendItem)
            menu.addItem(.separator())

            let ratingItem = NSMenuItem(title: "评分", action: nil, keyEquivalent: "")
            let ratingMenu = NSMenu(title: ratingItem.title)
            ratingMenu.autoenablesItems = false
            for rating in 0...5 {
                let item = actionItem(rating == 0 ? "无星" : "\(rating) 星",
                                      action: #selector(rateFromMenu(_:)), key: String(rating))
                item.tag = rating
                item.state = menuState(matches: selectedAssets.filter { $0.rating == rating }.count,
                                       total: selectedAssets.count)
                ratingMenu.addItem(item)
            }
            ratingItem.submenu = ratingMenu
            menu.addItem(ratingItem)

            let colorItem = NSMenuItem(title: "颜色标签", action: nil, keyEquivalent: "")
            let colorMenu = NSMenu(title: colorItem.title)
            colorMenu.autoenablesItems = false
            let labels: [ProjectColorLabel] = [.none, .red, .yellow, .green, .blue, .purple]
            let shortcuts = ["", "6", "7", "8", "9", ""]
            for (label, key) in zip(labels, shortcuts) {
                let item = actionItem(label.title, action: #selector(colorFromMenu(_:)), key: key)
                item.representedObject = label.rawValue
                item.state = menuState(matches: selectedAssets.filter { $0.colorLabel == label }.count,
                                       total: selectedAssets.count)
                if let color = displayColor(label) {
                    item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                        color.setFill()
                        NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
                        return true
                    }
                }
                colorMenu.addItem(item)
            }
            colorItem.submenu = colorMenu
            menu.addItem(colorItem)
            menu.addItem(.separator())
            menu.addItem(actionItem("从项目移除", action: #selector(removeFromMenu(_:)), key: "\u{8}"))
            menu.addItem(.separator())
        } else {
            // A background menu must never apply batch actions to an earlier selection.
            contextMenuSelection = []
        }
        let importItem = actionItem("导入照片或文件夹到项目…", action: #selector(importFromMenu(_:)), key: "i")
        importItem.keyEquivalentModifierMask = .command
        menu.addItem(importItem)
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        contextMenuSelection = []
    }

    private func actionItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = []
        return item
    }

    private func menuState(matches: Int, total: Int) -> NSControl.StateValue {
        guard matches > 0 else { return .off }
        return matches == total ? .on : .mixed
    }

    @objc private func sendFromMenu(_ item: NSMenuItem) {
        guard !contextMenuSelection.isEmpty, let raw = item.representedObject as? String,
              let operation = ProjectOperation(rawValue: raw) else { return }
        onSend?(operation, contextMenuSelection)
    }

    @objc private func rateFromMenu(_ item: NSMenuItem) {
        guard !contextMenuSelection.isEmpty else { return }
        onRate?(contextMenuSelection, item.tag)
    }

    @objc private func colorFromMenu(_ item: NSMenuItem) {
        guard !contextMenuSelection.isEmpty, let raw = item.representedObject as? String,
              let color = ProjectColorLabel(rawValue: raw) else { return }
        onColor?(contextMenuSelection, color)
    }

    @objc private func removeFromMenu(_ item: NSMenuItem) {
        guard !contextMenuSelection.isEmpty else { return }
        onRemove?(contextMenuSelection)
    }

    @objc private func importFromMenu(_ item: NSMenuItem) { onImportPanel?() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownAssetID = nil
        selectOnMouseUp = nil
        marqueeStart = nil
        marqueeRect = nil
        let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        guard let hit = asset(at: mouseDownPoint) else {
            marqueeBaseSelection = additive ? selectedIDs : []
            updateSelection(marqueeBaseSelection)
            marqueeStart = mouseDownPoint
            return
        }
        if event.modifierFlags.contains(.command) {
            var updated = selectedIDs
            if !updated.insert(hit.id).inserted { updated.remove(hit.id) }
            updateSelection(updated)
        } else if event.modifierFlags.contains(.shift) {
            updateSelection(selectedIDs.union([hit.id]))
        } else if !selectedIDs.contains(hit.id) {
            updateSelection([hit.id])
        } else {
            // Keep the existing group until we know whether this is a click or a drag.
            selectOnMouseUp = hit.id
        }
        if event.clickCount == 2 {
            selectOnMouseUp = nil
            onActivate?(hit.id)
        } else if selectedIDs.contains(hit.id) {
            mouseDownAssetID = hit.id
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragContext == nil else { return }
        if let start = marqueeStart {
            autoscroll(with: event)
            let point = convert(event.locationInWindow, from: nil)
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            marqueeRect = rect
            let covered = assets.filter { cardRect($0).intersects(rect) }.map(\.id)
            updateSelection(marqueeBaseSelection.union(covered))
            needsDisplay = true
            return
        }
        guard mouseDownAssetID != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= 4 else { return }
        beginMaterialDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        if let id = selectOnMouseUp, dragContext == nil { updateSelection([id]) }
        clearMouseInteraction()
    }

    private func clearMouseInteraction() {
        mouseDownAssetID = nil
        selectOnMouseUp = nil
        marqueeStart = nil
        marqueeRect = nil
        needsDisplay = true
    }

    private func beginMaterialDrag(_ event: NSEvent) {
        let dragged = assets.filter { selectedIDs.contains($0.id) }
        guard !dragged.isEmpty,
              let data = try? JSONEncoder().encode(dragged.map { $0.id.uuidString }) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: ProjectMaterialBoard.assetPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = dragImage(for: dragged)
        let point = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(CGRect(x: point.x - 36, y: point.y - 36,
                                             width: image.size.width, height: image.size.height), contents: image)
        dragContext = MaterialDrag(ids: dragged.map(\.id),
                                   positions: Dictionary(uniqueKeysWithValues: dragged.map { ($0.id, $0.position) }),
                                   startPoint: logicalPoint(mouseDownPoint))
        selectOnMouseUp = nil
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        needsDisplay = true
    }

    private func dragImage(for dragged: [ProjectAsset]) -> NSImage {
        let size = NSSize(width: 116, height: 132)
        return NSImage(size: size, flipped: true) { [thumbnails] rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
            if let asset = dragged.first, let thumbnail = thumbnails[asset.id],
               thumbnail.size.width > 0, thumbnail.size.height > 0 {
                let scale = min(100 / thumbnail.size.width, 100 / thumbnail.size.height)
                let width = thumbnail.size.width * scale
                let height = thumbnail.size.height * scale
                thumbnail.draw(in: CGRect(x: 58 - width / 2, y: 56 - height / 2, width: width, height: height),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            ("\(dragged.count) 张图片" as NSString).draw(in: CGRect(x: 4, y: 110, width: 108, height: 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                 .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragContext = nil
        dropPreview = [:]
        extraDragExtent = .zero
        acceptsFileDrop = false
        clearMouseInteraction()
        updateDocumentSize()
    }

    private func isInternalDrag(_ sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? ProjectMaterialDocumentView else { return false }
        return source === self && dragContext != nil
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isInternalDrag(sender) {
            autoscrollDrag(sender)
            dropPreview = movedPositions(to: convert(sender.draggingLocation, from: nil))
            needsDisplay = true
            return .move
        }
        acceptsFileDrop = !fileURLs(sender).isEmpty
        needsDisplay = true
        return acceptsFileDrop ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropPreview = [:]
        acceptsFileDrop = false
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isInternalDrag(sender) || !fileURLs(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        if isInternalDrag(sender) {
            let positions = movedPositions(to: point)
            guard !positions.isEmpty else { return false }
            onMove?(positions)
            return true
        }
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        let logical = logicalPoint(point)
        onImport?(urls, CGPoint(x: max(0, logical.x), y: max(0, logical.y)))
        acceptsFileDrop = false
        needsDisplay = true
        return true
    }

    private func movedPositions(to point: CGPoint) -> [UUID: CGPoint] {
        guard let drag = dragContext else { return [:] }
        let minimumX = drag.positions.values.map(\.x).min() ?? 0
        let minimumY = drag.positions.values.map(\.y).min() ?? 0
        let logical = logicalPoint(point)
        let dx = max(-minimumX, logical.x - drag.startPoint.x)
        let dy = max(-minimumY, logical.y - drag.startPoint.y)
        return drag.positions.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    private func autoscrollDrag(_ sender: NSDraggingInfo) {
        guard let scroll = enclosingScrollView else { return }
        let point = convert(sender.draggingLocation, from: nil)
        let visible = visibleRect
        var origin = scroll.contentView.bounds.origin
        let threshold: CGFloat = 28
        let step: CGFloat = 14
        if point.x < visible.minX + threshold { origin.x -= step }
        if point.x > visible.maxX - threshold { origin.x += step }
        if point.y < visible.minY + threshold { origin.y -= step }
        if point.y > visible.maxY - threshold { origin.y += step }
        origin.x = max(0, origin.x)
        origin.y = max(0, origin.y)
        guard origin != scroll.contentView.bounds.origin else { return }
        extraDragExtent.width = max(extraDragExtent.width, origin.x + visible.width)
        extraDragExtent.height = max(extraDragExtent.height, origin.y + visible.height)
        updateDocumentSize()
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if handleCommandShortcut(event) {
            return
        } else if modifiers.isEmpty, let key = event.charactersIgnoringModifiers,
                  let rating = Int(key), (0...5).contains(rating), !selectedIDs.isEmpty {
            onRate?(selectedIDs, rating)
        } else if modifiers.isEmpty, let key = event.charactersIgnoringModifiers,
                  let label = ["6": ProjectColorLabel.red, "7": .yellow, "8": .green, "9": .blue][key],
                  !selectedIDs.isEmpty {
            onColor?(selectedIDs, label)
        } else if modifiers.isEmpty, [51, 117].contains(event.keyCode), !selectedIDs.isEmpty {
            onRemove?(selectedIDs)
        } else if event.keyCode == 53 {
            clearMouseInteraction()
            updateSelection([])
        } else if (event.keyCode == 36 || event.keyCode == 49), modifiers.isEmpty,
                  let selected = assets.first(where: { selectedIDs.contains($0.id) }) {
            onActivate?(selected.id)
        } else if [123, 124, 125, 126].contains(event.keyCode), modifiers.isSubset(of: [.shift]) {
            moveSelectionWithArrow(event.keyCode, step: modifiers.contains(.shift) ? 10 : 1)
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return handleCommandShortcut(event) || super.performKeyEquivalent(with: event)
    }

    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": updateSelection(Set(assets.map(\.id)))
        case "z": onUndo?()
        case "i": onImportPanel?()
        default: return false
        }
        return true
    }

    private func moveSelectionWithArrow(_ key: UInt16, step: CGFloat) {
        let selected = assets.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        var dx: CGFloat = key == 123 ? -step : (key == 124 ? step : 0)
        var dy: CGFloat = key == 126 ? -step : (key == 125 ? step : 0)
        dx = max(dx, -(selected.map { $0.position.x }.min() ?? 0))
        dy = max(dy, -(selected.map { $0.position.y }.min() ?? 0))
        guard dx != 0 || dy != 0 else { return }
        onMove?(Dictionary(uniqueKeysWithValues: selected.map {
            ($0.id, CGPoint(x: $0.position.x + dx, y: $0.position.y + dy))
        }))
    }
}
