import AppKit
import SwiftUI

/// Keeps the main content mounted while a sidebar opens, closes or changes width.
struct ProjectSidebarSplit<Sidebar: View, Content: View>: View {
    let isPresented: Bool
    @Binding var width: Double
    let edge: HorizontalEdge
    let sidebarMinimum: CGFloat
    let sidebarMaximum: CGFloat
    let contentMinimum: CGFloat
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var content: () -> Content
    @State private var dragWidth: CGFloat?

    private let dividerWidth: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(0, min(sidebarMaximum, geometry.size.width - contentMinimum - dividerWidth))
            let minimum = min(sidebarMinimum, maximum)
            let preferred = dragWidth ?? (width.isFinite ? CGFloat(width) : sidebarMinimum)
            let effectiveWidth = min(maximum, max(minimum, preferred))
            HStack(spacing: 0) {
                if edge == .leading {
                    sidebarContent(width: effectiveWidth)
                    divider(width: effectiveWidth, minimum: minimum, maximum: maximum)
                }
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                if edge == .trailing {
                    divider(width: effectiveWidth, minimum: minimum, maximum: maximum)
                    sidebarContent(width: effectiveWidth)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: isPresented) { _, _ in dragWidth = nil }
        .transaction { $0.animation = nil }
    }

    private func sidebarContent(width: CGFloat) -> some View {
        sidebar()
            .frame(width: width)
            .frame(width: isPresented ? width : 0, alignment: edge == .leading ? .leading : .trailing)
            .clipped()
            .opacity(isPresented ? 1 : 0)
            .disabled(!isPresented)
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)
    }

    private func divider(width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> some View {
        ProjectSidebarDivider(isEnabled: isPresented, width: width, minimum: minimum,
                              maximum: maximum, isLeading: edge == .leading,
                              onChange: { dragWidth = $0 },
                              onCommit: { value in
                                  self.width = Double(value)
                                  dragWidth = nil
                              })
            .frame(width: isPresented ? dividerWidth : 0)
            .frame(maxHeight: .infinity)
            .clipped()
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)
    }
}

private struct ProjectSidebarDivider: NSViewRepresentable {
    let isEnabled: Bool
    let width: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let isLeading: Bool
    let onChange: (CGFloat) -> Void
    let onCommit: (CGFloat) -> Void

    func makeNSView(context: Context) -> ProjectSidebarDividerView {
        ProjectSidebarDividerView()
    }

    func updateNSView(_ view: ProjectSidebarDividerView, context: Context) {
        view.width = width
        view.minimum = minimum
        view.maximum = maximum
        view.direction = isLeading ? 1 : -1
        view.onChange = onChange
        view.onCommit = onCommit
        view.isEnabled = isEnabled
        view.setAccessibilityValue("\(Int(width))")
    }

    static func dismantleNSView(_ view: ProjectSidebarDividerView, coordinator: ()) {
        view.disconnect()
    }
}

private final class ProjectSidebarDividerView: NSView {
    var width: CGFloat = 0
    var minimum: CGFloat = 0
    var maximum: CGFloat = 0
    var direction: CGFloat = 1
    var onChange: ((CGFloat) -> Void)?
    var onCommit: ((CGFloat) -> Void)?
    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled { resetDrag() }
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    private var startX: CGFloat?
    private var startWidth: CGFloat = 0
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("调整侧栏宽度")
        setAccessibilityHelp("向左或向右拖动，调整侧栏宽度")
        toolTip = "拖动调整侧栏宽度"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        guard isEnabled else { hoverTracking = nil; return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
        updateHoverFromPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        needsDisplay = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        if startX == nil { NSCursor.arrow.set() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled, !isHiddenOrHasHiddenAncestor, bounds.width > 0 {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard isEnabled else { return }
        let scale = window?.backingScaleFactor ?? 1
        let highlighted = isHovered || startX != nil
        let lineWidth: CGFloat = (highlighted ? 3 : 1) / scale
        let x = round((bounds.midX - lineWidth / 2) * scale) / scale
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
        NSRect(x: x, y: bounds.minY, width: lineWidth, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        startX = event.locationInWindow.x
        startWidth = width
        needsDisplay = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let startX else { return }
        let candidate = startWidth + (event.locationInWindow.x - startX) * direction
        onChange?(min(maximum, max(minimum, candidate)))
        NSCursor.resizeLeftRight.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, let startX else { return }
        let candidate = startWidth + (event.locationInWindow.x - startX) * direction
        self.startX = nil
        needsDisplay = true
        onCommit?(min(maximum, max(minimum, candidate)))
        updateHoverFromPointer()
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { resetDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    func disconnect() {
        resetDrag()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        hoverTracking = nil
        onChange = nil
        onCommit = nil
        discardCursorRects()
    }

    private func resetDrag() {
        if startX != nil || window.map({ bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) }) == true {
            NSCursor.arrow.set()
        }
        startX = nil
        isHovered = false
        needsDisplay = true
        discardCursorRects()
    }

    private func updateHoverFromPointer() {
        let hovered = isEnabled && window?.isKeyWindow == true && window.map {
            bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
        } == true
        if hovered != isHovered {
            isHovered = hovered
            needsDisplay = true
        }
    }
}
