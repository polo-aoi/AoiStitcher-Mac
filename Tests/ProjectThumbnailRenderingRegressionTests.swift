import AppKit

/// Renders synthetic thumbnails into memory, with no window or screen capture.
/// In particular, the old viewport-only dictionary loses the red pixels as soon
/// as a loaded card leaves the prefetch set, even though the asset still exists.
@MainActor enum ProjectThumbnailRenderingRegressionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectThumbnailRenderingRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        let red = thumbnail(.red)
        let blue = thumbnail(.blue)
        for groupRow in [false, true] {
            let first = ProjectAsset(id: UUID(), fileName: "first.png", name: "first.png", position: .zero)
            let second = ProjectAsset(id: UUID(), fileName: "second.png", name: "second.png",
                                      position: CGPoint(x: 148, y: 0))
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 176))
            let board = ProjectMaterialDocumentView(frame: .zero)
            board.isGroupRow = groupRow
            scroll.documentView = board
            func configure(_ images: [UUID: NSImage], assets: [ProjectAsset]? = nil,
                           urls: [UUID: URL] = [:], size: CGFloat = 128) {
                board.configure(assets: assets ?? [first, second], selection: [], thumbnailSize: size,
                                viewZoom: 1, fitRequest: 0, thumbnails: images, assetURLs: urls,
                                badges: [:], operations: [], isActive: true)
            }
            configure([first.id: red])
            let initial = coloredPixels(in: board, color: .red)
            try check(initial > 1_000, "\(groupRow): a decoded thumbnail actually draws red pixels")

            // SwiftUI only sends images for the current viewport. Temporarily
            // missing keys must not replace an already decoded image with a placeholder.
            configure([second.id: blue])
            try check(coloredPixels(in: board, color: .red) == initial,
                      "\(groupRow): scrolling away retains a loaded thumbnail for the return frame")
            try check(coloredPixels(in: board, color: .blue) > 1_000,
                      "\(groupRow): new arrivals draw while previous thumbnails remain cached")
            for _ in 0..<5 { configure([:]) }
            try check(coloredPixels(in: board, color: .red) == initial,
                      "\(groupRow): empty asynchronous snapshots never flash a loaded photo to its placeholder")
            configure([:], size: 96)
            try check(coloredPixels(in: board, color: .red) > 1_000,
                      "\(groupRow): resizing cards reuses loaded pixels immediately")

            // A new source identity must not retain the old photograph.
            configure([:], urls: [first.id: URL(fileURLWithPath: "/new-project/first.png")])
            try check(coloredPixels(in: board, color: .red) == 0,
                      "\(groupRow): changing the original URL invalidates the retained image")
            configure([first.id: red], urls: [first.id: URL(fileURLWithPath: "/new-project/first.png")])
            try check(coloredPixels(in: board, color: .red) > 1_000,
                      "\(groupRow): replacement pixels appear on arrival")
            var overwritten = first
            overwritten.contentRevision = UUID()
            configure([:], assets: [overwritten, second],
                      urls: [first.id: URL(fileURLWithPath: "/new-project/first.png")])
            try check(coloredPixels(in: board, color: .red) == 0,
                      "\(groupRow): overwriting the same path and asset ID invalidates old pixels")
            configure([:], assets: [second])
            try check(coloredPixels(in: board, color: .red) == 0,
                      "\(groupRow): removed assets cannot leave stale photos behind")

            // Use different colors to make an accidental resolution downgrade
            // observable in the pixels, rather than inspecting private caches.
            configure([first.id: thumbnail(.red, side: 192)])
            configure([first.id: thumbnail(.blue, side: 512)])
            try check(coloredPixels(in: board, color: .blue) > 1_000
                      && coloredPixels(in: board, color: .red) == 0,
                      "\(groupRow): a completed larger preview replaces the coarse one")
            configure([first.id: thumbnail(.red, side: 192)])
            try check(coloredPixels(in: board, color: .blue) > 1_000
                      && coloredPixels(in: board, color: .red) == 0,
                      "\(groupRow): a late low-resolution result never downgrades a clear loaded photo")
        }

        let many = (0..<320).map { index in
            ProjectAsset(id: UUID(), fileName: "\(index).png", name: "\(index).png", position: .zero)
        }
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 176))
        let board = ProjectMaterialDocumentView(frame: .zero)
        scroll.documentView = board
        func update(_ images: [UUID: NSImage]) {
            board.configure(assets: many, selection: [], thumbnailSize: 128, viewZoom: 1,
                            fitRequest: 0, thumbnails: images, assetURLs: [:], badges: [:],
                            operations: [], isActive: true)
        }
        weak var oldImage: NSImage?
        do {
            let image = thumbnail(.red)
            oldImage = image
            update([many[0].id: image])
        }
        try check(oldImage != nil, "The board retains an already loaded image independently of a transient snapshot")
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 12_000))
        for asset in many.dropFirst() { update([asset.id: blue]) }
        try check(oldImage == nil, "Browsing hundreds of photos releases old offscreen previews instead of retaining the entire project")
        return checks
    }

    private static func thumbnail(_ color: NSColor, side: Int = 32) -> NSImage {
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
        color.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(cgImage: pixels.cgImage!, size: CGSize(width: side, height: side))
    }

    private static func coloredPixels(in board: ProjectMaterialDocumentView, color: NSColor) -> Int {
        let width = 500, height = 220
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        board.draw(CGRect(x: 0, y: 0, width: width, height: height))
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let target = color.usingColorSpace(.deviceRGB)!
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(pixel.redComponent - target.redComponent) < 0.05,
                   abs(pixel.greenComponent - target.greenComponent) < 0.05,
                   abs(pixel.blueComponent - target.blueComponent) < 0.05,
                   pixel.alphaComponent > 0.95 { count += 1 }
            }
        }
        return count
    }
}
