import AppKit

/// Group moves have their own pasteboard type, separate from photos and plain text.
enum ProjectPhotoGroupDragPayload {
    static let type = NSPasteboard.PasteboardType("com.aoipic.project-photo-group")

    static func item(for id: UUID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: type)
        return item
    }

    static func id(from pasteboard: NSPasteboard) -> UUID? {
        pasteboard.string(forType: type).flatMap(UUID.init(uuidString:))
    }
}

/// A native parent receives group drops over the entire row. Its photo scroll
/// view keeps receiving photo drops, including its existing internal reordering.
@MainActor final class ProjectPhotoGroupContainerView: NSView {
    static let handleWidth: CGFloat = 32
    let scrollView: NSScrollView
    let handleView = ProjectPhotoGroupHandleView()

    var groupID: UUID? { didSet { handleView.groupID = groupID } }
    var memberCount = 0 { didSet { handleView.memberCount = memberCount } }
    var isSelected = false { didSet { handleView.isSelected = isSelected } }
    var isActive = true {
        didSet {
            guard oldValue != isActive else { return }
            handleView.isActive = isActive
            if isActive {
                registerForDraggedTypes([ProjectPhotoGroupDragPayload.type, ProjectMaterialBoard.assetPasteboardType])
            } else {
                unregisterDraggedTypes()
                clearDropFeedback()
            }
        }
    }

    var onChoose: (() -> Void)?
    var assetIDs: Set<UUID> = []
    var operations: [ProjectOperation] = ProjectOperation.allCases
    var onSend: ((ProjectOperation, Set<UUID>) -> Void)?
    var onReturnAssets: ((Set<UUID>) -> Void)?
    var onGroupDragBegan: (() -> Void)?
    var onGroupDragEnded: (() -> Void)?
    var onGroupDragHover: ((UUID, Bool) -> Bool)?
    var onGroupDragExit: (() -> Void)?
    var onDropGroup: ((UUID, Bool) -> Bool)?
    var onDropAssets: ((Set<UUID>) -> Void)?
    var onAssetDropTargetChange: ((Bool) -> Void)?

