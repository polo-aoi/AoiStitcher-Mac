import AppKit
import Combine
import Foundation

nonisolated enum LongStitchDirection: String, Codable, CaseIterable, Identifiable {
    case vertical, horizontal

    var id: String { rawValue }
    var title: String { isVertical ? "纵向" : "横向" }
    var isVertical: Bool { self == .vertical }
}

nonisolated enum LongStitchEdge: String, Codable, CaseIterable, Identifiable {
    case top, bottom, left, right

    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: return "顶部"
        case .bottom: return "底部"
        case .left: return "左侧"
        case .right: return "右侧"
        }
    }
}

nonisolated enum DragPanMode: String, Codable, CaseIterable, Identifiable {
    case rightMouse, keyboard

    var id: String { rawValue }
    var title: String { self == .rightMouse ? "鼠标右键" : "键盘快捷键 + 左键" }
}

nonisolated enum LongStitchPanKey: String, Codable, CaseIterable, Identifiable {
    case space, option, command, control

    var id: String { rawValue }
    var title: String {
        switch self {
        case .space: return "空格"
        case .option: return "Option ⌥"
        case .command: return "Command ⌘"
        case .control: return "Control ⌃"
        }
    }
    var keyCode: UInt16? { self == .space ? 49 : nil }
    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .space: return []
        case .option: return .option
        case .command: return .command
        case .control: return .control
        }
    }
}

nonisolated enum LongStitchZoomModifier: String, Codable, CaseIterable, Identifiable {
    case option, command, control

    var id: String { rawValue }
    var title: String {
        switch self {
        case .option: return "Option ⌥"
        case .command: return "Command ⌘"
        case .control: return "Control ⌃"
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .command: return .command
        case .control: return .control
        }
    }
}

nonisolated enum LongStitchWheelMode: String, Codable, CaseIterable, Identifiable {
    case zoom, scroll

    var id: String { rawValue }
    var title: String { self == .zoom ? "滚轮缩放" : "滚轮滚动" }
}

