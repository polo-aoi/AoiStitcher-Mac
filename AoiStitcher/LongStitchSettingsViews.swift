import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LongStitchLayoutControls: View {
    @ObservedObject var preferences: LongStitchPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("排版").font(.callout.weight(.semibold))
                Spacer()
                Button("恢复默认") { preferences.restoreDefaults() }
                    .buttonStyle(.borderless)
                    .help("恢复所有长图出厂设置，包括留白、水印和快捷键；保留照片。")
                    .accessibilityLabel("恢复长图出厂设置")
            }
            Picker("排列方向", selection: $preferences.settings.direction) {
                ForEach(LongStitchDirection.allCases) { direction in
                    Text(direction.title).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("长图排列方向")

            VStack(spacing: 8) {
                LongStitchNumberRow(title: "图片间距", value: $preferences.settings.spacing, unit: "px")
                Slider(value: $preferences.settings.spacing, in: 0...300, step: 1)
                    .accessibilityLabel("图片间距")
            }
            Divider()
            VStack(spacing: 10) {
                ForEach(LongStitchEdge.allCases) { edge in
                    LongStitchMarginControls(preferences: preferences, edge: edge)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LongStitchMarginControls: View {
    @ObservedObject var preferences: LongStitchPreferences
    let edge: LongStitchEdge
    @State private var isExpanded = false

    private var margin: LongStitchMargin { preferences.settings[edge].sanitized() }

    private func binding<Value>(_ keyPath: WritableKeyPath<LongStitchMargin, Value>) -> Binding<Value> {
        Binding {
            preferences.settings[edge][keyPath: keyPath]
        } set: { value in
            var next = preferences.settings
            var margin = next[edge]
            margin[keyPath: keyPath] = value
            next[edge] = margin.sanitized()
            preferences.settings = next
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle("\(edge.title)留白", isOn: binding(\.isEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if margin.isEnabled {
                    Text("\(Int(margin.size)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "收起\(edge.title)留白设置" : "展开\(edge.title)留白设置")
                    .accessibilityLabel(isExpanded ? "收起\(edge.title)留白设置" : "展开\(edge.title)留白设置")
                }
            }
            if margin.isEnabled && isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 6) {
                        LongStitchNumberRow(title: "留白大小", value: binding(\.size), unit: "px")
                        Slider(value: binding(\.size), in: 0...1600, step: 1)
                            .accessibilityLabel("\(edge.title)留白大小")
                    }
                    Toggle("在此处使用水印", isOn: binding(\.usesWatermark))
                        .toggleStyle(.checkbox)
                    if margin.usesWatermark {
                        if preferences.watermark == nil {
                            Text("请在下方添加共享水印。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 6) {
                            LongStitchNumberRow(title: "水印缩放", value: binding(\.watermarkScale), unit: "倍", fractionDigits: 2)
                            Slider(value: binding(\.watermarkScale), in: 0.1...3)
                                .accessibilityLabel("\(edge.title)水印缩放")
                        }
                        VStack(spacing: 6) {
                            Text("水平位置").font(.caption).foregroundStyle(.secondary)
                            Slider(value: binding(\.offsetX), in: -1...1)
                                .accessibilityLabel("\(edge.title)水印水平位置")
                            HStack { Text("左"); Spacer(); Text("右") }
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 6) {
                            Text("垂直位置").font(.caption).foregroundStyle(.secondary)
                            Slider(value: binding(\.offsetY), in: -1...1)
                                .accessibilityLabel("\(edge.title)水印垂直位置")
                            HStack { Text("上"); Spacer(); Text("下") }
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.bottom, 4)
            }
        }
        .onChange(of: margin.isEnabled) { _, enabled in isExpanded = enabled }
    }
}

struct LongStitchWatermarkControls: View {
    @ObservedObject var preferences: LongStitchPreferences
    @State private var importError: String?

    var body: some View {
        EditorSection("共享水印") {
            HStack(spacing: 8) {
                Button(action: importWatermark) {
                    Label(preferences.watermark == nil ? "添加水印" : "更换水印", systemImage: "photo.badge.plus")
                }
                Spacer()
                if preferences.watermark != nil {
                    Button { preferences.removeWatermark() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除共享水印")
                    .accessibilityLabel("删除共享水印")
                }
            }
            if let watermark = preferences.watermark {
                Image(nsImage: watermark)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("共享水印预览")
            }
            TextField("水印备注（可选）", text: $preferences.settings.watermarkNote)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("水印备注")
            Text("使用自己提供的水印，在各边留白中分别选择是否使用。备注仅用于记录。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("无法添加水印", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("确定") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func importWatermark() {
        let panel = NSOpenPanel()
        panel.title = "选择共享水印"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try preferences.importWatermark(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }
}

struct LongStitchExportSettingsFields: View {
    @ObservedObject var preferences: LongStitchPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("短边像素")
                Spacer()
                TextField("2560", text: $preferences.settings.exportShortEdge)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityLabel("长图短边像素，不包含留白")
                Text("px").foregroundStyle(.secondary)
            }
            Text("不包含四边留白。导出后，留白会额外增加画布尺寸。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("图片格式")
                Spacer()
                Picker("长图图片格式", selection: $preferences.settings.exportPNG) {
                    Text("PNG").tag(true)
                    Text("JPEG").tag(false)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 170)
            }
            if preferences.settings.validatedExportShortEdge == nil {
                Text("短边像素需为 1 到 16384 的整数。")
                    .font(.callout).foregroundStyle(.red)
            }
        }
    }
}

struct LongStitchExportSettingsView: View {
    @ObservedObject var preferences: LongStitchPreferences
    var outputSize: String = ""
    @Environment(\.dismiss) private var dismiss
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("长图导出设置").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            LongStitchExportSettingsFields(preferences: preferences)
            if !outputSize.isEmpty {
                Text(outputSize).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Divider()
            Button {
                let defaults = LongStitchSettings()
                preferences.settings.exportShortEdge = defaults.exportShortEdge
                preferences.settings.exportPNG = defaults.exportPNG
            } label: {
                Label("恢复导出默认设置", systemImage: "arrow.counterclockwise")
            }
        }
        .padding(20).frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
        .preferredColorScheme(theme == 2 ? .dark : .light)
    }
}

private struct LongStitchNumberRow: View {
    let title: String
    @Binding var value: Double
    var unit: String = ""
    var fractionDigits: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...fractionDigits)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .accessibilityLabel(title)
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }
    }
}
