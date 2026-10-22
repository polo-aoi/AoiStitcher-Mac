import SwiftUI

nonisolated enum LongStitchWatermarkCorner: CaseIterable, Hashable {
    case topLeft, topRight, bottomRight, bottomLeft

    var opposite: Self {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomRight: return .topLeft
        case .bottomLeft: return .topRight
        }
    }

    private var signs: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: -1, y: -1)
        case .topRight: return CGPoint(x: 1, y: -1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottomLeft: return CGPoint(x: -1, y: 1)
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: signs.x < 0 ? rect.minX : rect.maxX,
                y: signs.y < 0 ? rect.minY : rect.maxY)
    }

    fileprivate var direction: CGPoint { signs }
}

nonisolated enum LongStitchWatermarkGeometry {
    static let selectionLineWidth: CGFloat = 1.5
    static let handleDiameter: CGFloat = 9
    static let handleHitRadius: CGFloat = 10

    /// Handle hit testing uses viewport points so it stays usable at any zoom.
    static func handle(at point: CGPoint, in viewportRect: CGRect) -> LongStitchWatermarkCorner? {
        guard isValid(viewportRect), isFinite(point) else { return nil }
        var nearest: LongStitchWatermarkCorner?
        var nearestDistance = CGFloat.infinity
        for corner in LongStitchWatermarkCorner.allCases {
            let position = corner.point(in: viewportRect)
            let distance = hypot(point.x - position.x, point.y - position.y)
            if distance <= handleHitRadius, distance < nearestDistance {
                nearest = corner
                nearestDistance = distance
            }
        }
        return nearest
    }

    static func maximumSize(imageSize: CGSize, in region: CGRect) -> CGSize {
        guard isValid(region), imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let factor = min(region.width / imageSize.width, region.height / imageSize.height)
        return CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
    }

    /// The start rectangle, points and region all use canvas coordinates.
    static func movedRect(from startRect: CGRect, startPoint: CGPoint,
                          currentPoint: CGPoint, in region: CGRect) -> CGRect {
        guard isValid(startRect), isValid(region), isFinite(startPoint), isFinite(currentPoint) else {
            return startRect
        }
        let x = startRect.minX + currentPoint.x - startPoint.x
        let y = startRect.minY + currentPoint.y - startPoint.y
        return CGRect(x: clamp(x, region.minX, max(region.minX, region.maxX - startRect.width)),
                      y: clamp(y, region.minY, max(region.minY, region.maxY - startRect.height)),
                      width: startRect.width, height: startRect.height)
    }

    /// Project pointer movement onto the corner diagonal, preserving its initial grab offset.
    /// The opposite corner stays fixed, including when the region limits enlargement.
    static func resizedRect(from startRect: CGRect, corner: LongStitchWatermarkCorner,
                            startPoint: CGPoint, currentPoint: CGPoint, in region: CGRect) -> CGRect {
        guard isValid(startRect), isValid(region), isFinite(startPoint), isFinite(currentPoint) else {
            return startRect
        }
        let maximum = maximumSize(imageSize: startRect.size, in: region)
        let anchor = corner.opposite.point(in: startRect)
        let direction = corner.direction
        let availableWidth = direction.x > 0 ? region.maxX - anchor.x : anchor.x - region.minX
        let availableHeight = direction.y > 0 ? region.maxY - anchor.y : anchor.y - region.minY
        let upperScale = max(0, min(1, availableWidth / maximum.width, availableHeight / maximum.height))
        // A valid start rectangle already leaves room for the 5% minimum at this anchor.
        let lowerScale = min(0.05, upperScale)
        let diagonal = CGPoint(x: maximum.width * direction.x, y: maximum.height * direction.y)
        let delta = CGPoint(x: currentPoint.x - startPoint.x, y: currentPoint.y - startPoint.y)
        let projectedChange = (delta.x * diagonal.x + delta.y * diagonal.y)
            / (maximum.width * maximum.width + maximum.height * maximum.height)
        let scale = clamp(startRect.width / maximum.width + projectedChange, lowerScale, upperScale)
        let size = CGSize(width: maximum.width * scale, height: maximum.height * scale)
        return CGRect(x: direction.x > 0 ? anchor.x : anchor.x - size.width,
                      y: direction.y > 0 ? anchor.y : anchor.y - size.height,
                      width: size.width, height: size.height)
    }

    /// Scale is a fraction of the largest image that fits inside this margin.
    static func parameters(for rect: CGRect, imageSize: CGSize,
                           in region: CGRect) -> (scale: Double, offsetX: Double, offsetY: Double) {
        let maximum = maximumSize(imageSize: imageSize, in: region)
        guard isValid(rect), maximum.width > 0, maximum.height > 0 else { return (1, 0, 0) }
        let remainingX = region.width - rect.width
        let remainingY = region.height - rect.height
        let x = remainingX > 0.000_001 ? 2 * (rect.minX - region.minX) / remainingX - 1 : 0
        let y = remainingY > 0.000_001 ? 2 * (rect.minY - region.minY) / remainingY - 1 : 0
        return (Double(clamp(rect.width / maximum.width, 0.05, 1)),
                Double(clamp(x, -1, 1)), Double(clamp(y, -1, 1)))
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        isFinite(rect.origin) && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}

/// Place in the viewport overlay; the event owner handles all pointer interaction.
struct LongStitchWatermarkSelection: View {
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { $0.addRect(rect) }
                .stroke(Color.accentColor, lineWidth: LongStitchWatermarkGeometry.selectionLineWidth)
            ForEach(LongStitchWatermarkCorner.allCases, id: \.self) { corner in
                Circle()
                    .fill(Color.white)
                    .overlay {
                        Circle().stroke(Color.accentColor,
                                        lineWidth: LongStitchWatermarkGeometry.selectionLineWidth)
                    }
                    .frame(width: LongStitchWatermarkGeometry.handleDiameter,
                           height: LongStitchWatermarkGeometry.handleDiameter)
                    .position(corner.point(in: rect))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
