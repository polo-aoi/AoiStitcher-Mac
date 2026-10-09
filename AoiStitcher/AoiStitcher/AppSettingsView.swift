import SwiftUI
import AppKit

struct ExportSettingsFields: View {
    @AppStorage("exportWidth") private var width = AppPreferences.defaultExportWidth
    @AppStorage("exportPNG") private var png = AppPreferences.defaultExportPNG

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("导出宽度")
                Spacer()
                TextField("2560", text: $width).textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityLabel("导出宽度，像素")
                Text("px").foregroundStyle(.secondary)
            }
            HStack {
                Text("图片格式")
                Spacer()
                Picker("图片格式", selection: $png) {
                    Text("PNG").tag(true)
                    Text("JPEG").tag(false)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 170)
            }
            if AppPreferences.exportWidth(width) == nil {
                Text("宽度需为 1 到 16384 的整数。").font(.callout).foregroundStyle(.red)
            }
        }
    }
}

struct ExportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme
    var outputSize: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("导出设置").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ExportSettingsFields()
            if !outputSize.isEmpty { Text(outputSize).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            Divider()
            Button { AppPreferences.restoreExportDefaults() } label: {
                Label("恢复默认设置", systemImage: "arrow.counterclockwise")
            }
        }.padding(20).frame(width: 360)
            .background(Color(NSColor.windowBackgroundColor))
            .preferredColorScheme(theme == 2 ? .dark : .light)
    }
}

struct AppSettingsView: View {
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme
    @Environment(\.openWindow) private var openWindow
    @State private var restored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("软件设置").font(.title2.weight(.semibold))
            EditorSection("外观") {
                Picker("外观", selection: $theme) {
                    Label("浅色", systemImage: "sun.max").tag(1)
                    Label("深色", systemImage: "moon").tag(2)
                }.pickerStyle(.segmented).labelsHidden()
            }
            Divider()
            EditorSection("导出") { ExportSettingsFields() }
            Divider()
            HStack {
                Button { openWindow(id: "about") } label: { Label("关于 AoiStitcher", systemImage: "info.circle") }
                Spacer()
                Button { openWindow(id: "support-author") } label: { Label("支持作者", systemImage: "heart") }
            }
            Divider()
            HStack {
                Button { AppPreferences.restoreDefaults(); restored = true } label: {
                    Label("恢复默认设置", systemImage: "arrow.counterclockwise")
                }
                Spacer()
                if restored { Text("已恢复默认设置").font(.callout).foregroundStyle(.secondary) }
            }
            Text("恢复软件偏好，保留当前画布和照片。").font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(width: 440)
            .background(Color(NSColor.windowBackgroundColor))
            .preferredColorScheme(theme == 2 ? .dark : .light)
    }
}
