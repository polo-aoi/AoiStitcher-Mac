import Foundation
import CoreGraphics

nonisolated struct CollageColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1
    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    static let white = CollageColor(red: 1, green: 1, blue: 1)
    static let black = CollageColor(red: 0, green: 0, blue: 0)
}

/// Layout and crop state use logical coordinates, independently of any Mac view.
nonisolated enum CollageAspectRatio: String, CaseIterable, Identifiable {
    case portrait3x4 = "3:4", square = "1:1", portrait9x16 = "9:16"
    case portrait2x3 = "2:3", portrait1x2 = "1:2"
    case landscape4x3 = "4:3", landscape3x2 = "3:2", landscape16x9 = "16:9"
    var id: String { rawValue }
    var value: CGFloat {
        let parts = rawValue.split(separator: ":")
        return CGFloat(Double(parts[0])! / Double(parts[1])!)
    }
    func size(forWidth width: CGFloat) -> CGSize {
        CGSize(width: max(1, width), height: max(1, width) / value)
    }
}

nonisolated enum CollageImageFill: String, CaseIterable, Identifiable {
    case cover = "填满", contain = "完整显示"
    var id: String { rawValue }
}

nonisolated struct CollageImageTransform: Equatable {
    var scale: CGFloat = 1
    /// Fractions of the current slot width and height, never screen pixels.
    var translateX: CGFloat = 0
    var translateY: CGFloat = 0
}

/// Portable editing recipe; watermark pixels and the rendered result live in
/// private cache files rather than retaining full-sized images in every slot.
nonisolated struct CollageCropRecipe: Codable, Equatable {
    var rect: CGRect
    var rotation: Double
    var imageCenter: CGPoint
    var scale: CGFloat
}

nonisolated struct CollageWatermarkRecipe: Codable, Equatable {
    var imageURL: URL
    var offset: CGSize
    var scale: CGFloat
    var rotation: Double
}

nonisolated struct CollageEditRecipe: Codable, Equatable {
    var crop: CollageCropRecipe?
    var watermarks: [CollageWatermarkRecipe]
}

nonisolated struct CollageSlot: Identifiable {
    var id: String
    var photoID = UUID()
    /// Always the original source; editing never overwrites this file.
    var imageURL: URL?
    /// Full-resolution rendered edit, preferred by the exporter when present.
    var editedImageURL: URL?
    var editRecipe: CollageEditRecipe?
    var image: CGImage?
    var previewImage: CGImage?
    var transform = CollageImageTransform()
    var fill: CollageImageFill = .cover
    var hasImage: Bool { image != nil || previewImage != nil || imageURL != nil }
    var imageSize: CGSize? {
        guard let pixels = previewImage ?? image else { return nil }
        return CGSize(width: pixels.width, height: pixels.height)
    }
    var name: String { imageURL?.lastPathComponent ?? "空白图片格" }
}

/// Horizontal means children run left to right; vertical means top to bottom.
nonisolated enum CollageSplitDirection: String {
    case horizontal, vertical
}

nonisolated indirect enum SplitNode: Equatable {
    case split(id: String, direction: CollageSplitDirection, ratios: [CGFloat], children: [SplitNode])
    case slot(slotId: String)

    var slotIDs: [String] {
        switch self {
        case .slot(let id): return [id]
        case .split(_, _, _, let children): return children.flatMap(\.slotIDs)
        }
    }
}

nonisolated struct CollageTemplate: Identifiable {
    var id: String
    var name: String
    var slotCount: Int
    var rootNode: SplitNode
    var familyID: String { String(id.split(separator: "-", maxSplits: 2).last ?? "") }
}

nonisolated struct CollageStyle {
    /// Style distances use a 1,000-point-wide logical canvas. Scale them together
    /// when displaying or exporting at another width.
    var gap: CGFloat = 8
    var padding: CGFloat = 16
    var borderRadius: CGFloat = 0
    var backgroundColor = CollageColor.white
    var backgroundImage: CGImage?
    var backgroundImageURL: URL?
}

nonisolated struct CollageState {
    var aspectRatio: CollageAspectRatio
    var activeTemplateId: String
    var rootNode: SplitNode
    var slots: [String: CollageSlot]
    var selectedSlotId: String?
    var style = CollageStyle()
    var orderedSlots: [CollageSlot] { rootNode.slotIDs.compactMap { slots[$0] } }
    var logicalSize: CGSize { aspectRatio.size(forWidth: 1000) }
}

nonisolated struct GridCollageDivider: Identifiable {
    var splitID: String
    var dividerIndex: Int
    var direction: CollageSplitDirection
    /// Center line of the gap; extend this rect only for view hit testing.
    var rect: CGRect
    var containerRect: CGRect
    /// Parent length after removing gaps, in the same coordinates as rect.
    var availableLength: CGFloat
    var minimumLeadingShare: CGFloat
    var minimumTrailingShare: CGFloat
    var id: String { "\(splitID):\(dividerIndex)" }
}

