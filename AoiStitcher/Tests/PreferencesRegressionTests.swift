import Foundation

enum PreferencesRegressionTests {
    static func run() -> Int {
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
        AppPreferences.restoreExportDefaults(in: defaults)
        check(defaults.string(forKey: "exportWidth") == "2560" && defaults.bool(forKey: "exportPNG"), "Export reset restores width and format")
        check(defaults.integer(forKey: "colorSchemeStyle") == 2 && defaults.string(forKey: "lastExportDir") == "/tmp", "Export reset preserves theme and remembered folders")
        AppPreferences.restoreDefaults(in: defaults)
        check(defaults.integer(forKey: "colorSchemeStyle") == 1 && defaults.object(forKey: "lastExportDir") == nil, "Software reset restores theme and remembered folders")
        check(defaults.string(forKey: "unrelated-value") == "untouched", "Software reset affects only owned preferences")
        check(AppPreferences.exportWidth(" 2200 ") == 2200, "Width validation accepts whitespace")
        check(["0", "-1", "16385", "abc", "1.5"].allSatisfy { AppPreferences.exportWidth($0) == nil }, "Width validation rejects invalid and unsafe dimensions")
        return checks
    }
}
