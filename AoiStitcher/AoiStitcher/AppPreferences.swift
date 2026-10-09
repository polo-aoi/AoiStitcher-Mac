import Foundation

enum AppPreferences {
    static let defaultExportWidth = "2560"
    static let defaultExportPNG = true
    static let defaultTheme = 1
    static let exportKeys = ["exportWidth", "exportPNG"]
    static let preferenceKeys = exportKeys + ["colorSchemeStyle", "lastExportDir", "lastGlobalWatermarkDir", "lastLocalWatermarkDir"]

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
        defaults.set(defaultTheme, forKey: "colorSchemeStyle")
        for key in preferenceKeys where key.hasPrefix("last") { defaults.removeObject(forKey: key) }
    }
}
