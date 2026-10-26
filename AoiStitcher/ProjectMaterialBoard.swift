import AppKit
import Combine
import QuickLookUI
import SwiftUI

@MainActor
final class ProjectMaterialDragState: ObservableObject {
    static let shared = ProjectMaterialDragState()
    @Published var assetIDs: [UUID] = []
    private init() {}
}

/// Materials wrap to the viewport; group rows keep their compact horizontal layout.
struct ProjectMaterialBoard: NSViewRepresentable {
    static let assetPasteboardType = NSPasteboard.PasteboardType("com.aoipic.project-assets")

    var assets: [ProjectAsset]
    @Binding var selection: Set<UUID>
    var thumbnailSize: CGFloat
    @Binding var viewZoom: Double
    var fitRequest: Int
    var thumbnails: [UUID: NSImage]
    var assetURLs: [UUID: URL] = [:]
    var isActive = true
    var badges: [UUID: String]
    var onMove: ([UUID: CGPoint]) -> Void
    var onImport: ([URL], CGPoint) -> Void
    var onActivate: (UUID) -> Void
    var onVisibleAssets: (Set<UUID>) -> Void = { _ in }
    var onViewportChange: (CGSize) -> Void = { _ in }
    var operations: [ProjectOperation] = ProjectOperation.allCases
    var onSend: (ProjectOperation, Set<UUID>) -> Void = { _, _ in }
    var onGather: (Set<UUID>, CGPoint) -> Void = { _, _ in }
    var onUngroup: (Set<UUID>) -> Void = { _ in }
    var onRemove: (Set<UUID>) -> Void = { _ in }
    var onImportPanel: () -> Void = {}
    var onUndo: () -> Void = {}
    var isGroupRow = false
    var onFocus: () -> Void = {}
    var onDropAssets: ((Set<UUID>) -> Void)? = nil
    var focusRequest = 0
    var onReorder: (([UUID]) -> Void)? = nil
    var onThumbnailResize: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ProjectMaterialScrollView()
        scroll.isGroupRow = isGroupRow
        scroll.hasVerticalScroller = !isGroupRow
        scroll.hasHorizontalScroller = isGroupRow
        scroll.scrollerStyle = .overlay
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
        board.onGather = onGather
        board.onUngroup = onUngroup
        board.onRemove = onRemove
        board.onImportPanel = onImportPanel
        board.onUndo = onUndo
        board.isGroupRow = isGroupRow
        board.onFocus = onFocus
        board.onDropAssets = onDropAssets
        board.onReorder = onReorder
        board.onThumbnailResize = onThumbnailResize
        board.onZoomChange = { zoomBinding.wrappedValue = Double($0) }
        board.configure(assets: assets, selection: selection, thumbnailSize: thumbnailSize,
                        viewZoom: viewZoom, fitRequest: fitRequest, thumbnails: thumbnails, assetURLs: assetURLs,
                        badges: badges, operations: operations, isActive: isActive)
        board.requestFocus(focusRequest)
    }
}

private final class ProjectMaterialScrollView: ProjectOverlayScrollView {
    var isGroupRow = false

