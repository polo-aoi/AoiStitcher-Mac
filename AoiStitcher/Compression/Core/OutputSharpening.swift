import Foundation
import CoreImage
import CoreGraphics
import Metal

/// Independent reference implementation reconstructed from static instructions.
/// This is not ImageFit's original Swift source or a complete image pipeline.
nonisolated enum OutputSharpeningLevel: String, CaseIterable, Sendable {
    case off, light, standard, medium, strong

    /// Float values match the recovered five-entry tables.
    var parameters: (radius: Float, intensity: Float) {
        switch self {
        case .off:      return (0, 0)
        case .light:    return (1.2, 0.4)
        case .standard: return (1.6, 0.5)
        case .medium:   return (2.0, 0.6)
        case .strong:   return (2.4, 0.7)
        }
    }
}

