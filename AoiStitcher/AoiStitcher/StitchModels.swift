import SwiftUI
import AppKit

// ==========================================
// 0. SwiftUI 兼容性扩展
// ==========================================
extension Binding where Value == CGFloat {
    var asDouble: Binding<Double> {
        Binding<Double>(
            get: { Double(self.wrappedValue) },
            set: { self.wrappedValue = CGFloat($0) }
        )
    }
}

// ==========================================
// 1. 数据模型与基础组件
// ==========================================
struct CropInfo: Equatable {
    var uiCropRect: CGRect
    var rotation: Double
    var imageCenter: CGPoint
    var scale: CGFloat
}

struct OverlayWatermark: Identifiable, Equatable {
    let id = UUID()
    var image: NSImage
    var offset: CGSize = .zero
    var scale: CGFloat = 1.0
    var rotation: Double = 0.0
}

struct StitchItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let image: NSImage
    var cropInfo: CropInfo?
    var watermarks: [OverlayWatermark] = []
    var croppedImage: NSImage?
    var displayImage: NSImage { return croppedImage ?? image }

    // 💡 高性能缓存：专门为解决拖拽卡顿准备的长宽比例缓存
    var displayAspect: CGFloat {
        return displayImage.size.width / max(1, displayImage.size.height)
    }

    static func == (lhs: StitchItem, rhs: StitchItem) -> Bool {
        lhs.id == rhs.id && lhs.cropInfo == rhs.cropInfo && lhs.watermarks == rhs.watermarks
    }
}

enum CropRatioPreset: String, CaseIterable, Identifiable {
    case free = "自由", original = "原图", square = "1:1"
    case r4_3 = "4:3", r3_4 = "3:4"
    case r3_2 = "3:2", r2_3 = "2:3"
    case r16_9 = "16:9", r9_16 = "9:16"

    var id: String { self.rawValue }
    var ratioValue: CGFloat? {
        switch self {
        case .free, .original: return nil
        case .square: return 1.0
        case .r4_3: return 4.0 / 3.0; case .r3_4: return 3.0 / 4.0
        case .r3_2: return 3.0 / 2.0; case .r2_3: return 2.0 / 3.0
        case .r16_9: return 16.0 / 9.0; case .r9_16: return 9.0 / 16.0
        }
    }
}