    private var isGroupDropTarget = false
    private var isAssetDropTarget = false

    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        // AppKit can leave plain NSViews unclipped. In a SwiftUI list each row
        // must contain its native subviews, even when they share a backing layer.
        clipsToBounds = true
        autoresizesSubviews = false
        addSubview(handleView)
        addSubview(scrollView)
        registerForDraggedTypes([ProjectPhotoGroupDragPayload.type, ProjectMaterialBoard.assetPasteboardType])
        handleView.onChoose = { [weak self] in self?.onChoose?() }
        handleView.onContextMenu = { [weak self] event in self?.menu(for: event) }
        handleView.onDragBegan = { [weak self] in self?.onGroupDragBegan?() }
        handleView.onDragEnded = { [weak self] in self?.onGroupDragEnded?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = min(Self.handleWidth, bounds.width)
        handleView.frame = CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        scrollView.frame = CGRect(x: bounds.minX + width, y: bounds.minY,
                                  width: max(0, bounds.width - width), height: bounds.height)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isActive, !assetIDs.isEmpty else { return nil }
        let members = assetIDs
        onChoose?()
        let menu = NSMenu(title: "照片组")
        menu.autoenablesItems = false
        for operation in operations where ProjectOperation.allCases.contains(operation) {
            let shortcut = ProjectOperation.allCases.firstIndex(of: operation).map { String($0 + 1) } ?? ""
            let item = NSMenuItem(title: "添加至\(operation.title)",
                                  action: #selector(sendGroupFromMenu(_:)), keyEquivalent: shortcut)
            item.target = self
            item.keyEquivalentModifierMask = []
            item.image = NSImage(systemSymbolName: operation.systemImage, accessibilityDescription: nil)
            item.representedObject = GroupMenuAction(operation: operation, assetIDs: members)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let returnItem = NSMenuItem(title: "移回素材", action: #selector(returnGroupFromMenu(_:)), keyEquivalent: "\u{8}")
        returnItem.target = self
        returnItem.keyEquivalentModifierMask = []
        returnItem.representedObject = members
        menu.addItem(returnItem)
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private struct GroupMenuAction {
        let operation: ProjectOperation
        let assetIDs: Set<UUID>
    }

    @objc private func sendGroupFromMenu(_ item: NSMenuItem) {
        guard isActive, let action = item.representedObject as? GroupMenuAction else { return }
        onSend?(action.operation, action.assetIDs)
    }

    @objc private func returnGroupFromMenu(_ item: NSMenuItem) {
        guard isActive, let members = item.representedObject as? Set<UUID> else { return }
        onReturnAssets?(members)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isActive else { clearDropFeedback(); return [] }
        if sender.draggingPasteboard.availableType(from: [ProjectPhotoGroupDragPayload.type]) != nil {
            setAssetDropTarget(false)
            guard let sourceID = validGroupID(from: sender),
                  onGroupDragHover?(sourceID, isBefore(sender)) == true else {
                clearDropFeedback()
                return []
            }
            isGroupDropTarget = true
            autoscrollGroupList(sender)
            return .move
        }
        clearGroupDropTarget()
        let acceptsPhotos = onDropAssets != nil && !assetIDs(from: sender).isEmpty
        setAssetDropTarget(acceptsPhotos)
        return acceptsPhotos ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDropFeedback() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearDropFeedback() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isActive else { return false }
        if sender.draggingPasteboard.availableType(from: [ProjectPhotoGroupDragPayload.type]) != nil {
            guard let sourceID = validGroupID(from: sender) else { return false }
            return onGroupDragHover?(sourceID, isBefore(sender)) == true
        }
        return onDropAssets != nil && !assetIDs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropFeedback() }
        guard isActive else { return false }
        if sender.draggingPasteboard.availableType(from: [ProjectPhotoGroupDragPayload.type]) != nil {
            guard let sourceID = validGroupID(from: sender) else { return false }
            // Read the actual drop point. Enter/exit ordering cannot erase a drop.
            return onDropGroup?(sourceID, isBefore(sender)) ?? false
        }
        let ids = assetIDs(from: sender)
        guard !ids.isEmpty, let onDropAssets else { return false }
        onDropAssets(ids)
        return true
    }

    private func validGroupID(from sender: NSDraggingInfo) -> UUID? {
        guard let source = sender.draggingSource as? ProjectPhotoGroupHandleView,
              source.isActive,
              let id = ProjectPhotoGroupDragPayload.id(from: sender.draggingPasteboard),
              id == source.groupID, let groupID, id != groupID else { return nil }
        return id
    }

    private func assetIDs(from sender: NSDraggingInfo) -> Set<UUID> {
        guard sender.draggingSource != nil,
              let data = sender.draggingPasteboard.data(forType: ProjectMaterialBoard.assetPasteboardType),
              let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private func isBefore(_ sender: NSDraggingInfo) -> Bool {
        convert(sender.draggingLocation, from: nil).y < bounds.midY
    }

    private func setAssetDropTarget(_ targeted: Bool) {
        guard isAssetDropTarget != targeted else { return }
        isAssetDropTarget = targeted
        onAssetDropTargetChange?(targeted)
    }

    private func clearGroupDropTarget() {
        guard isGroupDropTarget else { return }
        isGroupDropTarget = false
        onGroupDragExit?()
    }

    private func clearDropFeedback() {
        clearGroupDropTarget()
        setAssetDropTarget(false)
    }

    private func autoscrollGroupList(_ sender: NSDraggingInfo) {
        guard let outerScroll = enclosingScrollView, let document = outerScroll.documentView else { return }
        let clip = outerScroll.contentView
        let point = clip.convert(sender.draggingLocation, from: nil)
        let visible = clip.bounds
        var origin = visible.origin
        if point.y < visible.minY + 24 { origin.y -= 14 }
        else if point.y > visible.maxY - 24 { origin.y += 14 }
        origin.y = min(max(0, origin.y), max(0, document.bounds.height - visible.height))
        guard origin != visible.origin else { return }
        clip.scroll(to: origin)
        outerScroll.reflectScrolledClipView(clip)
    }

    func disconnect() {
        isActive = false
        handleView.disconnect()
        onChoose = nil
        onSend = nil
        onReturnAssets = nil
        onGroupDragBegan = nil
        onGroupDragEnded = nil
        onGroupDragHover = nil
        onGroupDragExit = nil
        onDropGroup = nil
        onDropAssets = nil
        onAssetDropTargetChange = nil
    }
}

/// Mouse handling is native so a SwiftUI button or overlay cannot consume the
/// drag threshold. A click selects; moving at least four points begins sorting.
@MainActor class ProjectPhotoGroupHandleView: NSView, NSDraggingSource {
    var groupID: UUID?
    var memberCount = 0 {
        didSet {
            setAccessibilityLabel("照片组，\(memberCount) 张照片")
            toolTip = "\(memberCount) 张照片；点击选中整组；拖动调整顺序"
        }
    }
    var isSelected = false { didSet { needsDisplay = true } }
    var isActive = true {
        didSet {
            guard oldValue != isActive else { return }
            if !isActive { finishDrag() }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onChoose: (() -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    private var mouseDownPoint: CGPoint?
    private var isDragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("点击选中整组，按住拖动调整顺序")
        toolTip = "点击选中整组；拖动调整顺序"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isActive { addCursorRect(bounds, cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.06) : NSColor.controlBackgroundColor).setFill()
        dirtyRect.intersection(bounds).fill()
        (isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
        let gripY = bounds.midY - 6.25
        for row in 0..<3 {
            for column in 0..<2 {
                let dot = CGRect(x: bounds.midX - 4.25 + CGFloat(column) * 6,
                                 y: gripY + CGFloat(row) * 5, width: 2.5, height: 2.5)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive, groupID != nil else { return }
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isActive, !isDragging, let start = mouseDownPoint, let groupID else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        isDragging = true
        onDragBegan?()
        beginGroupDragging(with: event, item: ProjectPhotoGroupDragPayload.item(for: groupID))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isActive else { return nil }
        mouseDownPoint = nil
        return onContextMenu?(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldChoose = isActive && mouseDownPoint != nil && !isDragging
            && bounds.contains(convert(event.locationInWindow, from: nil))
        mouseDownPoint = nil
        if shouldChoose { onChoose?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isActive else { return false }
        onChoose?()
        return true
    }

    /// Kept separate from event dispatch so event routing can be tested without
    /// starting the window server's interactive drag loop.
    func beginGroupDragging(with event: NSEvent, item: NSPasteboardItem) {
        guard window != nil else { finishDrag(); return }
        let item = NSDraggingItem(pasteboardWriter: item)
        let size = NSSize(width: 116, height: 36)
        let count = memberCount
        let image = NSImage(size: size, flipped: true) { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            NSColor.controlBackgroundColor.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            let text = "\(count) 张照片" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                 y: (size.height - textSize.height) / 2), withAttributes: attributes)
            return true
        }
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - 14, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag()
    }

    func finishDrag() {
        mouseDownPoint = nil
        guard isDragging else { return }
        isDragging = false
        onDragEnded?()
    }

    func disconnect() {
        isActive = false
        finishDrag()
        onChoose = nil
        onContextMenu = nil
        onDragBegan = nil
        onDragEnded = nil
        discardCursorRects()
    }
}
