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

/// One viewport-sized request. Pixel density is measured by AppKit, while the
/// cache chooses a small number of reusable resolution tiers.
struct ProjectThumbnailDemand: Equatable {
    var visibleIDs: Set<UUID>
    var prefetchIDs: Set<UUID>
    var maximumPixelSize: Int

    var assetIDs: Set<UUID> { visibleIDs.union(prefetchIDs) }
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
    var onThumbnailDemand: (ProjectThumbnailDemand) -> Void = { _ in }
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
    var onGroupChoose: () -> Void = {}
    var onGroupClearSelection: () -> Void = {}
    var isGroupSelected = false
    var groupDragID: UUID? = nil
    var onGroupDragBegan: () -> Void = {}
    var onGroupDragEnded: () -> Void = {}
    var onGroupDragHover: (UUID, Bool) -> Bool = { _, _ in false }
    var onGroupDragExit: () -> Void = {}
    var onDropGroup: (UUID, Bool) -> Bool = { _, _ in false }
    var onAssetDropTargetChange: (Bool) -> Void = { _ in }
    var focusRequest = 0
    var onReorder: (([UUID]) -> Void)? = nil
    var onThumbnailResize: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
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
        let view: NSView = isGroupRow ? ProjectPhotoGroupContainerView(scrollView: scroll) : scroll
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let groupContainer = view as? ProjectPhotoGroupContainerView
        guard let scroll = groupContainer?.scrollView ?? (view as? NSScrollView) else { return }
        guard let board = scroll.documentView as? ProjectMaterialDocumentView else { return }
        if let groupContainer {
            groupContainer.groupID = groupDragID
            groupContainer.memberCount = assets.count
            groupContainer.isSelected = isGroupSelected
            groupContainer.onChoose = onGroupChoose
            groupContainer.onGroupDragBegan = onGroupDragBegan
            groupContainer.onGroupDragEnded = onGroupDragEnded
            groupContainer.onGroupDragHover = onGroupDragHover
            groupContainer.onGroupDragExit = onGroupDragExit
            groupContainer.onDropGroup = onDropGroup
            groupContainer.onDropAssets = onDropAssets
            groupContainer.onAssetDropTargetChange = onAssetDropTargetChange
            groupContainer.isActive = isActive
        }
        let selectionBinding = $selection
        let zoomBinding = $viewZoom
        board.onSelectionChange = { selectionBinding.wrappedValue = $0 }
        board.onMove = onMove
        board.onImport = onImport
        board.onActivate = onActivate
        board.onVisibleAssets = onVisibleAssets
        board.onThumbnailDemand = onThumbnailDemand
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
        board.onGroupClearSelection = onGroupClearSelection
        board.onReorder = onReorder
        board.onThumbnailResize = onThumbnailResize
        board.onZoomChange = { zoomBinding.wrappedValue = Double($0) }
        board.configure(assets: assets, selection: selection, thumbnailSize: thumbnailSize,
                        viewZoom: viewZoom, fitRequest: fitRequest, thumbnails: thumbnails, assetURLs: assetURLs,
                        badges: badges, operations: operations, isActive: isActive)
        board.requestFocus(focusRequest)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? ProjectPhotoGroupContainerView)?.disconnect()
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

