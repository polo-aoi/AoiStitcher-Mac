import SwiftUI

@main
struct AoiStitcherApp: App {
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 AoiStitcher") { openWindow(id: "about") }
            }
        }
        Settings { AppSettingsView() }
        Window("关于 AoiStitcher", id: "about") { AboutView() }
            .windowResizability(.contentSize)
        Window("支持作者", id: "support-author") { SupportAuthorView() }
            .windowResizability(.contentSize)
    }
}
