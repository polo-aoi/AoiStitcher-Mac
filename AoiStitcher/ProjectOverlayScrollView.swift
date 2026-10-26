import AppKit
import SwiftUI

/// The library's scrollbars use overlay geometry even when macOS prefers legacy tracks.
class ProjectOverlayScrollView: NSScrollView {
    private var overlayStyle: ProjectOverlayScrollbarStyle?
    private var hoverTracking: NSTrackingArea?

    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .overlay
        overlayStyle = ProjectOverlayScrollbarStyle(scrollView: self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        scrollerStyle = .overlay
        overlayStyle = ProjectOverlayScrollbarStyle(scrollView: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        flashScrollers()
        super.mouseEntered(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        overlayStyle?.apply()
    }
}

/// Keep AppKit's native knob dragging and accessibility, drawing only a narrow thumb.
private final class ProjectOverlayScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        guard isEnabled, knobProportion < 1 else { return }
        var thumb = rect(for: .knob)
        guard thumb.width > 0, thumb.height > 0 else { return }
        if bounds.height > bounds.width {
            thumb = CGRect(x: bounds.midX - 2.5, y: thumb.minY + 1,
                           width: 5, height: max(0, thumb.height - 2))
        } else {
            thumb = CGRect(x: thumb.minX + 1, y: bounds.midY - 2.5,
                           width: max(0, thumb.width - 2), height: 5)
        }
        NSColor.labelColor.withAlphaComponent(0.36).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

/// Scoped to one scroll view; no application-wide appearance changes.
private final class ProjectOverlayScrollbarStyle {
    private weak var scrollView: NSScrollView?
    private let previousStyle: NSScroller.Style
    private let previousAutohides: Bool
    private let previousVerticalScroller: NSScroller?
    private let previousHorizontalScroller: NSScroller?
    private weak var installedVerticalScroller: NSScroller?
    private weak var installedHorizontalScroller: NSScroller?
    private var boundsObservation: NSObjectProtocol?
    private var styleObservation: NSKeyValueObservation?
    private var lastOrigin: CGPoint?
    private var applying = false

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        previousStyle = scrollView.scrollerStyle
        previousAutohides = scrollView.autohidesScrollers
        previousVerticalScroller = scrollView.verticalScroller
        previousHorizontalScroller = scrollView.horizontalScroller
        apply()
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            guard let self, let scrollView = self.scrollView else { return }
            let origin = scrollView.contentView.bounds.origin
            if let previous = self.lastOrigin, previous != origin { scrollView.flashScrollers() }
            self.lastOrigin = origin
        }
        // AppKit may react to the system's "Show scroll bars" preference after installation.
        styleObservation = scrollView.observe(\.scrollerStyle, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.apply() }
        }
    }

    deinit {
        if let boundsObservation { NotificationCenter.default.removeObserver(boundsObservation) }
        styleObservation?.invalidate()
    }

    func apply() {
        guard let scrollView, !applying else { return }
        applying = true
        defer { applying = false }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        let hasVertical = scrollView.hasVerticalScroller
        let hasHorizontal = scrollView.hasHorizontalScroller
        if !(scrollView.verticalScroller is ProjectOverlayScroller) {
            scrollView.verticalScroller = ProjectOverlayScroller(frame: CGRect(x: 0, y: 0, width: 12, height: 100))
            installedVerticalScroller = scrollView.verticalScroller
        }
        if !(scrollView.horizontalScroller is ProjectOverlayScroller) {
            scrollView.horizontalScroller = ProjectOverlayScroller(frame: CGRect(x: 0, y: 0, width: 100, height: 12))
            installedHorizontalScroller = scrollView.horizontalScroller
        }
        if scrollView.hasVerticalScroller != hasVertical { scrollView.hasVerticalScroller = hasVertical }
        if scrollView.hasHorizontalScroller != hasHorizontal { scrollView.hasHorizontalScroller = hasHorizontal }
        if scrollView.verticalScroller?.controlSize != .small { scrollView.verticalScroller?.controlSize = .small }
        if scrollView.horizontalScroller?.controlSize != .small { scrollView.horizontalScroller?.controlSize = .small }
    }

    func restore() {
        styleObservation?.invalidate()
        styleObservation = nil
        if let boundsObservation {
            NotificationCenter.default.removeObserver(boundsObservation)
            self.boundsObservation = nil
        }
        guard let scrollView else { return }
        let hasVertical = scrollView.hasVerticalScroller
        let hasHorizontal = scrollView.hasHorizontalScroller
        if scrollView.verticalScroller === installedVerticalScroller {
            scrollView.verticalScroller = previousVerticalScroller
        }
        if scrollView.horizontalScroller === installedHorizontalScroller {
            scrollView.horizontalScroller = previousHorizontalScroller
        }
        scrollView.hasVerticalScroller = hasVertical
        scrollView.hasHorizontalScroller = hasHorizontal
        scrollView.scrollerStyle = previousStyle
        scrollView.autohidesScrollers = previousAutohides
        self.scrollView = nil
    }
}

extension View {
    /// Apply to the content *inside* a SwiftUI ScrollView, not to the scroll container.
    func projectOverlayScrollbars() -> some View {
        background(ProjectOverlayScrollbarReader().allowsHitTesting(false))
    }
}

private struct ProjectOverlayScrollbarReader: NSViewRepresentable {
    func makeNSView(context: Context) -> ProjectOverlayScrollbarReaderView {
        ProjectOverlayScrollbarReaderView()
    }

    func updateNSView(_ view: ProjectOverlayScrollbarReaderView, context: Context) {
        view.scheduleAttach()
    }

    static func dismantleNSView(_ view: ProjectOverlayScrollbarReaderView, coordinator: ()) {
        view.disconnect()
    }
}

private final class ProjectOverlayScrollbarReaderView: NSView {
    private weak var styledScrollView: NSScrollView?
    private var style: ProjectOverlayScrollbarStyle?
    private var hoverTracking: NSTrackingArea?
    private var attachmentScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { disconnect() } else { scheduleAttach() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleAttach()
    }

    func scheduleAttach() {
        guard !attachmentScheduled else { return }
        attachmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachmentScheduled = false
            guard self.window != nil, let scroll = self.enclosingScrollView else { return }
            if self.styledScrollView !== scroll {
                self.style?.restore()
                self.style = ProjectOverlayScrollbarStyle(scrollView: scroll)
                self.styledScrollView = scroll
            } else {
                self.style?.apply()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { styledScrollView?.flashScrollers() }

    func disconnect() {
        style?.restore()
        style = nil
        styledScrollView = nil
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        hoverTracking = nil
    }
}
