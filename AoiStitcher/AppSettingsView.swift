import SwiftUI
import AppKit

struct DragPanSettingsFields: View {
    let title: String
    @Binding var mode: DragPanMode
    @Binding var key: LongStitchPanKey

    var body: some View {
        Picker(title, selection: $mode) {
            ForEach(DragPanMode.allCases) { mode in Text(mode.title).tag(mode) }
        }
        .pickerStyle(.radioGroup)
        if mode == .keyboard {
            Picker("按住按键", selection: $key) {
                ForEach(LongStitchPanKey.allCases) { key in Text(key.title).tag(key) }
            }
            Text("按住\(key.title)，再用左键拖拽。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GridCollageSettingsView: View {
    @AppStorage(AppPreferences.gridPanModeKey) private var panMode: DragPanMode = .rightMouse
    @AppStorage(AppPreferences.gridPanKeyKey) private var panKey: LongStitchPanKey = .space

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("标准拼图设置").font(.title2.weight(.semibold))
                EditorSection("图片快捷键") {
                    Text("左键单击选中图片，左键拖到另一格可交换图片位置。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DragPanSettingsFields(title: "框内移动图片", mode: $panMode, key: $panKey)
                }
                Divider()
                Text("选中图片后，滚轮或触控板捏合可缩放图片。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    panMode = .rightMouse
                    panKey = .space
                } label: {
                    Label("恢复默认快捷键", systemImage: "arrow.counterclockwise")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}

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
    @AppStorage(AoiBorderContact.userDefaultsKey) private var contactEmail = ""
    @Environment(\.openWindow) private var openWindow
    @State private var restored = false
    @ObservedObject private var longStitchPreferences = LongStitchPreferences.shared

    var body: some View {
        TabView {
            ScrollView { generalSettings.padding(24) }
                .tabItem { Label("通用", systemImage: "gearshape") }
            LongStitchSidebar(preferences: longStitchPreferences, includePreferences: true)
                .tabItem { Label("长图拼接", systemImage: "rectangle.split.1x2") }
            GridCollageSettingsView()
                .tabItem { Label("标准拼图", systemImage: "square.grid.2x2") }
        }
        .padding(12)
        .frame(width: 600, height: 680)
        .background(Color(NSColor.windowBackgroundColor))
        .preferredColorScheme(theme == 2 ? .dark : .light)
    }

    private var generalSettings: some View {
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
            EditorSection("开发者联系") {
                TextField("开发者邮箱", text: $contactEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .accessibilityLabel("开发者联系邮箱")
                Text("边框工作区的“提交效果”确认后会复制这个邮箱。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button { openWindow(id: "about") } label: { Label("关于 aoipic", systemImage: "info.circle") }
                Spacer()
                Button { openWindow(id: "support-author") } label: { Label("支持作者", systemImage: "heart") }
            }
            Divider()
            HStack {
                Button {
                    LongStitchNumericEditing.discardDrafts()
                    AppPreferences.restoreDefaults()
                    longStitchPreferences.restoreDefaults()
                    restored = true
                } label: {
                    Label("恢复默认设置", systemImage: "arrow.counterclockwise")
                }
                Spacer()
                if restored { Text("已恢复默认设置").font(.callout).foregroundStyle(.secondary) }
            }
            Text("恢复软件偏好，保留当前画布和照片。").font(.callout).foregroundStyle(.secondary)
        }
    }
}