nonisolated struct LongStitchMargin: Codable, Equatable {
    var isEnabled = false
    /// Distances are output pixels, independent of preview magnification.
    var size: Double = 150
    var usesWatermark = false
    var watermarkID: UUID?
    /// Fraction of the largest image that fits completely inside this margin.
    var watermarkScale: Double = 0.7 {
        didSet { legacyWatermarkScale = nil }
    }
    /// The old scale was relative to 30% of the photo content's short edge.
    /// Keep it until a real image and layout are available for conversion.
    private(set) var legacyWatermarkScale: Double?
    /// Normalized positions within the remaining room, from -1 to 1.
    var offsetX: Double = 0
    var offsetY: Double = 0

    init(isEnabled: Bool = false, size: Double = 150, usesWatermark: Bool = false,
         watermarkID: UUID? = nil, watermarkScale: Double = 0.7,
         offsetX: Double = 0, offsetY: Double = 0) {
        self.isEnabled = isEnabled
        self.size = size
        self.usesWatermark = usesWatermark
        self.watermarkID = watermarkID
        self.watermarkScale = watermarkScale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    func sanitized() -> LongStitchMargin {
        var value = self
        value.size = longStitchClamp(size, to: 0...16_384, fallback: 150)
        value.watermarkScale = longStitchClamp(watermarkScale, to: 0.05...1, fallback: 0.7)
        value.legacyWatermarkScale = legacyWatermarkScale.map {
            longStitchClamp($0, to: 0.05...5, fallback: 1)
        }
        value.offsetX = longStitchClamp(offsetX, to: -1...1, fallback: 0)
        value.offsetY = longStitchClamp(offsetY, to: -1...1, fallback: 0)
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, size, usesWatermark, watermarkID, watermarkScale, offsetX, offsetY
        case watermarkScaleVersion, legacyWatermarkScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 150
        usesWatermark = try container.decodeIfPresent(Bool.self, forKey: .usesWatermark) ?? false
        watermarkID = try container.decodeIfPresent(UUID.self, forKey: .watermarkID)
        let version = try container.decodeIfPresent(Int.self, forKey: .watermarkScaleVersion) ?? 1
        let storedScale = try container.decodeIfPresent(Double.self, forKey: .watermarkScale)
        if version >= 2 {
            watermarkScale = storedScale ?? 0.7
            legacyWatermarkScale = try container.decodeIfPresent(Double.self, forKey: .legacyWatermarkScale)
        } else {
            watermarkScale = 0.7
            legacyWatermarkScale = watermarkID != nil || usesWatermark ? (storedScale ?? 1) : nil
        }
        offsetX = try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(size, forKey: .size)
        try container.encode(usesWatermark, forKey: .usesWatermark)
        try container.encodeIfPresent(watermarkID, forKey: .watermarkID)
        try container.encode(watermarkScale, forKey: .watermarkScale)
        try container.encode(2, forKey: .watermarkScaleVersion)
        try container.encodeIfPresent(legacyWatermarkScale, forKey: .legacyWatermarkScale)
        try container.encode(offsetX, forKey: .offsetX)
        try container.encode(offsetY, forKey: .offsetY)
    }
}

nonisolated struct LongStitchSettings: Codable, Equatable {
    var direction: LongStitchDirection = .vertical
    var spacing: Double = 20
    var top = LongStitchMargin()
    var bottom = LongStitchMargin(isEnabled: true)
    var left = LongStitchMargin()
    var right = LongStitchMargin()
    /// Kept only to decode and migrate the former single-watermark preference.
    var watermarkNote = ""
    var exportShortEdge = "2560"
    var exportPNG = true
    var panMode: DragPanMode = .rightMouse
    var rightMousePanEnabled: Bool { panMode == .rightMouse }
    var keyboardPanEnabled: Bool { panMode == .keyboard }
    var panKey: LongStitchPanKey = .space
    var zoomModifier: LongStitchZoomModifier = .option
    var wheelMode: LongStitchWheelMode = .zoom
    var zoomSensitivity: Double = 1

    init(direction: LongStitchDirection = .vertical, spacing: Double = 20,
         top: LongStitchMargin = LongStitchMargin(),
         bottom: LongStitchMargin = LongStitchMargin(isEnabled: true),
         left: LongStitchMargin = LongStitchMargin(),
         right: LongStitchMargin = LongStitchMargin(), watermarkNote: String = "",
         exportShortEdge: String = "2560", exportPNG: Bool = true,
         panMode: DragPanMode = .rightMouse,
         panKey: LongStitchPanKey = .space,
         zoomModifier: LongStitchZoomModifier = .option,
         wheelMode: LongStitchWheelMode = .zoom, zoomSensitivity: Double = 1) {
        self.direction = direction
        self.spacing = spacing
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.watermarkNote = watermarkNote
        self.exportShortEdge = exportShortEdge
        self.exportPNG = exportPNG
        self.panMode = panMode
        self.panKey = panKey
        self.zoomModifier = zoomModifier
        self.wheelMode = wheelMode
        self.zoomSensitivity = zoomSensitivity
    }

    subscript(edge: LongStitchEdge) -> LongStitchMargin {
        get {
            switch edge {
            case .top: return top
            case .bottom: return bottom
            case .left: return left
            case .right: return right
            }
        }
        set {
            switch edge {
            case .top: top = newValue
            case .bottom: bottom = newValue
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }

    func sanitized() -> LongStitchSettings {
        var value = self
        value.spacing = longStitchClamp(spacing, to: 0...16_384, fallback: 20)
        value.zoomSensitivity = longStitchClamp(zoomSensitivity, to: 0.25...2, fallback: 1)
        for edge in LongStitchEdge.allCases { value[edge] = self[edge].sanitized() }
        // Keep text edits, including an empty field, so the UI can validate them.
        return value
    }

    var validatedExportShortEdge: Int? {
        guard let value = Int(exportShortEdge.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...16_384).contains(value) else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case direction, spacing, top, bottom, left, right, watermarkNote
        case exportShortEdge, exportPNG, rightMousePanEnabled, keyboardPanEnabled
        case panMode, panKey, zoomModifier, wheelMode, zoomSensitivity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decodeIfPresent(LongStitchDirection.self, forKey: .direction) ?? .vertical
        spacing = try container.decodeIfPresent(Double.self, forKey: .spacing) ?? 20
        top = try container.decodeIfPresent(LongStitchMargin.self, forKey: .top) ?? LongStitchMargin()
        bottom = try container.decodeIfPresent(LongStitchMargin.self, forKey: .bottom)
            ?? LongStitchMargin(isEnabled: true, usesWatermark: true)
        left = try container.decodeIfPresent(LongStitchMargin.self, forKey: .left) ?? LongStitchMargin()
        right = try container.decodeIfPresent(LongStitchMargin.self, forKey: .right) ?? LongStitchMargin()
        watermarkNote = try container.decodeIfPresent(String.self, forKey: .watermarkNote) ?? ""
        exportShortEdge = try container.decodeIfPresent(String.self, forKey: .exportShortEdge) ?? "2560"
        exportPNG = try container.decodeIfPresent(Bool.self, forKey: .exportPNG) ?? true
        if let mode = try container.decodeIfPresent(DragPanMode.self, forKey: .panMode) {
            panMode = mode
        } else {
            // Old versions allowed both switches. Prefer the default right mouse
            // unless the user explicitly enabled only keyboard panning.
            let rightMouse = try container.decodeIfPresent(Bool.self, forKey: .rightMousePanEnabled) ?? true
            let keyboard = try container.decodeIfPresent(Bool.self, forKey: .keyboardPanEnabled) ?? true
            panMode = !rightMouse && keyboard ? .keyboard : .rightMouse
        }
        panKey = try container.decodeIfPresent(LongStitchPanKey.self, forKey: .panKey) ?? .space
        zoomModifier = try container.decodeIfPresent(LongStitchZoomModifier.self, forKey: .zoomModifier) ?? .option
        wheelMode = try container.decodeIfPresent(LongStitchWheelMode.self, forKey: .wheelMode) ?? .zoom
        zoomSensitivity = try container.decodeIfPresent(Double.self, forKey: .zoomSensitivity) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(direction, forKey: .direction)
        try container.encode(spacing, forKey: .spacing)
        try container.encode(top, forKey: .top)
        try container.encode(bottom, forKey: .bottom)
        try container.encode(left, forKey: .left)
        try container.encode(right, forKey: .right)
        try container.encode(watermarkNote, forKey: .watermarkNote)
        try container.encode(exportShortEdge, forKey: .exportShortEdge)
        try container.encode(exportPNG, forKey: .exportPNG)
        try container.encode(panMode, forKey: .panMode)
        try container.encode(panKey, forKey: .panKey)
        try container.encode(zoomModifier, forKey: .zoomModifier)
        try container.encode(wheelMode, forKey: .wheelMode)
        try container.encode(zoomSensitivity, forKey: .zoomSensitivity)
    }
}

nonisolated private func longStitchClamp(_ value: Double, to range: ClosedRange<Double>,
                                       fallback: Double) -> Double {
    value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
}

@MainActor
final class LongStitchPreferences: ObservableObject {
    static let settingsKey = "longStitchSettings.v1"
    static let migrationKey = "longStitchWatermarkLibraryMigration.v1"
    static let shared = LongStitchPreferences(
        defaults: .standard,
        library: .shared,
        legacyWatermarkURL: defaultLegacyWatermarkURL
    )

    @Published var settings: LongStitchSettings {
        didSet { scheduleSettingsSave() }
    }
    @Published var libraryError: String?

    private let defaults: UserDefaults
    let library: WatermarkLibraryStore
    private let legacyWatermarkURL: URL?
    private var libraryObservation: AnyCancellable?
    private var libraryErrorObservation: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
    private var scheduledSettingsSave: DispatchWorkItem?

    init(defaults: UserDefaults = .standard,
         library: WatermarkLibraryStore? = nil,
         legacyWatermarkURL: URL? = nil) {
        self.defaults = defaults
        self.library = library ?? WatermarkLibraryStore.shared
        self.legacyWatermarkURL = legacyWatermarkURL
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(LongStitchSettings.self, from: data) {
            settings = decoded.sanitized()
        } else {
            settings = LongStitchSettings()
        }
        libraryObservation = self.library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        libraryErrorObservation = self.library.$loadError.compactMap { $0 }.sink { [weak self] error in
            self?.libraryError = error
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                do { try self.flushSettings() }
                catch { self.libraryError = "无法保存长图设置：\(error.localizedDescription)" }
            }
        }
        migrateLegacyWatermarkIfNeeded()
    }

    deinit {
        scheduledSettingsSave?.cancel()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func watermark(for edge: LongStitchEdge) -> NSImage? {
        let margin = settings[edge]
        guard margin.usesWatermark else { return nil }
        return library.image(for: margin.watermarkID)
    }

    func selectWatermark(_ id: UUID?, for edge: LongStitchEdge) {
        updateMargin(edge) {
            if $0.watermarkID == nil, id != nil {
                $0.watermarkScale = 0.7
            }
            $0.watermarkID = id != nil && library.item(id: id) != nil ? id : nil
            $0.usesWatermark = $0.watermarkID != nil
        }
    }

    /// Run outside a SwiftUI body once photo and watermark geometry are available.
    /// Unresolved legacy values remain serializable, including disabled margins.
    func resolveWatermarkScales(in layout: LongStitchLayout) {
        let shortEdge = min(layout.contentRect.width, layout.contentRect.height)
        guard !layout.photoRects.isEmpty, shortEdge.isFinite, shortEdge > 0 else { return }
        var resolved = settings
        for edge in LongStitchEdge.allCases {
            let margin = settings[edge]
            guard margin.legacyWatermarkScale != nil,
                  let region = layout.marginRects[edge], region.width > 0, region.height > 0,
                  let image = library.image(for: margin.watermarkID),
                  image.size.width > 0, image.size.height > 0 else { continue }
            resolved[edge].watermarkScale = LongStitchLayout.effectiveWatermarkScale(
                imageSize: image.size, in: region, contentShortEdge: shortEdge, margin: margin
            )
        }
        if resolved != settings { settings = resolved }
    }

    func deleteWatermark(_ id: UUID) throws {
        let previous = settings
        var updated = previous
        for edge in LongStitchEdge.allCases where updated[edge].watermarkID == id {
            updated[edge].watermarkID = nil
            updated[edge].usesWatermark = false
        }
        settings = updated
        do {
            try flushSettings()
            try library.remove(id: id)
        } catch {
            if library.item(id: id) != nil {
                settings = previous
                do { try flushSettings() }
                catch { libraryError = "无法恢复水印选择设置：\(error.localizedDescription)" }
            }
            throw error
        }
    }

    func resetWatermarkPlacement(for edge: LongStitchEdge) {
        updateMargin(edge) {
            $0.watermarkScale = 0.7
            $0.offsetX = 0
            $0.offsetY = 0
        }
    }

    func copyWatermark(from source: LongStitchEdge, to destinations: [LongStitchEdge]) {
        let sourceMargin = settings[source]
        for destination in destinations where destination != source {
            updateMargin(destination) {
                $0.watermarkID = sourceMargin.watermarkID
                $0.usesWatermark = sourceMargin.usesWatermark
            }
        }
    }

    func restoreDefaults() {
        settings = LongStitchSettings()
        do {
            try flushSettings()
            libraryError = library.loadError
        } catch {
            libraryError = "无法保存长图默认设置：\(error.localizedDescription)"
        }
    }

    /// Called on app termination and by destructive preference changes that need durable state.
    func flushSettings(synchronize: Bool = true) throws {
        scheduledSettingsSave?.cancel()
        scheduledSettingsSave = nil
        let data = try JSONEncoder().encode(settings.sanitized())
        defaults.set(data, forKey: Self.settingsKey)
        if synchronize, !defaults.synchronize() { throw LongStitchPreferencesError.cannotSaveSettings }
    }

    func retryLibraryMigration() {
        library.reload()
        migrateLegacyWatermarkIfNeeded()
    }

    private func scheduleSettingsSave() {
        scheduledSettingsSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                try self.flushSettings(synchronize: false)
            } catch {
                self.libraryError = "无法保存长图设置：\(error.localizedDescription)"
            }
        }
        scheduledSettingsSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func updateMargin(_ edge: LongStitchEdge,
                              _ update: (inout LongStitchMargin) -> Void) {
        var next = settings
        update(&next[edge])
        settings = next
    }

    private func migrateLegacyWatermarkIfNeeded() {
        guard !defaults.bool(forKey: Self.migrationKey) else {
            libraryError = library.loadError
            return
        }
        do {
            var migrated = settings
            if let legacyWatermarkURL,
               FileManager.default.fileExists(atPath: legacyWatermarkURL.path) {
                let identifier = legacyWatermarkURL.standardizedFileURL.path
                let item: WatermarkLibraryItem
                if let existing = library.item(legacySourceIdentifier: identifier) {
                    item = existing
                } else {
                    item = try library.importLegacyImage(
                        from: legacyWatermarkURL,
                        name: "旧长图水印",
                        note: migrated.watermarkNote,
                        legacySourceIdentifier: identifier
                    )
                }
                for edge in LongStitchEdge.allCases where migrated[edge].usesWatermark && migrated[edge].watermarkID == nil {
                    migrated[edge].watermarkID = item.id
                }
                migrated.watermarkNote = ""
            } else {
                // Older versions enabled the bottom watermark even when no image was imported.
                for edge in LongStitchEdge.allCases where migrated[edge].watermarkID == nil {
                    migrated[edge].usesWatermark = false
                }
            }
            if migrated != settings { settings = migrated }
            try flushSettings()
            defaults.set(true, forKey: Self.migrationKey)
            guard defaults.synchronize() else { throw LongStitchPreferencesError.cannotSaveSettings }
            libraryError = library.loadError
        } catch {
            defaults.removeObject(forKey: Self.migrationKey)
            libraryError = "旧水印迁移未完成，可稍后重试：\(error.localizedDescription)"
        }
    }

    private static var defaultLegacyWatermarkURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("aoipic/LongStitch/watermark.png")
    }
}

nonisolated enum LongStitchPreferencesError: LocalizedError {
    case cannotSaveSettings

    var errorDescription: String? { "系统未能保存长图偏好，请检查可用磁盘空间后重试。" }
}

/// All rectangles use output pixels and a top-left origin. Four outer margins
/// never enter the calculation of the photograph content's short edge.
nonisolated struct LongStitchLayout {
    var photoRects: [CGRect]
    var contentRect: CGRect
    var canvasSize: CGSize
    var marginRects: [LongStitchEdge: CGRect]

    init(aspects: [CGFloat], settings: LongStitchSettings) {
        let settings = settings.sanitized()
        let target = CGFloat(settings.validatedExportShortEdge ?? 2560)
        let spacing = CGFloat(settings.spacing)
        let factors = aspects.map { aspect -> CGFloat in
            let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 1
            return settings.direction.isVertical ? 1 / safeAspect : safeAspect
        }
        let totalFactor = factors.reduce(0, +)
        let totalSpacing = CGFloat(max(0, factors.count - 1)) * spacing
        // Usually the cross-axis is the short edge. A single wide photograph,
        // or a short row of portrait photographs, can make the main axis shorter.
        let cross = totalFactor > 0 ? max(target, (target - totalSpacing) / totalFactor) : target
        let main = totalFactor * cross + totalSpacing
        let contentSize = settings.direction.isVertical
            ? CGSize(width: cross, height: main)
            : CGSize(width: main, height: cross)

        let top = settings.top.isEnabled ? CGFloat(settings.top.size) : 0
        let bottom = settings.bottom.isEnabled ? CGFloat(settings.bottom.size) : 0
        let left = settings.left.isEnabled ? CGFloat(settings.left.size) : 0
        let right = settings.right.isEnabled ? CGFloat(settings.right.size) : 0
        contentRect = CGRect(x: left, y: top, width: contentSize.width, height: contentSize.height)
        canvasSize = CGSize(width: ceil(left + contentSize.width + right),
                            height: ceil(top + contentSize.height + bottom))
        marginRects = [
            .top: CGRect(x: 0, y: 0, width: canvasSize.width, height: top),
            .bottom: CGRect(x: 0, y: contentRect.maxY,
                            width: canvasSize.width, height: bottom),
            .left: CGRect(x: 0, y: top, width: left, height: contentSize.height),
            .right: CGRect(x: contentRect.maxX, y: top,
                           width: right, height: contentSize.height)
        ]
        var position: CGFloat = 0
        photoRects = factors.map { factor in
            let length = cross * factor
            let rect = settings.direction.isVertical
                ? CGRect(x: left, y: top + position, width: cross, height: length)
                : CGRect(x: left + position, y: top, width: length, height: cross)
            position += length + spacing
            return rect
        }
    }

    static func maximumWatermarkSize(imageSize: CGSize, in region: CGRect) -> CGSize {
        guard region.width.isFinite, region.height.isFinite,
              region.width > 0, region.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let aspect = imageSize.width / imageSize.height
        if region.width / region.height < aspect {
            return CGSize(width: region.width, height: region.width / aspect)
        }
        return CGSize(width: region.height * aspect, height: region.height)
    }

    static func effectiveWatermarkScale(imageSize: CGSize, in region: CGRect,
                                        contentShortEdge: CGFloat, margin: LongStitchMargin) -> Double {
        let margin = margin.sanitized()
        guard let legacyScale = margin.legacyWatermarkScale,
              contentShortEdge.isFinite, contentShortEdge > 0 else { return margin.watermarkScale }
        let maximum = maximumWatermarkSize(imageSize: imageSize, in: region)
        guard maximum.width > 0 else { return margin.watermarkScale }
        // The old contain clamp is exactly min(desiredWidth, maximum.width).
        // Convert that visible size, rather than interpreting the former multiplier as a percentage.
        let desiredWidth = contentShortEdge * 0.3 * CGFloat(legacyScale)
        return longStitchClamp(Double(min(desiredWidth, maximum.width) / maximum.width),
                               to: 0.05...1, fallback: 0.7)
    }

    static func watermarkRect(imageSize: CGSize, in region: CGRect,
                              contentShortEdge: CGFloat, margin: LongStitchMargin) -> CGRect {
        let maximum = maximumWatermarkSize(imageSize: imageSize, in: region)
        guard maximum.width > 0, maximum.height > 0 else { return .zero }
        let margin = margin.sanitized()
        let scale = CGFloat(effectiveWatermarkScale(imageSize: imageSize, in: region,
                                                   contentShortEdge: contentShortEdge, margin: margin))
        let width = maximum.width * scale
        let height = maximum.height * scale
        let x = region.minX + (region.width - width) * CGFloat(margin.offsetX + 1) / 2
        let y = region.minY + (region.height - height) * CGFloat(margin.offsetY + 1) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated enum LongStitchRenderError: LocalizedError {
    case invalidSize
    case tooLarge
    case renderFailed
    case cannotReadImage(Int)
    case cannotReadWatermark
    case cannotEncodeWatermark
    case watermarkStorageUnavailable
    case cannotSaveWatermark(String)

    var errorDescription: String? {
        switch self {
        case .invalidSize: return "长图尺寸无效，请检查照片、间距和留白设置。"
        case .tooLarge: return "长图超过 6400 万像素或单边 131072 像素，请减小短边像素、间距或留白。"
        case .renderFailed: return "无法分配长图所需的内存，请减小短边像素。"
        case .cannotReadImage(let index): return "无法读取第 \(index + 1) 张照片，请重新导入。"
        case .cannotReadWatermark: return "无法读取水印图片，请选择有效的图片文件。"
        case .cannotEncodeWatermark: return "无法保存水印图片，请尝试其他图片。"
        case .watermarkStorageUnavailable: return "水印保存位置不可用。"
        case .cannotSaveWatermark(let reason): return "无法保存水印：\(reason)"
        }
    }
}

nonisolated enum LongStitchRenderer {
    static let maximumDimension = 131_072
    static let maximumPixelCount: Int64 = 64_000_000

    static func render(images: [NSImage], layout: LongStitchLayout,
                       settings: LongStitchSettings,
                       watermarks: [LongStitchEdge: NSImage]) throws -> NSImage {
        let size = layout.canvasSize
        guard !images.isEmpty, images.count == layout.photoRects.count,
              size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            throw LongStitchRenderError.invalidSize
        }
        guard size.width <= CGFloat(maximumDimension), size.height <= CGFloat(maximumDimension) else {
            throw LongStitchRenderError.tooLarge
        }
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        guard Int64(width) * Int64(height) <= maximumPixelCount else {
            throw LongStitchRenderError.tooLarge
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LongStitchRenderError.renderFailed
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, image) in images.enumerated() {
            guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw LongStitchRenderError.cannotReadImage(index)
            }
            let rect = layout.photoRects[index]
            context.draw(pixels, in: bitmapRect(rect, height: CGFloat(height)))
        }
        let safeSettings = settings.sanitized()
        for edge in LongStitchEdge.allCases {
            let margin = safeSettings[edge]
            guard margin.isEnabled, margin.usesWatermark, margin.watermarkID != nil,
                  let region = layout.marginRects[edge], region.width > 0, region.height > 0 else { continue }
            guard let watermark = watermarks[edge],
                  let pixels = watermark.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw LongStitchRenderError.cannotReadWatermark
            }
            let rect = LongStitchLayout.watermarkRect(
                imageSize: watermark.size, in: region,
                contentShortEdge: min(layout.contentRect.width, layout.contentRect.height),
                margin: margin
            )
            context.saveGState()
            context.clip(to: bitmapRect(region, height: CGFloat(height)))
            context.draw(pixels, in: bitmapRect(rect, height: CGFloat(height)))
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw LongStitchRenderError.renderFailed }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    private static func bitmapRect(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
