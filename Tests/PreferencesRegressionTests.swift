import Foundation

enum PreferencesRegressionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError("FAIL: " + message) }
            checks += 1
        }
        let domain = "aoistitcher.preference-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("2200", forKey: "exportWidth")
        defaults.set(false, forKey: "exportPNG")
        defaults.set(2, forKey: "colorSchemeStyle")
        defaults.set("/tmp", forKey: "lastExportDir")
        defaults.set("untouched", forKey: "unrelated-value")
        defaults.set(DragPanMode.keyboard.rawValue, forKey: AppPreferences.gridPanModeKey)
        defaults.set(LongStitchPanKey.command.rawValue, forKey: AppPreferences.gridPanKeyKey)
        let defaultWorkspaces: [AppWorkspace] = [.gridCollage, .freeCanvas, .longStitch]
        let legacyWorkspaceOrder = #"["border","longStitch","compression","freeCanvas","gridCollage","longStitch","unknown"]"#
        defaults.set(legacyWorkspaceOrder, forKey: AppPreferences.workspaceOrderKey)
        check(AppPreferences.workspaceOrder(from: "") == defaultWorkspaces &&
              AppPreferences.workspaceOrder(from: "[]") == defaultWorkspaces,
              "Empty workspace preferences use standard collage, free canvas and long stitch")
        check(AppPreferences.workspaceOrder(from: legacyWorkspaceOrder) == [.longStitch, .freeCanvas, .gridCollage],
              "Legacy workspace order drops removed tools and duplicates while preserving remaining custom order")
        check(AppPreferences.workspaceOrder(from: #"["compression","freeCanvas","border"]"#) == [.freeCanvas, .gridCollage, .longStitch],
              "Legacy partial workspace order fills missing supported tools without restoring removed ones")
        let customWorkspaces: [AppWorkspace] = [.longStitch, .gridCollage, .freeCanvas]
        check(AppPreferences.workspaceOrder(from: AppPreferences.encodeWorkspaceOrder(customWorkspaces)) == customWorkspaces,
              "The remaining workspace order survives saving and reopening")
        AppPreferences.restoreExportDefaults(in: defaults)
        check(defaults.string(forKey: "exportWidth") == "2560" && defaults.bool(forKey: "exportPNG"), "Export reset restores width and format")
        check(defaults.integer(forKey: "colorSchemeStyle") == 2 && defaults.string(forKey: "lastExportDir") == "/tmp", "Export reset preserves theme and remembered folders")
        check(defaults.string(forKey: AppPreferences.gridPanModeKey) == DragPanMode.keyboard.rawValue &&
              defaults.string(forKey: AppPreferences.gridPanKeyKey) == LongStitchPanKey.command.rawValue,
              "Export reset preserves standard collage shortcuts")
        check(defaults.string(forKey: AppPreferences.workspaceOrderKey) == legacyWorkspaceOrder,
              "Export reset preserves the customized workspace order")
        defaults.set(true, forKey: AppPreferences.skipGroupingPromptKey)
        defaults.set(true, forKey: AppPreferences.materialSelectionHintDismissedKey)
        AppPreferences.restoreGuidanceDefaults(in: defaults)
        check(defaults.object(forKey: AppPreferences.skipGroupingPromptKey) == nil &&
              defaults.object(forKey: AppPreferences.materialSelectionHintDismissedKey) == nil,
              "Guidance reset re-enables both dismissible onboarding hints")
        check(defaults.integer(forKey: "colorSchemeStyle") == 2 && defaults.string(forKey: "lastExportDir") == "/tmp",
              "Guidance reset preserves appearance and remembered export location")
        AppPreferences.restoreDefaults(in: defaults)
        check(defaults.integer(forKey: "colorSchemeStyle") == 1 && defaults.object(forKey: "lastExportDir") == nil, "Software reset restores theme and remembered folders")
        check(defaults.string(forKey: "unrelated-value") == "untouched", "Software reset affects only owned preferences")
        check(defaults.object(forKey: AppPreferences.gridPanModeKey) == nil &&
              defaults.object(forKey: AppPreferences.gridPanKeyKey) == nil,
              "Software reset removes standard collage overrides so the default drag mode returns")
        check(defaults.object(forKey: AppPreferences.workspaceOrderKey) == nil &&
              AppPreferences.workspaceOrder(from: defaults.string(forKey: AppPreferences.workspaceOrderKey) ?? "") == defaultWorkspaces,
              "Software reset restores the three-tool default workspace order")
        check(AppPreferences.exportWidth(" 2200 ") == 2200, "Width validation accepts whitespace")
        check(["0", "-1", "16385", "abc", "1.5"].allSatisfy { AppPreferences.exportWidth($0) == nil }, "Width validation rejects invalid and unsafe dimensions")
        let decoder = JSONDecoder()
        let migrationCases: [(String, DragPanMode)] = [
            (#"{}"#, .rightMouse),
            (#"{"rightMousePanEnabled":true,"keyboardPanEnabled":true}"#, .rightMouse),
            (#"{"rightMousePanEnabled":true,"keyboardPanEnabled":false}"#, .rightMouse),
            (#"{"rightMousePanEnabled":false,"keyboardPanEnabled":true}"#, .keyboard),
            (#"{"rightMousePanEnabled":false,"keyboardPanEnabled":false}"#, .rightMouse),
            (#"{"panMode":"keyboard","rightMousePanEnabled":true,"keyboardPanEnabled":false}"#, .keyboard)
        ]
        for (json, expectedMode) in migrationCases {
            let settings = try decoder.decode(LongStitchSettings.self, from: Data(json.utf8))
            check(settings.panMode == expectedMode, "Legacy settings migrate to the expected exclusive drag mode: " + json)
            check(settings.rightMousePanEnabled != settings.keyboardPanEnabled,
                  "Migrated settings enable exactly one drag mode")
        }

        let libraryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: libraryDirectory) }
        let library = WatermarkLibraryStore(directoryURL: libraryDirectory)
        let legacyJSON = #"{"rightMousePanEnabled":false,"keyboardPanEnabled":true,"panKey":"command","spacing":31,"exportShortEdge":"3200"}"#
        defaults.set(Data(legacyJSON.utf8), forKey: LongStitchPreferences.settingsKey)
        defaults.set(true, forKey: LongStitchPreferences.migrationKey)
        let preferences = LongStitchPreferences(defaults: defaults, library: library)
        check(preferences.settings.panMode == .keyboard && preferences.settings.panKey == .command,
              "Loading saved legacy preferences preserves a keyboard-only choice and its key")
        preferences.settings.panMode = .rightMouse
        try preferences.flushSettings()
        let saved = try decoder.decode(LongStitchSettings.self,
                                       from: defaults.data(forKey: LongStitchPreferences.settingsKey)!)
        check(saved.panMode == .rightMouse && saved.panKey == .command &&
              saved.spacing == 31 && saved.exportShortEdge == "3200",
              "Saving a new drag mode preserves the chosen key and unrelated long-stitch preferences")
        let reopened = LongStitchPreferences(defaults: defaults, library: library)
        check(reopened.settings == saved, "The exclusive drag mode survives reopening preferences")
        reopened.restoreDefaults()
        let reset = try decoder.decode(LongStitchSettings.self,
                                       from: defaults.data(forKey: LongStitchPreferences.settingsKey)!)
        check(reset.panMode == .rightMouse && reset.panKey == .space,
              "Restoring long-stitch defaults persists right-mouse dragging with Space as the alternate key")
        return checks
    }
}
