import SwiftUI
import AppKit

struct CanvasLayersList: NSViewRepresentable {
    @ObservedObject var store: CanvasStore
    var onInspect: (CanvasLayer) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let table = CanvasLayersTableView()
        table.store = store
        table.onInspect = onInspect
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        table.refresh()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? CanvasLayersTableView else { return }
        table.onInspect = onInspect
        table.refresh()
    }
}

final class CanvasLayersTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    static let layerPasteboardType = NSPasteboard.PasteboardType("com.aoistitcher.canvas-layer")
    var store: CanvasStore!
    var onInspect: ((CanvasLayer) -> Void)?
    private var layers: [CanvasLayer] = []
    private var synchronizingSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("material"))
        column.width = 248
        addTableColumn(column)
        headerView = nil
        style = .sourceList
        rowHeight = 42
        intercellSpacing = NSSize(width: 0, height: 2)
        columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        autoresizingMask = [.width]
        backgroundColor = .clear
        allowsMultipleSelection = false
        allowsEmptySelection = true
        dataSource = self
        delegate = self
        registerForDraggedTypes([Self.layerPasteboardType])
        setDraggingSourceOperationMask(.move, forLocal: true)
        setDraggingSourceOperationMask([], forLocal: false)
        setAccessibilityLabel("素材图层，从上到下排列")
        toolTip = "单击选中，右击设置，拖动调整图层顺序。⌘I 设置素材，⌥↑／⌥↓ 调整顺序。"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let updated = Array(store.document.layers.reversed())
        let changed = layers.count != updated.count || zip(layers, updated).contains { old, new in
            old.id != new.id || old.name != new.name || old.locked != new.locked ||
            old.color != new.color || (old.previewImage ?? old.image) !== (new.previewImage ?? new.image)
        }
        layers = updated
        synchronizingSelection = true
        if changed { reloadData() }
        if let selected = layers.firstIndex(where: { $0.id == store.selectedID }) {
            if selectedRow != selected { selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        } else if selectedRow != -1 { deselectAll(nil) }
        synchronizingSelection = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { layers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("material-cell")
        let cell = (makeView(withIdentifier: identifier, owner: nil) as? CanvasLayerCell) ?? CanvasLayerCell()
        cell.identifier = identifier
        let layer = layers[row]
        cell.configure(layer) { [weak self] in self?.store.toggleLock(layer.id) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizingSelection else { return }
        store.selectedID = layers.indices.contains(selectedRow) ? layers[selectedRow].id : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        inspectRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            inspectRow(at: convert(event.locationInWindow, from: nil))
        } else {
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
    }

    private func inspectRow(at point: NSPoint) {
        let index = row(at: point)
        guard layers.indices.contains(index) else { return }
        window?.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        store.selectedID = layers[index].id
        onInspect?(layers[index])
    }

    override func keyDown(with event: NSEvent) {
        // Fn, Caps Lock and numeric-pad flags should not disable Delete or shortcuts.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased()
        if character == "z" && (modifiers == .command || modifiers == [.command, .shift]) {
            if modifiers.contains(.shift) { store.redo() } else { store.undo() }
            refresh()
        } else if character == "d" && modifiers == .command {
            store.duplicateSelected()
            refresh()
        } else if (event.keyCode == 51 || event.keyCode == 117) && modifiers.isEmpty {
            store.deleteSelected()
            refresh()
        } else if modifiers == .command && character == "i",
           layers.indices.contains(selectedRow) {
            onInspect?(layers[selectedRow])
        } else if modifiers == .option && (event.keyCode == 125 || event.keyCode == 126),
                  layers.indices.contains(selectedRow) {
            let destination = event.keyCode == 126 ? selectedRow - 1 : selectedRow + 2
            store.moveLayer(layers[selectedRow].id, toListInsertionIndex: destination)
            refresh()
            if selectedRow >= 0 { scrollRowToVisible(selectedRow) }
        } else { super.keyDown(with: event) }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard layers.indices.contains(row), !layers[row].locked else { return nil }
        let item = NSPasteboardItem()
        item.setString(layers[row].id.uuidString, forType: Self.layerPasteboardType)
        return item
    }

    private func draggedLayer(from info: NSDraggingInfo) -> UUID? {
        guard let source = info.draggingSource as? CanvasLayersTableView, source === self,
              let value = info.draggingPasteboard.string(forType: Self.layerPasteboardType),
              let id = UUID(uuidString: value),
              let layer = store.document.layers.first(where: { $0.id == id }), !layer.locked else { return nil }
        return id
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard draggedLayer(from: info) != nil else { return [] }
        tableView.setDropRow(min(layers.count, max(0, row)), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = draggedLayer(from: info), (0...layers.count).contains(row) else { return false }
        store.moveLayer(id, toListInsertionIndex: row)
        refresh()
        return true
    }
}

private final class CanvasLayerCell: NSTableCellView {
    private let thumbnail = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let lock = NSButton()
    private var toggleLock: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lock.isBordered = false
        lock.target = self
        lock.action = #selector(lockClicked)
        lock.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [thumbnail, name, lock])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 30),
            thumbnail.heightAnchor.constraint(equalToConstant: 30),
            lock.widthAnchor.constraint(equalToConstant: 24),
            lock.heightAnchor.constraint(equalToConstant: 26)
        ])
        textField = name
        imageView = thumbnail
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ layer: CanvasLayer, toggleLock: @escaping () -> Void) {
        self.toggleLock = toggleLock
        name.stringValue = layer.name
        name.toolTip = layer.name
        if let image = layer.previewImage ?? layer.image {
            thumbnail.image = NSImage(cgImage: image, size: .zero)
        } else {
            thumbnail.image = NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
                layer.color.nsColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
                NSColor.separatorColor.setStroke()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).stroke()
                return true
            }
        }
        lock.image = NSImage(systemSymbolName: layer.locked ? "lock.fill" : "lock.open", accessibilityDescription: nil)
        lock.toolTip = layer.locked ? "解锁素材" : "锁定素材"
        lock.setAccessibilityLabel(lock.toolTip)
        setAccessibilityLabel(layer.name + (layer.locked ? "，已锁定" : ""))
    }

    @objc private func lockClicked() { toggleLock?() }
}
