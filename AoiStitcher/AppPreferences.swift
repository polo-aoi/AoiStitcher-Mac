import Foundation

nonisolated enum CanvasScrollBehavior: String, CaseIterable, Identifiable {
    case zoom, pan

    var id: String { rawValue }
    var title: String { self == .zoom ? "缩放查看" : "平移查看" }
}

nonisolated struct CanvasInteractionSettings: Equatable {
    var wheelBehavior: CanvasScrollBehavior = .zoom
    var gestureBehavior: CanvasScrollBehavior = .pan
    var zoomSensitivity: Double = 1
    var reverseZoom = false
    var panMode: DragPanMode = .rightMouse
    var panKey: LongStitchPanKey = .space

    var hint: String {
        let wheel = wheelBehavior == .zoom ? "滚轮缩放" : "滚轮平移"
        let drag = panMode == .rightMouse ? "右键拖动画布" : "\(panKey.title) + 左键拖动画布"
        return "\(wheel) · \(drag)"
    }
}

nonisolated enum AppWorkspace: String, CaseIterable, Identifiable {
    case gridCollage, freeCanvas, longStitch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .freeCanvas: return "自由画布"
        case .longStitch: return "长图拼接"
        case .gridCollage: return "标准拼图"
        }
    }
    var systemImage: String {
        switch self {
        case .freeCanvas: return "rectangle.on.rectangle"
        case .longStitch: return "rectangle.split.1x2"
        case .gridCollage: return "square.grid.2x2"
        }
    }
}

enum AppPreferences {
    static let defaultExportWidth = "2560"
    static let defaultExportPNG = true
    static let defaultTheme = 1
    static let gridPanModeKey = "gridCollage.panMode"
    static let gridPanKeyKey = "gridCollage.panKey"
    static let workspaceOrderKey = "workspaceOrder.v1"
    static let canvasWheelBehaviorKey = "freeCanvas.wheelBehavior"
    static let canvasGestureBehaviorKey = "freeCanvas.gestureBehavior"
    static let canvasZoomSensitivityKey = "freeCanvas.zoomSensitivity"
    static let canvasReverseZoomKey = "freeCanvas.reverseZoom"
    static let canvasPanModeKey = "freeCanvas.panMode"
    static let canvasPanKeyKey = "freeCanvas.panKey"
    static let canvasInteractionKeys = [canvasWheelBehaviorKey, canvasGestureBehaviorKey,
        canvasZoomSensitivityKey, canvasReverseZoomKey, canvasPanModeKey, canvasPanKeyKey]
    static let exportKeys = ["exportWidth", "exportPNG"]
    // The project root is intentionally NOT included in preferenceKeys: restoring
    // defaults must never relocate the user's existing projects.
    static nonisolated let projectRootKey = "projectRootDirectory.v1"
    static nonisolated let defaultProjectRootName = "AoiStitcher 项目"
    static let preferenceKeys = exportKeys + canvasInteractionKeys + ["colorSchemeStyle", "lastExportDir", "lastGlobalWatermarkDir", "lastLocalWatermarkDir", gridPanModeKey, gridPanKeyKey, workspaceOrderKey]

    /// The user-facing directory that holds every project folder. Defaults to
    /// `~/Pictures/AoiStitcher 项目/` so copies and project data stay visible and
    /// backup-friendly instead of buried in Application Support.
    static nonisolated func projectRootURL(in defaults: UserDefaults = .standard) -> URL {
        if let stored = defaults.string(forKey: projectRootKey),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: stored, isDirectory: true)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent(defaultProjectRootName, isDirectory: true)
    }

    static func workspaceOrder(from storedOrder: String) -> [AppWorkspace] {
        let identifiers = (try? JSONDecoder().decode([String].self, from: Data(storedOrder.utf8))) ?? []
        var order: [AppWorkspace] = []
        // Keep every workspace exactly once, including newly added functions.
        for workspace in identifiers.compactMap(AppWorkspace.init(rawValue:)) + AppWorkspace.allCases {
            if !order.contains(workspace) { order.append(workspace) }
        }
        return order
    }

    static func encodeWorkspaceOrder(_ order: [AppWorkspace]) -> String {
        guard let data = try? JSONEncoder().encode(order.map(\.rawValue)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func exportWidth(_ text: String) -> Int? {
        guard let width = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (1...16384).contains(width) else { return nil }
        return width
    }

    static func restoreExportDefaults(in defaults: UserDefaults = .standard) {
        defaults.set(defaultExportWidth, forKey: "exportWidth")
        defaults.set(defaultExportPNG, forKey: "exportPNG")
    }

    static func restoreDefaults(in defaults: UserDefaults = .standard) {
        restoreExportDefaults(in: defaults)
        restoreCanvasInteractionDefaults(in: defaults)
        defaults.set(defaultTheme, forKey: "colorSchemeStyle")
        defaults.removeObject(forKey: gridPanModeKey)
        defaults.removeObject(forKey: gridPanKeyKey)
        defaults.removeObject(forKey: workspaceOrderKey)
        for key in preferenceKeys where key.hasPrefix("last") { defaults.removeObject(forKey: key) }
    }

    static func restoreCanvasInteractionDefaults(in defaults: UserDefaults = .standard) {
        for key in canvasInteractionKeys { defaults.removeObject(forKey: key) }
    }
}
