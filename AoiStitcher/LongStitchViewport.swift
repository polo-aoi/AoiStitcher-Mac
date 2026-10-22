import AppKit
import SwiftUI

/// The document keeps its logical size throughout a zoom gesture. AppKit owns
/// the viewport transform; the published scale is only used by overlays and labels.
struct LongStitchViewport<Content: View>: NSViewRepresentable {
    let canvasSize: CGSize
    @Binding var scrollView: NSScrollView?
    @Binding var scale: CGFloat
    var onViewportChange: () -> Void
    @ViewBuilder var content: () -> Content

    final class Coordinator {
        var parent: LongStitchViewport
        let document = LongStitchDocumentView()
        var hostingView: NSHostingView<AnyView>?
        var magnificationObserver: NSKeyValueObservation?
        var observers: [NSObjectProtocol] = []
        var refreshScheduled = false

        init(_ parent: LongStitchViewport) { self.parent = parent }

        func refresh(_ scrollView: NSScrollView) {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.refreshScheduled = false
                if self.parent.scale != scrollView.magnification {
                    self.parent.scale = scrollView.magnification
                }
                self.parent.onViewportChange()
            }
        }

        func updateContent() {
            let size = CGSize(width: max(1, parent.canvasSize.width) + 48,
                              height: max(1, parent.canvasSize.height) + 48)
            let root = AnyView(parent.content().padding(24)
                .frame(width: size.width, height: size.height))
            if let hostingView {
                hostingView.rootView = root
            } else {
                let host = NSHostingView(rootView: root)
                host.sizingOptions = []
                document.addSubview(host)
                hostingView = host
            }
            if document.frame.size != size { document.setFrameSize(size) }
            hostingView?.frame = CGRect(origin: .zero, size: size)
        }

        func disconnect() {
            magnificationObserver?.invalidate()
            magnificationObserver = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        deinit {
            magnificationObserver?.invalidate()
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = NSScrollView()
        view.contentView = LongStitchCenteredClipView()
        view.drawsBackground = false
        view.borderType = .noBorder
        view.allowsMagnification = true
        view.minMagnification = 0.001
        view.maxMagnification = 4
        view.horizontalScrollElasticity = .none
        view.verticalScrollElasticity = .none
        configureScrollers(view)
        let coordinator = context.coordinator
        coordinator.updateContent()
        view.documentView = coordinator.document
        coordinator.magnificationObserver = view.observe(\.magnification, options: [.new]) { [weak coordinator] view, _ in
            coordinator?.refresh(view)
        }
        view.contentView.postsBoundsChangedNotifications = true
        view.contentView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            coordinator.observers.append(NotificationCenter.default.addObserver(
                forName: name, object: view.contentView, queue: .main
            ) { [weak coordinator, weak view] _ in
                guard let view else { return }
                coordinator?.refresh(view)
            })
        }
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.parent.scrollView = view
            coordinator.refresh(view)
        }
        return view
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        configureScrollers(view)
        context.coordinator.updateContent()
        context.coordinator.refresh(view)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    private func configureScrollers(_ view: NSScrollView) {
        view.hasHorizontalScroller = false
        view.hasVerticalScroller = false
        view.autohidesScrollers = true
        view.scrollerStyle = .overlay
    }
}

final class LongStitchDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

/// Center a small document without changing its dimensions as magnification changes.
private final class LongStitchCenteredClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        let document = documentView.frame
        if document.width < result.width { result.origin.x = document.midX - result.width / 2 }
        if document.height < result.height { result.origin.y = document.midY - result.height / 2 }
        return result
    }
}

enum LongStitchViewportNavigation {
    /// Keep an exact document point at the same fractional position in the viewport.
    static func setScale(_ scale: CGFloat, in scrollView: NSScrollView,
                         anchor: CGPoint, viewportFraction: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        guard let document = scrollView.documentView else { return }
        let target = min(max(scale, scrollView.minMagnification), scrollView.maxMagnification)
        if scrollView.magnification != target { scrollView.magnification = target }
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let point = document.convert(anchor, to: clip)
        var bounds = clip.bounds
        bounds.origin = CGPoint(x: point.x - bounds.width * viewportFraction.x,
                                y: point.y - bounds.height * viewportFraction.y)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    static func zoom(_ factor: CGFloat, in scrollView: NSScrollView, atWindowPoint point: CGPoint) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let local = clip.convert(point, from: nil)
        let fraction = CGPoint(x: (local.x - clip.bounds.minX) / max(1, clip.bounds.width),
                               y: (local.y - clip.bounds.minY) / max(1, clip.bounds.height))
        let anchor = document.convert(point, from: nil)
        setScale(scrollView.magnification * factor, in: scrollView,
                 anchor: anchor, viewportFraction: fraction)
    }
}
