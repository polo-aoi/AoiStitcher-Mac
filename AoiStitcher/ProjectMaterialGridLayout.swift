import Foundation
import CoreGraphics

/// Pure grid geometry. Reflow changes only presentation, never the project's saved order.
nonisolated struct ProjectMaterialGridLayout {
    let count: Int
    let viewportWidth: CGFloat
    let scale: CGFloat
    let margin: CGFloat
    let gap: CGFloat
    let cardSize: CGSize
    let columns: Int

    init(count: Int, viewportWidth: CGFloat, thumbnailSize: CGFloat, zoom: CGFloat = 1) {
        self.count = max(0, count)
        self.viewportWidth = viewportWidth.isFinite ? max(1, viewportWidth) : 1
        margin = min(12, max(0, (self.viewportWidth - 1) / 2))
        let base = ProjectMaterialLayout(thumbnailSize: thumbnailSize).cardSize
        let available = max(1, self.viewportWidth - 2 * margin)
        let requestedScale = zoom.isFinite ? min(2, max(0.02, zoom)) : 1
        scale = min(requestedScale, available / base.width)
        cardSize = CGSize(width: base.width * scale, height: base.height * scale)
        gap = 8 * scale
        columns = max(1, Int(min(CGFloat(max(1, self.count)), floor((available + gap) / (cardSize.width + gap)))))
    }

    var rowStride: CGFloat { cardSize.height + gap }
    var columnStride: CGFloat { cardSize.width + gap }
    var height: CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        return 2 * margin + CGFloat(rows) * cardSize.height + CGFloat(rows - 1) * gap
    }

    func frame(at index: Int) -> CGRect {
        CGRect(x: margin + CGFloat(index % columns) * columnStride,
               y: margin + CGFloat(index / columns) * rowStride,
               width: cardSize.width, height: cardSize.height)
    }

    func insertionIndex(at point: CGPoint) -> Int {
        guard count > 0, point.x.isFinite, point.y.isFinite else { return 0 }
        if point.y < margin { return 0 }
        if point.y >= height - margin { return count }
        let row = max(0, Int(floor((point.y - margin) / rowStride)))
        let x = min(viewportWidth, max(0, point.x - margin))
        let column = min(columns - 1, Int(floor(x / columnStride)))
        let index = min(count, row * columns + column)
        guard index < count else { return count }
        return min(count, index + (point.x >= frame(at: index).midX ? 1 : 0))
    }

    func insertionMarker(at index: Int) -> CGRect {
        guard count > 0 else { return .zero }
        let target = min(count, max(0, index))
        let cell = frame(at: min(target, count - 1))
        let x = target == count ? cell.maxX + gap / 2 : cell.minX - gap / 2
        return CGRect(x: min(max(1, x), max(1, viewportWidth - 2)),
                      y: cell.minY, width: 2, height: cell.height)
    }

    static func reordered(_ ids: [UUID], moving: Set<UUID>, insertionIndex: Int) -> [UUID] {
        let boundary = min(ids.count, max(0, insertionIndex))
        let moved = ids.filter { moving.contains($0) }
        guard !moved.isEmpty else { return ids }
        let destination = ids.prefix(boundary).filter { !moving.contains($0) }.count
        var result = ids.filter { !moving.contains($0) }
        result.insert(contentsOf: moved, at: destination)
        return result
    }
}