nonisolated struct GridCollageLayout {
    var slotRects: [String: CGRect]
    var dividers: [GridCollageDivider]
    var contentRect: CGRect
    var effectiveGap: CGFloat
}

nonisolated enum GridCollageLayoutEngine {
    static func normalizedRatios(_ ratios: [CGFloat], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard ratios.count == count else { return Array(repeating: 1 / CGFloat(count), count: count) }
        let values = ratios.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = values.reduce(0, +)
        guard total.isFinite, total > 0 else { return Array(repeating: 1 / CGFloat(count), count: count) }
        return values.map { $0 / total }
    }

    static func layout(state: CollageState, in bounds: CGRect) -> GridCollageLayout {
        let factor = bounds.width / 1000
        let padding = max(0, min(finite(state.style.padding) * factor,
                                  max(0, min(bounds.width, bounds.height) / 2 - 0.5)))
        return layout(rootNode: state.rootNode, in: bounds.insetBy(dx: padding, dy: padding),
                      gap: finite(state.style.gap) * factor)
    }

    static func layout(rootNode: SplitNode, in rect: CGRect, gap: CGFloat = 0,
                       minimumShare: CGFloat = 0.10) -> GridCollageLayout {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            return GridCollageLayout(slotRects: [:], dividers: [], contentRect: .zero, effectiveGap: 0)
        }
        let unitsX = intrinsicUnits(rootNode, along: .horizontal)
        let unitsY = intrinsicUnits(rootNode, along: .vertical)
        // Even extreme spacing values cannot consume every pixel of a slot.
        let safeGap = min(max(0, finite(gap)), rect.width / (CGFloat(unitsX) * 2),
                          rect.height / (CGFloat(unitsY) * 2))
        let minShare = min(0.49, max(0, finite(minimumShare)))
        let minimumWidth = min(rect.width * minShare,
                               max(0, (rect.width - safeGap * CGFloat(unitsX - 1)) / CGFloat(unitsX)))
        let minimumHeight = min(rect.height * minShare,
                                max(0, (rect.height - safeGap * CGFloat(unitsY - 1)) / CGFloat(unitsY)))
        var result = GridCollageLayout(slotRects: [:], dividers: [], contentRect: rect, effectiveGap: safeGap)
        func visit(_ node: SplitNode, _ bounds: CGRect) {
            switch node {
            case .slot(let id): result.slotRects[id] = bounds
            case .split(let id, let direction, let values, let children):
                guard !children.isEmpty else { return }
                let ratios = normalizedRatios(values, count: children.count)
                let horizontal = direction == .horizontal
                let length = horizontal ? bounds.width : bounds.height
                let localGap = min(safeGap, length / max(1, CGFloat(children.count * 2)))
                let available = max(0, length - localGap * CGFloat(children.count - 1))
                var offset: CGFloat = 0
                for index in children.indices {
                    // The final child absorbs subpixel rounding, so the tree tiles exactly.
                    let extent = index == children.count - 1 ? max(0, length - offset) : available * ratios[index]
                    let childRect = horizontal
                        ? CGRect(x: bounds.minX + offset, y: bounds.minY, width: extent, height: bounds.height)
                        : CGRect(x: bounds.minX, y: bounds.minY + offset, width: bounds.width, height: extent)
                    visit(children[index], childRect)
                    offset += extent
                    if index < children.count - 1 {
                        let line = horizontal
                            ? CGRect(x: bounds.minX + offset + localGap / 2, y: bounds.minY, width: 0, height: bounds.height)
                            : CGRect(x: bounds.minX, y: bounds.minY + offset + localGap / 2, width: bounds.width, height: 0)
                        let leafMinimum = horizontal ? minimumWidth : minimumHeight
                        result.dividers.append(GridCollageDivider(
                            splitID: id, dividerIndex: index, direction: direction, rect: line,
                            containerRect: bounds, availableLength: available,
                            minimumLeadingShare: minimumExtent(children[index], along: direction,
                                                               leafMinimum: leafMinimum, gap: localGap) / max(1, available),
                            minimumTrailingShare: minimumExtent(children[index + 1], along: direction,
                                                                leafMinimum: leafMinimum, gap: localGap) / max(1, available)))
                        offset += localGap
                    }
                }
            }
        }
        visit(rootNode, rect)
        return result
    }

    /// Delta is incremental in the layout's coordinate system. Only the two
    /// neighboring children change; all their descendants follow recursively.
    static func resizing(rootNode: SplitNode, divider: GridCollageDivider, delta: CGFloat) -> SplitNode {
        guard delta.isFinite, divider.availableLength > 0 else { return rootNode }
        return resize(rootNode, splitID: divider.splitID, index: divider.dividerIndex,
                      delta: delta / divider.availableLength,
                      minimumLeading: divider.minimumLeadingShare,
                      minimumTrailing: divider.minimumTrailingShare)
    }

    /// Callers without geometry may use this local-share variant. Interactive
    /// workspaces should use the divider overload, which also protects subtrees.
    static func resizing(rootNode: SplitNode, splitID: String, dividerIndex: Int,
                         delta: CGFloat, availableLength: CGFloat,
                         minimumShare: CGFloat = 0.10) -> SplitNode {
        guard delta.isFinite, availableLength.isFinite, availableLength > 0 else { return rootNode }
        return resize(rootNode, splitID: splitID, index: dividerIndex,
                      delta: delta / availableLength,
                      minimumLeading: max(0, finite(minimumShare)),
                      minimumTrailing: max(0, finite(minimumShare)))
    }

    static func fittedRect(aspectRatio: CGFloat, in viewport: CGRect) -> CGRect {
        guard aspectRatio.isFinite, aspectRatio > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let width = min(viewport.width, viewport.height * aspectRatio)
        let height = width / aspectRatio
        return CGRect(x: viewport.midX - width / 2, y: viewport.midY - height / 2, width: width, height: height)
    }

    /// Screen geometry and export both use this exact image rect and crop clamp.
    static func imageRect(imageSize: CGSize, viewport: CGRect,
                          transform: CollageImageTransform, fill: CollageImageFill = .cover) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let transform = clampedTransform(transform, imageSize: imageSize, viewport: viewport.size, fill: fill)
        let scaleX = viewport.width / imageSize.width, scaleY = viewport.height / imageSize.height
        let base = fill == .cover ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let size = CGSize(width: imageSize.width * base * transform.scale,
                          height: imageSize.height * base * transform.scale)
        return CGRect(x: viewport.midX - size.width / 2 + transform.translateX * viewport.width,
                      y: viewport.midY - size.height / 2 + transform.translateY * viewport.height,
                      width: size.width, height: size.height)
    }

    static func clampedTransform(_ value: CollageImageTransform, imageSize: CGSize,
                                 viewport: CGSize, fill: CollageImageFill = .cover) -> CollageImageTransform {
        var result = value
        result.scale = min(5, max(1, value.scale.isFinite ? value.scale : 1))
        guard imageSize.width > 0, imageSize.height > 0, viewport.width > 0, viewport.height > 0 else {
            result.translateX = 0; result.translateY = 0; return result
        }
        let scaleX = viewport.width / imageSize.width, scaleY = viewport.height / imageSize.height
        let base = fill == .cover ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let maximumX = max(0, (imageSize.width * base * result.scale - viewport.width) / (2 * viewport.width))
        let maximumY = max(0, (imageSize.height * base * result.scale - viewport.height) / (2 * viewport.height))
        result.translateX = min(maximumX, max(-maximumX, finite(value.translateX)))
        result.translateY = min(maximumY, max(-maximumY, finite(value.translateY)))
        return result
    }

    private static func resize(_ node: SplitNode, splitID: String, index: Int,
                               delta: CGFloat, minimumLeading: CGFloat, minimumTrailing: CGFloat) -> SplitNode {
        guard case .split(let id, let direction, let input, let children) = node else { return node }
        if id != splitID {
            return .split(id: id, direction: direction, ratios: input, children: children.map {
                resize($0, splitID: splitID, index: index, delta: delta,
                       minimumLeading: minimumLeading, minimumTrailing: minimumTrailing)
            })
        }
        guard index >= 0, index + 1 < children.count else { return node }
        var ratios = normalizedRatios(input, count: children.count)
        let total = ratios[index] + ratios[index + 1]
        let lower = max(0, minimumLeading), upper = total - max(0, minimumTrailing)
        guard upper >= lower else { return node }
        ratios[index] = min(upper, max(lower, ratios[index] + delta))
        ratios[index + 1] = total - ratios[index]
        return .split(id: id, direction: direction, ratios: ratios, children: children)
    }

    private static func intrinsicUnits(_ node: SplitNode, along axis: CollageSplitDirection) -> Int {
        switch node {
        case .slot: return 1
        case .split(_, let direction, _, let children):
            let units = children.map { intrinsicUnits($0, along: axis) }
            return max(1, direction == axis ? units.reduce(0, +) : units.max() ?? 1)
        }
    }

    private static func minimumExtent(_ node: SplitNode, along axis: CollageSplitDirection,
                                      leafMinimum: CGFloat, gap: CGFloat) -> CGFloat {
        switch node {
        case .slot: return leafMinimum
        case .split(_, let direction, let values, let children):
            let extents = children.map { minimumExtent($0, along: axis, leafMinimum: leafMinimum, gap: gap) }
            guard direction == axis else { return extents.max() ?? leafMinimum }
            let ratios = normalizedRatios(values, count: children.count)
            // Resizing this ancestor leaves descendant ratios fixed. Account for
            // the smallest leaf in those proportions, not merely leaf counts.
            let required = zip(extents, ratios).map { extent, ratio in extent / max(0.000001, ratio) }.max() ?? leafMinimum
            return required + gap * CGFloat(max(0, children.count - 1))
        }
    }

    private static func finite(_ number: CGFloat) -> CGFloat { number.isFinite ? number : 0 }
}