    override func scrollWheel(with event: NSEvent) {
        // Group rows scroll horizontally; a vertical wheel gesture belongs to
        // the outer list rather than an otherwise stationary photo strip.
        if isGroupRow, !event.modifierFlags.contains(.shift),
           abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func tile() {
        super.tile()
        (documentView as? ProjectMaterialDocumentView)?.updateDocumentSize()
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        (documentView as? ProjectMaterialDocumentView)?.scheduleVisibleAssetsReport()
    }
}

private final class ProjectMaterialDocumentView: NSView, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onSelectionChange: ((Set<UUID>) -> Void)?
    var onMove: (([UUID: CGPoint]) -> Void)?
    var onImport: (([URL], CGPoint) -> Void)?
    var onActivate: ((UUID) -> Void)?
    var onVisibleAssets: ((Set<UUID>) -> Void)?
    var onViewportChange: ((CGSize) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?
    var onSend: ((ProjectOperation, Set<UUID>) -> Void)?
    var onGather: ((Set<UUID>, CGPoint) -> Void)?
    var onUngroup: ((Set<UUID>) -> Void)?
    var onRemove: ((Set<UUID>) -> Void)?
    var onImportPanel: (() -> Void)?
    var onUndo: (() -> Void)?
    var isGroupRow = false
    var onFocus: (() -> Void)?
    var onDropAssets: ((Set<UUID>) -> Void)?
    var onReorder: (([UUID]) -> Void)?
    var onThumbnailResize: ((CGFloat) -> Void)?

    private var assets: [ProjectAsset] = []
    private var selectedIDs: Set<UUID> = []
    private var thumbnails: [UUID: NSImage] = [:]
    private var assetURLs: [UUID: URL] = [:]
    private var badges: [UUID: String] = [:]
    private var operations: [ProjectOperation] = []
    private var isActive = true
    private var contextMenuSelection: Set<UUID> = []
    private var contextMenuPoint = CGPoint.zero
    private var previewItems: [NSURL] = []
    private var pendingSelection: Set<UUID>?
    private var lastPublishedSelection: Set<UUID> = []
    private var lastExternalSelection: Set<UUID> = []
    private var geometry: [UUID: CGRect] = [:]
    private var assetIndices: [UUID: Int] = [:]
    private var spatialBuckets: [Bucket: Set<UUID>] = [:]
    private var geometryRevision = 0
    private var contentExtent = CGSize.zero
    private var gridLayout: ProjectMaterialGridLayout?
    private var layoutViewportWidth: CGFloat = -1
    private let marqueeLayer = CAShapeLayer()
    private let insertionLayer = CAShapeLayer()
    private var insertionIndex: Int?
    private lazy var titleAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        return [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph]
    }()
    private var tooltipRevision = -1
    private var tooltipAssetIDs: [UUID] = []

    private struct Bucket: Hashable {
        var x: Int
        var y: Int
    }
    private var thumbnailSize: CGFloat = 120
    private var zoom: CGFloat = 1
    private var contentMargin: CGFloat { isGroupRow ? 4 : 24 }
    private var lastConfiguredZoom: CGFloat?
    private var lastFitRequest = 0
    private var lastFocusRequest = 0
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
    private var extraDragExtent = CGSize.zero
    private var acceptsFileDrop = false
    private var lastVisibleIDs: Set<UUID>?
    private var visibleAssetsReportScheduled = false