final class ProjectMaterialDocumentView: NSView, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onSelectionChange: ((Set<UUID>) -> Void)?
    var onMove: (([UUID: CGPoint]) -> Void)?
    var onImport: (([URL], CGPoint) -> Void)?
    var onActivate: ((UUID) -> Void)?
    var onVisibleAssets: ((Set<UUID>) -> Void)?
    var onThumbnailDemand: ((ProjectThumbnailDemand) -> Void)?
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
    var onGroupClearSelection: (() -> Void)?
    var onReorder: (([UUID]) -> Void)?
    var onThumbnailResize: ((CGFloat) -> Void)?

    private var assets: [ProjectAsset] = []
    private var selectedIDs: Set<UUID> = []
    // SwiftUI supplies a moving viewport snapshot, not an authoritative list of
    // loaded images. Keep recent decoded previews across snapshot changes.
    private static let retainedThumbnailLimit = 256
    private var thumbnails: [UUID: NSImage] = [:]
    private var thumbnailSources: [UUID: ThumbnailSource] = [:]
    private var thumbnailLastUse: [UUID: UInt64] = [:]
    private var thumbnailClock: UInt64 = 0
    private var assetURLs: [UUID: URL] = [:]
    private var badges: [UUID: String] = [:]
    private var operations: [ProjectOperation] = []
    private var isActive = true
    private var contextMenuSelection: Set<UUID> = []
    private var contextMenuPoint = CGPoint.zero
    private var previewItems: [NSURL] = []
    // Keep the preview order independent from the live selection. Finder keeps
    // the selected set available while Quick Look moves the active item.
    private var previewAssetIDs: [UUID] = []
    private var previewIndex = 0
    // Quick Look handles arrow keys and its ‹ › buttons internally; the panel's
    // currentPreviewItemIndex is the only reliable signal for panel-driven
    // navigation, observed here so the grid selection can follow it.
    private var isSynchronizingPreview = false
    private var observedPreviewPanel: QLPreviewPanel?
    private static var previewIndexObservationContext = 0
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
    private var tooltipRevision = -1
    private var tooltipAssetIDs: [UUID] = []

    private struct Bucket: Hashable {
        var x: Int
        var y: Int
    }
    private struct ThumbnailSource: Equatable {
        var fileName: String
        var url: URL?
        var revision: UUID?

        init(asset: ProjectAsset, url: URL?) {
            fileName = asset.fileName
            self.url = url
            revision = asset.contentRevision
        }
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
    private var lastThumbnailDemand: ProjectThumbnailDemand?
    private var visibleAssetsReportScheduled = false

    private struct MaterialDrag {
        var ids: [UUID]
        var positions: [UUID: CGPoint]
        var startPoint: CGPoint
        var sourceOrder: [UUID]
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { isActive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        wantsLayer = true
        layer?.actions = ["contents": NSNull()]
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
        scheduleVisibleAssetsReport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleVisibleAssetsReport()
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
        let namesChanged = self.assets.count != assets.count || zip(self.assets, assets).contains { previous, updated in
            previous.name != updated.name
        }
        let indices = assetGeometryChanged
            ? Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
            : assetIndices
        let changedThumbnails = mergeThumbnails(thumbnails, assets: assets, indices: indices, urls: assetURLs)
        self.assets = assets
        self.thumbnailSize = size
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
        if badgeChanged || namesChanged { tooltipRevision = -1 }
        scheduleVisibleAssetsReport()
    }

    private var cardSize: CGSize { ProjectMaterialLayout(thumbnailSize: thumbnailSize).cardSize }
    private var displayScale: CGFloat { isGroupRow ? zoom : (gridLayout?.scale ?? zoom) }

    private func mergeThumbnails(_ incoming: [UUID: NSImage], assets: [ProjectAsset],
                                 indices: [UUID: Int], urls: [UUID: URL]) -> Set<UUID> {
        var changed = Set<UUID>()
        func discard(_ id: UUID) {
            thumbnails.removeValue(forKey: id)
            thumbnailSources.removeValue(forKey: id)
            thumbnailLastUse.removeValue(forKey: id)
            changed.insert(id)
        }
        for id in Array(thumbnails.keys) {
            guard let index = indices[id], !assets[index].isRemoved,
                  thumbnailSources[id] == ThumbnailSource(asset: assets[index], url: urls[id]) else {
                discard(id)
                continue
            }
        }
        thumbnailClock &+= 1
        for (id, image) in incoming {
            guard let index = indices[id], !assets[index].isRemoved else { continue }
            if let retained = thumbnails[id], Self.pixelCost(retained) > Self.pixelCost(image) {
                thumbnailLastUse[id] = thumbnailClock
                continue
            }
            if thumbnails[id] !== image { changed.insert(id) }
            thumbnails[id] = image
            thumbnailSources[id] = ThumbnailSource(asset: assets[index], url: urls[id])
            thumbnailLastUse[id] = thumbnailClock
        }

        // Only visible images are pinned. Prefetch arrivals may be evicted to
        // keep large Retina thumbnails within the same bounded memory budget.
        let visible = visibleRect
        let pinned = Set(thumbnails.keys.filter { geometry[$0]?.intersects(visible) == true })
        let limit = max(Self.retainedThumbnailLimit, pinned.count)
        let costLimit = (isGroupRow ? 8 : 32) * 1024 * 1024
        var cost = thumbnails.values.reduce(0) { $0 + Self.pixelCost($1) }
        if thumbnails.count > limit || cost > costLimit {
            let evictionOrder = thumbnails.keys.filter { !pinned.contains($0) }.sorted {
                (thumbnailLastUse[$0] ?? 0) < (thumbnailLastUse[$1] ?? 0)
            }
            for id in evictionOrder {
                guard thumbnails.count > limit || cost > costLimit else { break }
                if let image = thumbnails[id] { cost -= Self.pixelCost(image) }
                discard(id)
            }
        }
        return changed
    }

    private static func pixelCost(_ image: NSImage) -> Int {
        image.representations.map { max(0, $0.pixelsWide) * max(0, $0.pixelsHigh) * 4 }.max() ?? 0
    }

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
        guard isFiniteVisibleRect(rect) else { return [] }
        let side: CGFloat = 256
        let x0 = Int(floor(rect.minX / side)), x1 = Int(floor(rect.maxX / side))
        let y0 = Int(floor(rect.minY / side)), y1 = Int(floor(rect.maxY / side))
        guard x1 >= x0, y1 >= y0 else { return [] }
        return (y0...y1).flatMap { y in (x0...x1).map { Bucket(x: $0, y: y) } }
    }

    private func assetIDs(intersecting rect: CGRect) -> Set<UUID> {
        guard isFiniteVisibleRect(rect) else { return [] }
        let bucketCount = (floor(rect.width / 256) + 2) * (floor(rect.height / 256) + 2)
        if bucketCount > CGFloat(max(32, spatialBuckets.count * 2)) {
            return Set(geometry.compactMap { $0.value.intersects(rect) ? $0.key : nil })
        }
        let candidates = buckets(intersecting: rect).reduce(into: Set<UUID>()) {
            $0.formUnion(spatialBuckets[$1] ?? [])
        }
        return Set(candidates.filter { geometry[$0]?.intersects(rect) == true })
    }

    private func isFiniteVisibleRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty
            && rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
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
            let pixels = max(1, Int(ceil(self.thumbnailSize * self.displayScale
                                        * (self.window?.backingScaleFactor ?? 1))))
            // Never convert unbounded geometry into a spatial bucket. An empty
            // demand releases queued work without clearing already-drawn pixels.
            guard self.isActive, self.isFiniteVisibleRect(visible) else {
                self.publishThumbnailDemand(ProjectThumbnailDemand(visibleIDs: [], prefetchIDs: [],
                                                                   maximumPixelSize: pixels))
                return
            }
            let prefetchRect = visible.insetBy(
                dx: -(self.isGroupRow ? max(80, self.cardSize.width * self.displayScale + 12) : 80),
                dy: -(self.isGroupRow ? 80 : max(80, self.cardSize.height * self.displayScale + 12)))
            let ids = self.assetIDs(intersecting: prefetchRect)
            let visibleIDs = self.assetIDs(intersecting: visible)
            let candidates = ids.compactMap { id -> Int? in
                self.geometry[id]?.intersects(visible) == true ? self.assetIndices[id] : nil
            }.sorted().map { self.assets[$0] }
            let tooltipIDs = candidates.map(\.id)
            if self.tooltipAssetIDs != tooltipIDs || self.tooltipRevision != self.geometryRevision {
                self.updateTooltips(for: candidates)
                self.tooltipAssetIDs = tooltipIDs
                self.tooltipRevision = self.geometryRevision
            }
            if self.lastVisibleIDs != ids {
                self.lastVisibleIDs = ids
                self.onVisibleAssets?(ids)
            }
            self.publishThumbnailDemand(ProjectThumbnailDemand(visibleIDs: visibleIDs,
                                                                prefetchIDs: ids.subtracting(visibleIDs),
                                                                maximumPixelSize: pixels))
        }
    }

    private func publishThumbnailDemand(_ demand: ProjectThumbnailDemand) {
        guard lastThumbnailDemand != demand else { return }
        lastThumbnailDemand = demand
        onThumbnailDemand?(demand)
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

    private func thumbnailAsset(at point: CGPoint) -> ProjectAsset? {
        let candidates = spatialBuckets[Bucket(x: Int(floor(point.x / 256)), y: Int(floor(point.y / 256)))] ?? []
        return candidates.compactMap { id -> (Int, ProjectAsset)? in
            guard let index = assetIndices[id], let card = geometry[id] else { return nil }
            let imageRect = CGRect(x: card.minX + 8 * displayScale,
                                   y: card.minY + 8 * displayScale,
                                   width: thumbnailSize * displayScale,
                                   height: thumbnailSize * displayScale)
            let photoRect = thumbnails[id].map { fittedImageRect($0, in: imageRect) } ?? imageRect
            guard photoRect.contains(point) else { return nil }
            return (index, assets[index])
        }.max(by: { $0.0 < $1.0 })?.1
    }

    private func fittedImageRect(_ image: NSImage, in rect: CGRect) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return rect }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
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
            NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
            card.fill()
            NSColor.controlAccentColor.setStroke()
            card.lineWidth = 1
            card.stroke()
        }
        let imageRect = CGRect(x: rect.minX + 8 * displayScale, y: rect.minY + 8 * displayScale,
                               width: thumbnailSize * displayScale, height: thumbnailSize * displayScale)
        if let image = thumbnails[asset.id], image.size.width > 0, image.size.height > 0 {
            let destination = fittedImageRect(image, in: imageRect)
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium.rawValue])
        } else if let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) {
            let side = min(36 * displayScale, imageRect.width)
            let symbolRect = CGRect(x: imageRect.midX - side / 2, y: imageRect.midY - side / 2, width: side, height: side)
            placeholder.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 0.4,
                             respectFlipped: true, hints: nil)
        }
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
        let hit = thumbnailAsset(at: point)
        if let hit {
            if !selectedIDs.contains(hit.id) { updateSelection([hit.id]) }
        } else if isGroupRow {
            updateSelection([])
            onGroupClearSelection?()
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
        // The dedicated leading handle selects or moves a group. Thumbnail
        // clicks select a photo; gaps and trailing space clear the selection.
        let hit = thumbnailAsset(at: mouseDownPoint)
        guard let hit else {
            if isGroupRow {
                updateSelection([])
                onGroupClearSelection?()
                return
            }
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
            if handlePreviewKey(event, panel: panel, modifiers: modifiers) { return }
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
            navigateSelectionWithArrow(event.keyCode)
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
        guard let panel = QLPreviewPanel.shared() else { return }
        presentPreview(acquireControl: {
            // Quick Look resolves the controller from the key window's
            // responder chain only when the panel is about to become key.
            // A never-opened hidden panel therefore has no currentController
            // yet, so the panel must be shown inside the handoff to trigger
            // the begin callback before the first frame is exposed.
            panel.updateController()
            // Closing clears our datasource, but Quick Look can retain this
            // controller while hidden and omit a second begin callback. Take
            // the datasource back before exposing the panel again.
            if panel.dataSource !== self,
               let controller = panel.currentController as? ProjectMaterialDocumentView,
               controller === self {
                panel.dataSource = self
                panel.delegate = self
            }
            panel.makeKeyAndOrderFront(self)
            guard panel.dataSource === self else {
                panel.orderOut(self)
                return false
            }
            return true
        }, synchronize: {
            self.synchronizePreviewPanel(panel)
            self.startObservingPreviewIndex(panel)
        }, show: {})
    }

    /// Keep the first visible frame behind the same preparation barrier for
    /// both initial presentation and reopening on a different selected photo.
    /// Closures allow regression checks without showing the system panel.
    @discardableResult
    func presentPreview(acquireControl: () -> Bool, synchronize: () -> Void, show: () -> Void) -> Bool {
        guard isActive else { return false }
        let candidates = assets.filter { assetURLs[$0.id] != nil }
        previewAssetIDs = candidates.map(\.id)
        previewItems = candidates.compactMap { assetURLs[$0.id].map { $0 as NSURL } }
        guard !previewItems.isEmpty else { return false }
        previewIndex = previewAssetIDs.firstIndex(where: { selectedIDs.contains($0) }) ?? 0
        // updateController may invoke beginPreviewPanelControl, which must also
        // synchronize before returning. Never expose a panel that still points
        // at index zero or at the previous controller's data source.
        guard acquireControl() else { return false }
        synchronize()
        show()
        return true
    }

    private func synchronizePreviewPanel(_ panel: QLPreviewPanel) {
        guard panel.dataSource === self, !previewItems.isEmpty else { return }
        // Transient index changes during our own reload must not be mistaken
        // for panel-driven navigation.
        isSynchronizingPreview = true
        defer { isSynchronizingPreview = false }
        panel.reloadData()
        panel.currentPreviewItemIndex = previewIndex
    }

    var preparedPreviewIndex: Int { previewIndex }

    private func closePreview(_ panel: QLPreviewPanel, restoreFocus: Bool = true) {
        stopObservingPreviewIndex()
        panel.orderOut(self)
        // Panel-native navigation (arrows, ‹ › buttons) never passes through
        // previewPanel(_:handle:); fold the panel's final index back into the
        // selection so closing lands on the photo that was actually viewed.
        if restoreFocus { syncSelectionToPanelIndex(panel) }
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        previewItems = []
        previewAssetIDs = []
        previewIndex = 0
        if restoreFocus, isActive { window?.makeFirstResponder(self) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        isActive && window?.firstResponder === self && !previewItems.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard isActive else { return }
        panel.dataSource = self
        panel.delegate = self
        synchronizePreviewPanel(panel)
        startObservingPreviewIndex(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        stopObservingPreviewIndex()
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index]
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return handlePreviewKey(event, panel: panel, modifiers: modifiers)
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

    private func handlePreviewKey(_ event: NSEvent, panel: QLPreviewPanel,
                                  modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.isEmpty else { return false }
        if [49, 53].contains(event.keyCode) {
            if !event.isARepeat { closePreview(panel) }
            return true
        }
        guard [123, 124, 125, 126].contains(event.keyCode) else { return false }
        navigatePreview(with: event.keyCode, panel: panel)
        return true
    }

    private func navigatePreview(with key: UInt16, panel: QLPreviewPanel) {
        navigatePreview(with: key) { panel.currentPreviewItemIndex = $0 }
    }

    func navigatePreview(with key: UInt16, setDisplayedIndex: (Int) -> Void) {
        guard !previewAssetIDs.isEmpty else { return }
        guard [123, 124, 125, 126].contains(key) else { return }
        let delta = (key == 123 || key == 126) ? -1 : 1
        let next = min(max(0, previewIndex + delta), previewAssetIDs.count - 1)
        guard next != previewIndex else { return }
        previewIndex = next
        setDisplayedIndex(next)
        updateSelection([previewAssetIDs[next]])
        revealAsset(previewAssetIDs[next])
    }

    /// Finder keeps the underlying selection on the item Quick Look is showing.
    /// Since the panel consumes arrow keys and ‹ › clicks internally, observe
    /// currentPreviewItemIndex instead of waiting for delegate events.
    private func startObservingPreviewIndex(_ panel: QLPreviewPanel) {
        guard observedPreviewPanel !== panel, panel.dataSource === self else { return }
        stopObservingPreviewIndex()
        panel.addObserver(self, forKeyPath: "currentPreviewItemIndex",
                          options: [], context: &Self.previewIndexObservationContext)
        observedPreviewPanel = panel
    }

    private func stopObservingPreviewIndex() {
        guard let panel = observedPreviewPanel else { return }
        observedPreviewPanel = nil
        panel.removeObserver(self, forKeyPath: "currentPreviewItemIndex",
                             context: &Self.previewIndexObservationContext)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &Self.previewIndexObservationContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        guard !isSynchronizingPreview, let panel = observedPreviewPanel,
              object as? QLPreviewPanel === panel else { return }
        syncSelectionToPanelIndex(panel)
    }

    private func syncSelectionToPanelIndex(_ panel: QLPreviewPanel) {
        guard panel.dataSource === self else { return }
        syncSelectionToPreviewIndex(panel.currentPreviewItemIndex)
    }

    /// The bounds check also rejects stale values such as NSNotFound.
    func syncSelectionToPreviewIndex(_ index: Int) {
        guard previewAssetIDs.indices.contains(index), index != previewIndex else { return }
        previewIndex = index
        updateSelection([previewAssetIDs[index]])
        revealAsset(previewAssetIDs[index])
    }

    private func navigateSelectionWithArrow(_ key: UInt16) {
        guard !assets.isEmpty else { return }
        let columns = isGroupRow ? max(1, assets.count) : max(1, gridLayout?.columns ?? 1)
        let delta: Int
        switch key {
        case 123: delta = -1
        case 124: delta = 1
        case 126: delta = -columns
        case 125: delta = columns
        default: return
        }
        let selectedIndices = assets.indices.filter { selectedIDs.contains(assets[$0].id) }
        let anchor = delta < 0 ? selectedIndices.first : selectedIndices.last
        let current = anchor ?? (delta < 0 ? assets.count : -1)
        let target = min(max(0, current + delta), assets.count - 1)
        guard target != current || anchor == nil else { return }
        updateSelection([assets[target].id])
        revealAsset(assets[target].id)
    }

    private func revealAsset(_ id: UUID) {
        guard let rect = geometry[id], let scrollView = enclosingScrollView else { return }
        let visible = scrollView.contentView.bounds
        var origin = visible.origin
        if rect.minX < visible.minX { origin.x = rect.minX - 8 }
        else if rect.maxX > visible.maxX { origin.x = rect.maxX - visible.width + 8 }
        if rect.minY < visible.minY { origin.y = rect.minY - 8 }
        else if rect.maxY > visible.maxY { origin.y = rect.maxY - visible.height + 8 }
        scroll(to: origin)
    }
}