    private struct MaterialDrag {
        var ids: [UUID]
        var positions: [UUID: CGPoint]
        var startPoint: CGPoint
        var sourceOrder: [UUID]
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isActive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        marqueeLayer.actions = ["path": NSNull(), "hidden": NSNull()]
        marqueeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        marqueeLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        marqueeLayer.lineWidth = 1
        layer?.addSublayer(marqueeLayer)
        insertionLayer.actions = ["path": NSNull(), "hidden": NSNull()]
        insertionLayer.fillColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(insertionLayer)
        registerForDraggedTypes([ProjectMaterialBoard.assetPasteboardType, .fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("项目素材库")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func requestFocus(_ request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marqueeLayer.frame = bounds
        insertionLayer.frame = bounds
        CATransaction.commit()
    }

    func configure(assets: [ProjectAsset], selection: Set<UUID>, thumbnailSize: CGFloat,
                   viewZoom: Double, fitRequest: Int, thumbnails: [UUID: NSImage], assetURLs: [UUID: URL],
                   badges: [UUID: String], operations: [ProjectOperation], isActive: Bool) {
        let activeChanged = self.isActive != isActive
        self.isActive = isActive
        if activeChanged {
            if isActive {
                registerForDraggedTypes([ProjectMaterialBoard.assetPasteboardType, .fileURL])
            } else {
                unregisterDraggedTypes()
            }
        }
        if !isActive {
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self {
                closePreview(panel, restoreFocus: false)
            }
            clearMouseInteraction()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        let assetGeometryChanged = self.assets.count != assets.count || zip(self.assets, assets).contains { previous, updated in
            previous.id != updated.id || previous.position != updated.position || previous.groupID != updated.groupID
        }
        let size = ProjectMaterialLayout(thumbnailSize: thumbnailSize).thumbnailSize
        let sizeChanged = self.thumbnailSize != size
        let badgeChanged = self.badges != badges
        let changedThumbnails: Set<UUID> = Set(thumbnails.compactMap { id, image in
            self.thumbnails[id] === image ? nil : id
        }).union(self.thumbnails.keys.filter { thumbnails[$0] == nil })
        self.assets = assets
        self.thumbnailSize = size
        self.thumbnails = thumbnails
        self.assetURLs = assetURLs
        self.badges = badges
        self.operations = operations
        if let pendingSelection {
            if selection == pendingSelection {
                self.pendingSelection = nil
                lastExternalSelection = selection
                lastPublishedSelection = selection
            } else if selection == lastPublishedSelection {
                // SwiftUI may acknowledge the previous marquee frame before the newest one is published.
                lastExternalSelection = selection
            } else if selection != lastExternalSelection {
                self.pendingSelection = nil
                lastExternalSelection = selection
                lastPublishedSelection = selection
                replaceSelection(selection)
            }
        } else {
            lastExternalSelection = selection
            lastPublishedSelection = selection
            replaceSelection(selection)
        }
        selectedIDs.formIntersection(Set(assets.map(\.id)))
        setAccessibilityValue("显示 \(assets.count) 张图片，已选 \(selectedIDs.count) 张")
        if assetGeometryChanged || sizeChanged { rebuildGeometry() }
        let requestedZoom = clampedZoom(CGFloat(viewZoom))
        if lastConfiguredZoom != requestedZoom {
            lastConfiguredZoom = requestedZoom
            applyZoom(requestedZoom)
        }
        if lastFitRequest != fitRequest {
            lastFitRequest = fitRequest
            pendingFit = true
        }
        if assetGeometryChanged || sizeChanged {
            updateDocumentSize()
            needsDisplay = true
        } else {
            invalidateCards(changedThumbnails)
        }
        if badgeChanged { tooltipRevision = -1 }
        scheduleVisibleAssetsReport()
    }

    private var cardSize: CGSize { ProjectMaterialLayout(thumbnailSize: thumbnailSize).cardSize }
    private var displayScale: CGFloat { isGroupRow ? zoom : (gridLayout?.scale ?? zoom) }

    private func rebuildGeometry() {
        if isGroupRow {
            gridLayout = nil
            geometry = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, viewRect(logicalCardRect($0))) })
        } else {
            let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
            layoutViewportWidth = width
            let layout = ProjectMaterialGridLayout(count: assets.count, viewportWidth: width,
                                                   thumbnailSize: thumbnailSize, zoom: zoom)
            gridLayout = layout
            geometry = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, layout.frame(at: $0.offset)) })
        }
        assetIndices = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
        spatialBuckets = [:]
        for (id, rect) in geometry {
            for bucket in buckets(intersecting: rect) { spatialBuckets[bucket, default: []].insert(id) }
        }
        contentExtent = geometry.values.reduce(CGSize.zero) { size, rect in
            CGSize(width: max(size.width, rect.maxX + contentMargin),
                   height: max(size.height, rect.maxY + contentMargin))
        }
        geometryRevision += 1
        clearInsertionMarker()
    }

    private func buckets(intersecting rect: CGRect) -> [Bucket] {
        let side: CGFloat = 256
        let x0 = Int(floor(rect.minX / side)), x1 = Int(floor(rect.maxX / side))
        let y0 = Int(floor(rect.minY / side)), y1 = Int(floor(rect.maxY / side))
        guard x1 >= x0, y1 >= y0 else { return [] }
        return (y0...y1).flatMap { y in (x0...x1).map { Bucket(x: $0, y: y) } }
    }

    private func assetIDs(intersecting rect: CGRect) -> Set<UUID> {
        let bucketCount = (floor(rect.width / 256) + 2) * (floor(rect.height / 256) + 2)
        if bucketCount > CGFloat(max(32, spatialBuckets.count * 2)) {
            return Set(geometry.compactMap { $0.value.intersects(rect) ? $0.key : nil })
        }
        let candidates = buckets(intersecting: rect).reduce(into: Set<UUID>()) {
            $0.formUnion(spatialBuckets[$1] ?? [])
        }
        return Set(candidates.filter { geometry[$0]?.intersects(rect) == true })
    }

    private func invalidateCards(_ ids: Set<UUID>) {
        for id in ids {
            if let rect = geometry[id] { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
        }
    }

    private func replaceSelection(_ ids: Set<UUID>) {
        let changed = selectedIDs.symmetricDifference(ids)
        selectedIDs = ids
        invalidateCards(changed)
    }

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
        if !isGroupRow, let rect = geometry[asset.id] { return rect }
        return viewRect(logicalCardRect(asset, at: position))
    }

    func updateDocumentSize() {
        guard !isUpdatingDocumentSize else { return }
        isUpdatingDocumentSize = true
        defer { isUpdatingDocumentSize = false }
        let viewport = enclosingScrollView?.contentView.bounds.size ?? .zero
        if !isGroupRow, layoutViewportWidth != viewport.width {
            rebuildGeometry()
            needsDisplay = true
        }
        var size = CGSize(width: max(1, viewport.width), height: max(1, viewport.height))
        if isGroupRow {
            size.width = max(size.width, contentExtent.width)
        } else {
            size.height = max(size.height, gridLayout?.height ?? 0)
        }
        if frame.size != size { setFrameSize(size) }
        if let scrollView = enclosingScrollView {
            let current = scrollView.contentView.bounds.origin
            let clamped = CGPoint(x: isGroupRow ? min(current.x, max(0, size.width - viewport.width)) : 0,
                                  y: isGroupRow ? 0 : min(current.y, max(0, size.height - viewport.height)))
            if current != clamped { scrollView.contentView.scroll(to: clamped) }
        }
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
        let anchorID = asset(at: anchor)?.id
        let previousAnchorFrame = anchorID.flatMap { geometry[$0] }
        let logicalAnchor = logicalPoint(anchor)
        let viewportAnchor = CGPoint(x: anchor.x - visible.minX, y: anchor.y - visible.minY)
        zoom = target
        rebuildGeometry()
        updateDocumentSize()
        if !isGroupRow, let anchorID, let previousAnchorFrame, let frame = geometry[anchorID] {
            let relativeY = (anchor.y - previousAnchorFrame.minY) / max(1, previousAnchorFrame.height)
            scroll(to: CGPoint(x: 0, y: frame.minY + relativeY * frame.height - viewportAnchor.y))
        } else {
            scroll(to: CGPoint(x: logicalAnchor.x * zoom + contentMargin - viewportAnchor.x,
                               y: logicalAnchor.y * zoom + contentMargin - viewportAnchor.y))
        }
        needsDisplay = true
    }

    private func fitVisibleAssets() {
        guard let viewport = enclosingScrollView?.contentView.bounds.size,
              viewport.width > 1, viewport.height > 1 else { return }
        pendingFit = false
        if !isGroupRow {
            // Grid alignment follows the viewport; returning to its start must
            // preserve the thumbnail size instead of fitting legacy positions.
            rebuildGeometry()
            updateDocumentSize()
            scroll(to: .zero)
            needsDisplay = true
            return
        }
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
        rebuildGeometry()
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
        guard isActive, !isGroupRow, dragContext == nil, marqueeStart == nil else { return }
        if let onThumbnailResize {
            let next = ProjectMaterialLayout(thumbnailSize: thumbnailSize * (1 + event.magnification)).thumbnailSize
            onThumbnailResize(next)
            return
        }
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
            let ids = self.assetIDs(intersecting: prefetchRect)
            let candidates = ids.compactMap { id -> Int? in
                self.geometry[id]?.intersects(visible) == true ? self.assetIndices[id] : nil
            }.sorted().map { self.assets[$0] }
            let tooltipIDs = candidates.map(\.id)
            if self.tooltipAssetIDs != tooltipIDs || self.tooltipRevision != self.geometryRevision {
                self.updateTooltips(for: candidates)
                self.tooltipAssetIDs = tooltipIDs
                self.tooltipRevision = self.geometryRevision
            }
            guard self.lastVisibleIDs != ids else { return }
            self.lastVisibleIDs = ids
            self.onVisibleAssets?(ids)
        }
    }

    private func updateTooltips(for visibleAssets: [ProjectAsset]) {
        removeAllToolTips()
        tooltipOwners = visibleAssets.map { asset in
            [asset.name, badges[asset.id] ?? "尚未导出"].joined(separator: "\n") as NSString
        }
        for (asset, tooltip) in zip(visibleAssets, tooltipOwners) {
            addToolTip(cardRect(asset), owner: tooltip, userData: nil)
        }
    }

    private func asset(at point: CGPoint) -> ProjectAsset? {
        let candidates = spatialBuckets[Bucket(x: Int(floor(point.x / 256)), y: Int(floor(point.y / 256)))] ?? []
        return candidates.compactMap { id -> (Int, ProjectAsset)? in
            guard let index = assetIndices[id], geometry[id]?.contains(point) == true else { return nil }
            return (index, assets[index])
        }.max(by: { $0.0 < $1.0 })?.1
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let draggedIDs = Set(dragContext?.ids ?? [])
        let drawingIDs = assetIDs(intersecting: dirtyRect)
        for index in drawingIDs.compactMap({ assetIndices[$0] }).sorted() {
            let asset = assets[index]
            guard let rect = geometry[asset.id], needsToDraw(rect) else { continue }
            drawCard(asset, at: asset.position, alpha: draggedIDs.contains(asset.id) ? 0.35 : 1)
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
        let imageRect = CGRect(x: rect.minX + 8 * displayScale, y: rect.minY + 8 * displayScale,
                               width: thumbnailSize * displayScale, height: thumbnailSize * displayScale)
        if let image = thumbnails[asset.id], image.size.width > 0, image.size.height > 0 {
            let scale = min(imageRect.width / image.size.width, imageRect.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let destination = CGRect(x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2,
                                     width: size.width, height: size.height)
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else if let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) {
            let side = min(36 * displayScale, imageRect.width)
            let symbolRect = CGRect(x: imageRect.midX - side / 2, y: imageRect.midY - side / 2, width: side, height: side)
            placeholder.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 0.4,
                             respectFlipped: true, hints: nil)
        }
        let titleFont: CGFloat = 11
        let titleY = imageRect.maxY + 5
        guard rect.width >= 36, rect.maxY - titleY >= titleFont + 2 else { return }
        let titleRect = CGRect(x: rect.minX + 3 * displayScale, y: titleY,
                               width: rect.width - 6 * displayScale, height: titleFont + 5)
        (asset.name as NSString).draw(in: titleRect, withAttributes: titleAttributes)
    }

    private func updateSelection(_ ids: Set<UUID>) {
        guard selectedIDs != ids else { return }
        replaceSelection(ids)
        pendingSelection = ids
        // AppKit draws selection immediately; publish once when marquee selection finishes.
        if marqueeStart == nil { publishSelection() }
        setAccessibilityValue("显示 \(assets.count) 张图片，已选 \(ids.count) 张")
    }

    private func publishSelection() {
        guard lastPublishedSelection != selectedIDs else { return }
        lastPublishedSelection = selectedIDs
        onSelectionChange?(selectedIDs)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isActive else { return nil }
        window?.makeFirstResponder(self)
        onFocus?()
        clearMouseInteraction()
        let menu = NSMenu(title: "项目素材")
        menu.autoenablesItems = false
        let point = convert(event.locationInWindow, from: nil)
        contextMenuPoint = logicalPoint(point)
        if let hit = asset(at: point) {
            if !selectedIDs.contains(hit.id) { updateSelection([hit.id]) }
        }
        contextMenuSelection = selectedIDs
        if !contextMenuSelection.isEmpty {
            for (index, operation) in [ProjectOperation.gridCollage, .freeCanvas, .longStitch].enumerated() where operations.contains(operation) {
                let item = actionItem("添加至\(operation.title)", action: #selector(sendFromMenu(_:)), key: String(index + 1))
                item.representedObject = operation.rawValue
                item.image = NSImage(systemSymbolName: operation.systemImage, accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            if !isGroupRow {
                let gather = actionItem("新建照片组", action: #selector(gatherFromMenu(_:)), key: "\r")
                gather.isEnabled = contextMenuSelection.count >= 2
                menu.addItem(gather)
                menu.addItem(.separator())
            }
            menu.addItem(actionItem(isGroupRow ? "移回项目素材" : "从项目移除", action: #selector(removeFromMenu(_:)), key: "\u{8}"))
            menu.addItem(.separator())
        }
        let undoItem = actionItem("撤销", action: #selector(undoFromMenu(_:)), key: "z")
        undoItem.keyEquivalentModifierMask = .command
        menu.addItem(undoItem)
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

    @objc private func sendFromMenu(_ item: NSMenuItem) {
        guard !contextMenuSelection.isEmpty, let raw = item.representedObject as? String,
              let operation = ProjectOperation(rawValue: raw) else { return }
        onSend?(operation, contextMenuSelection)
    }

    @objc private func gatherFromMenu(_ item: NSMenuItem) {
        guard contextMenuSelection.count >= 2 else { return }
        onGather?(contextMenuSelection, contextMenuPoint)
    }

    @objc private func ungroupFromMenu(_ item: NSMenuItem) {
        guard !contextMenuSelection.isEmpty else { return }
        onUngroup?(contextMenuSelection)
    }

    @objc private func undoFromMenu(_ item: NSMenuItem) { onUndo?() }

    @objc private func removeFromMenu(_ item: NSMenuItem) {
        guard !contextMenuSelection.isEmpty else { return }
        onRemove?(contextMenuSelection)
    }

    @objc private func importFromMenu(_ item: NSMenuItem) { onImportPanel?() }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        onFocus?()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownAssetID = nil
        selectOnMouseUp = nil
        marqueeStart = nil
        marqueeRect = nil
        marqueeLayer.path = nil
        let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        guard let hit = asset(at: mouseDownPoint) else {
            marqueeBaseSelection = additive ? selectedIDs : []
            updateSelection(marqueeBaseSelection)
            marqueeStart = mouseDownPoint
            return
        }
        if additive {
            var updated = selectedIDs
            if !updated.insert(hit.id).inserted { updated.remove(hit.id) }
            updateSelection(updated)
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
            marqueeLayer.path = CGPath(rect: rect, transform: nil)
            let covered = assetIDs(intersecting: rect)
            updateSelection(marqueeBaseSelection.union(covered))
            return
        }
        guard mouseDownAssetID != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= 4 else { return }
        beginMaterialDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        if let id = selectOnMouseUp, dragContext == nil { updateSelection([id]) }
        publishSelection()
        clearMouseInteraction()
    }

    private func clearMouseInteraction() {
        mouseDownAssetID = nil
        selectOnMouseUp = nil
        marqueeStart = nil
        marqueeRect = nil
        marqueeLayer.path = nil
        clearInsertionMarker()
    }

    private func beginMaterialDrag(_ event: NSEvent) {
        let selected = assets.filter { selectedIDs.contains($0.id) }
        guard let grabbed = selected.first(where: { $0.id == mouseDownAssetID }) ?? selected.first else { return }
        let dragged = [grabbed] + selected.filter { $0.id != grabbed.id }
        guard let data = try? JSONEncoder().encode(dragged.map { $0.id.uuidString }) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: ProjectMaterialBoard.assetPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = dragImage(for: dragged)
        let point = convert(event.locationInWindow, from: nil)
        let grabbedRect = cardRect(grabbed)
        let grabOffset = CGPoint(x: mouseDownPoint.x - grabbedRect.minX, y: mouseDownPoint.y - grabbedRect.minY)
        draggingItem.setDraggingFrame(CGRect(x: point.x - grabOffset.x, y: point.y - grabOffset.y,
                                             width: image.size.width, height: image.size.height), contents: image)
        dragContext = MaterialDrag(ids: dragged.map(\.id),
                                   positions: Dictionary(uniqueKeysWithValues: dragged.map { ($0.id, $0.position) }),
                                   startPoint: logicalPoint(mouseDownPoint),
                                   sourceOrder: assets.map(\.id))
        selectOnMouseUp = nil
        ProjectMaterialDragState.shared.assetIDs = dragged.map(\.id)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
        invalidateCards(Set(dragged.map(\.id)))
    }

    private func dragImage(for dragged: [ProjectAsset]) -> NSImage {
        let side = thumbnailSize * displayScale
        let inset = 8 * displayScale
        let stackStep = min(5, side / 12)
        let layerCount = min(3, dragged.count)
        let stackExtent = CGFloat(max(0, layerCount - 1)) * stackStep
        let size = NSSize(width: cardSize.width * displayScale + stackExtent,
                          height: cardSize.height * displayScale + stackExtent)
        return NSImage(size: size, flipped: true) { [thumbnails] _ in
            for index in (0..<layerCount).reversed() {
                let offset = CGFloat(index) * stackStep
                let imageRect = CGRect(x: inset + offset, y: inset + offset, width: side, height: side)
                guard let image = thumbnails[dragged[index].id], image.size.width > 0, image.size.height > 0 else { continue }
                let scale = min(imageRect.width / image.size.width, imageRect.height / image.size.height)
                let destination = CGRect(x: imageRect.midX - image.size.width * scale / 2,
                                         y: imageRect.midY - image.size.height * scale / 2,
                                         width: image.size.width * scale, height: image.size.height * scale)
                if index > 0 {
                    NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
                    NSBezierPath(roundedRect: destination.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
                }
                image.draw(in: destination, from: .zero, operation: .sourceOver,
                           fraction: index == 0 ? 1 : 0.8, respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            if dragged.count > 1 {
                let text = "\(dragged.count)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
                ]
                let textSize = text.size(withAttributes: attributes)
                let badge = CGRect(x: max(0, inset + side - textSize.width - 12), y: inset,
                                   width: textSize.width + 12, height: 19)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: badge, xRadius: 9.5, yRadius: 9.5).fill()
                text.draw(at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                          withAttributes: attributes)
            }
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let draggedIDs = Set(dragContext?.ids ?? [])
        dragContext = nil
        ProjectMaterialDragState.shared.assetIDs = []
        extraDragExtent = .zero
        acceptsFileDrop = false
        clearMouseInteraction()
        invalidateCards(draggedIDs)
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

    // Keep periodic callbacks for edge autoscroll, but draggingUpdated below only
    // invalidates when a preview or drop-target state actually changes.
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isActive else { return [] }
        if isInternalDrag(sender) {
            autoscrollDrag(sender)
            if !isGroupRow { updateInsertionMarker(at: convert(sender.draggingLocation, from: nil)) }
            return .move
        }
        let nextAcceptsFileDrop = (onDropAssets != nil && sender.draggingPasteboard.availableType(from: [ProjectMaterialBoard.assetPasteboardType]) != nil)
            || (!isGroupRow && sender.draggingPasteboard.availableType(from: [.fileURL]) != nil)
        if nextAcceptsFileDrop != acceptsFileDrop {
            acceptsFileDrop = nextAcceptsFileDrop
            setNeedsDisplay(visibleRect.insetBy(dx: -2, dy: -2))
        }
        return acceptsFileDrop ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearInsertionMarker()
        if acceptsFileDrop {
            acceptsFileDrop = false
            setNeedsDisplay(visibleRect.insetBy(dx: -2, dy: -2))
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isActive && (isInternalDrag(sender) || acceptsFileDrop)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isActive else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        if isInternalDrag(sender) {
            if !isGroupRow {
                guard let onReorder, let gridLayout, let dragContext,
                      dragContext.sourceOrder == assets.map(\.id) else { return false }
                let ids = ProjectMaterialGridLayout.reordered(dragContext.sourceOrder,
                    moving: Set(dragContext.ids), insertionIndex: gridLayout.insertionIndex(at: point))
                clearInsertionMarker()
                if ids != dragContext.sourceOrder { onReorder(ids) }
                return true
            }
            let positions = movedPositions(to: point)
            guard !positions.isEmpty else { return false }
            onMove?(positions)
            return true
        }
        if let onDropAssets,
           let data = sender.draggingPasteboard.data(forType: ProjectMaterialBoard.assetPasteboardType),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            let ids = Set(values.compactMap(UUID.init(uuidString:)))
            guard !ids.isEmpty else { return false }
            onDropAssets(ids)
            acceptsFileDrop = false
            needsDisplay = true
            return true
        }
        guard !isGroupRow else { return false }
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
        let dy = isGroupRow ? 0 : max(-minimumY, logical.y - drag.startPoint.y)
        return drag.positions.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    private func updateInsertionMarker(at point: CGPoint) {
        guard let gridLayout else { return }
        let index = gridLayout.insertionIndex(at: point)
        guard index != insertionIndex else { return }
        insertionIndex = index
        insertionLayer.path = CGPath(rect: gridLayout.insertionMarker(at: index), transform: nil)
    }

    private func clearInsertionMarker() {
        insertionIndex = nil
        insertionLayer.path = nil
    }

    private func autoscrollDrag(_ sender: NSDraggingInfo) {
        guard let scroll = enclosingScrollView else { return }
        let point = convert(sender.draggingLocation, from: nil)
        let visible = visibleRect
        var origin = scroll.contentView.bounds.origin
        let threshold: CGFloat = 28
        let step: CGFloat = 14
        if isGroupRow {
            if point.x < visible.minX + threshold { origin.x -= step }
            if point.x > visible.maxX - threshold { origin.x += step }
        } else {
            if point.y < visible.minY + threshold { origin.y -= step }
            if point.y > visible.maxY - threshold { origin.y += step }
        }
        origin.x = isGroupRow ? max(0, origin.x) : 0
        origin.y = isGroupRow ? 0 : min(max(0, origin.y), max(0, frame.height - visible.height))
        if isGroupRow { origin.x = min(origin.x, max(0, contentExtent.width - visible.width)) }
        guard origin != scroll.contentView.bounds.origin else { return }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func keyDown(with event: NSEvent) {
        guard isActive, window?.firstResponder === self, window?.attachedSheet == nil else {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if let panel = visiblePreviewPanel {
            if [49, 53].contains(event.keyCode), modifiers.isEmpty, !event.isARepeat { closePreview(panel) }
            return
        }
        let actionKeys: Set<UInt16> = [36, 49, 51, 76, 117]
        let operation = ["1": ProjectOperation.gridCollage, "2": .freeCanvas, "3": .longStitch][event.charactersIgnoringModifiers ?? ""]
        if event.isARepeat && (actionKeys.contains(event.keyCode) || operation != nil || modifiers.contains(.command)) { return }
        if handleCommandShortcut(event) {
            return
        } else if modifiers.isEmpty, let operation, !selectedIDs.isEmpty, operations.contains(operation) {
            onSend?(operation, selectedIDs)
        } else if modifiers.isEmpty, [51, 117].contains(event.keyCode), !selectedIDs.isEmpty {
            onRemove?(selectedIDs)
        } else if event.keyCode == 53 {
            clearMouseInteraction()
            updateSelection([])
        } else if event.keyCode == 49, modifiers.isEmpty {
            togglePreview()
        } else if [36, 76].contains(event.keyCode), modifiers.isEmpty, selectedIDs.count >= 2, !isGroupRow {
            onGather?(selectedIDs, .zero)
        } else if [123, 124, 125, 126].contains(event.keyCode), modifiers.isSubset(of: [.shift]) {
            moveSelectionWithArrow(event.keyCode, step: modifiers.contains(.shift) ? 10 : 1)
        } else {
            super.keyDown(with: event)
        }
    }

    private var visiblePreviewPanel: QLPreviewPanel? {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, panel.dataSource === self else { return nil }
        return panel
    }

    private func togglePreview() {
        guard isActive else { return }
        if let panel = visiblePreviewPanel {
            closePreview(panel)
            return
        }
        previewItems = assets.filter { selectedIDs.contains($0.id) }
            .compactMap { assetURLs[$0.id].map { $0 as NSURL } }
        guard !previewItems.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        // Let Quick Look acquire this responder before changing its data source or delegate.
        panel.updateController()
        panel.makeKeyAndOrderFront(self)
        guard panel.dataSource === self else { return }
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    private func closePreview(_ panel: QLPreviewPanel, restoreFocus: Bool = true) {
        panel.orderOut(self)
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        previewItems = []
        if restoreFocus, isActive { window?.makeFirstResponder(self) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        isActive && window?.firstResponder === self && !previewItems.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard isActive else { return }
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index]
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, [49, 53].contains(event.keyCode) else { return false }
        if !event.isARepeat { closePreview(panel) }
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.dataSource === self {
            closePreview(panel, restoreFocus: false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActive, window?.firstResponder === self, window?.attachedSheet == nil else {
            return super.performKeyEquivalent(with: event)
        }
        if visiblePreviewPanel != nil { return super.performKeyEquivalent(with: event) }
        if event.isARepeat, event.modifierFlags.contains(.command) { return true }
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
        if !isGroupRow {
            guard let onReorder, let gridLayout,
                  let first = assets.firstIndex(where: { selectedIDs.contains($0.id) }),
                  let last = assets.lastIndex(where: { selectedIDs.contains($0.id) }) else { return }
            let delta = key == 123 ? -1 : key == 124 ? 1 : key == 126 ? -gridLayout.columns : gridLayout.columns
            let boundary = delta < 0 ? first + delta : last + 1 + delta
            let ids = assets.map(\.id)
            let next = ProjectMaterialGridLayout.reordered(ids, moving: selectedIDs, insertionIndex: boundary)
            if next != ids { onReorder(next) }
            return
        }
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
