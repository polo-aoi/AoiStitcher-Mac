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

private struct FreeCanvasSettingsView: View {
    @AppStorage(AppPreferences.canvasWheelBehaviorKey) private var wheelBehavior: CanvasScrollBehavior = .zoom
    @AppStorage(AppPreferences.canvasGestureBehaviorKey) private var gestureBehavior: CanvasScrollBehavior = .pan
    @AppStorage(AppPreferences.canvasZoomSensitivityKey) private var zoomSensitivity = 1.0
    @AppStorage(AppPreferences.canvasReverseZoomKey) private var reverseZoom = false
    @AppStorage(AppPreferences.canvasPanModeKey) private var panMode: DragPanMode = .rightMouse
    @AppStorage(AppPreferences.canvasPanKeyKey) private var panKey: LongStitchPanKey = .space

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("自由画布设置").font(.title2.weight(.semibold))
                EditorSection("浏览画布") {
                    Picker("鼠标滚轮", selection: $wheelBehavior) {
                        ForEach(CanvasScrollBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("触控板连续滚动", selection: $gestureBehavior) {
                        ForEach(CanvasScrollBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    Text("触控板双指滚动默认平移，捏合始终缩放。部分触控鼠标也发送连续滚动手势，可将连续滚动设为缩放。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("滚轮缩放灵敏度")
                        Slider(value: $zoomSensitivity, in: 0.25...3, step: 0.05)
                        Text(String(format: "%.2f×", zoomSensitivity))
                            .font(.callout.monospacedDigit()).frame(width: 50)
                    }
                    Toggle("反转滚轮缩放方向", isOn: $reverseZoom)
                    Text("缩放以鼠标所在位置为中心，只改变查看比例。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                EditorSection("拖动画布") {
                    DragPanSettingsFields(title: "平移方式", mode: $panMode, key: $panKey)
                    Text("左键拖动照片调整位置；选中后显示快捷工具条，右键打开裁剪、替换和删除菜单。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Button { AppPreferences.restoreCanvasInteractionDefaults() } label: {
                    Label("恢复默认操作", systemImage: "arrow.counterclockwise")
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
    @AppStorage(AppPreferences.workspaceOrderKey) private var storedWorkspaceOrder = ""
    @AppStorage(AppPreferences.projectRootKey) private var projectRootPath = ""
    @Environment(\.openWindow) private var openWindow
    @State private var restored = false
    @State private var pendingProjectRoot = false
    @ObservedObject private var longStitchPreferences = LongStitchPreferences.shared

    var body: some View {
        TabView {
            ScrollView { generalSettings.padding(24) }
                .tabItem { Label("通用", systemImage: "gearshape") }
            LongStitchSidebar(preferences: longStitchPreferences, includePreferences: true)
                .tabItem { Label("长图拼接", systemImage: "rectangle.split.1x2") }
            GridCollageSettingsView()
                .tabItem { Label("标准拼图", systemImage: "square.grid.2x2") }
            FreeCanvasSettingsView()
                .tabItem { Label("自由画布", systemImage: "rectangle.on.rectangle") }
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
            projectStorageSection
            Divider()
            workspaceOrderSettings
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

    private var workspaceOrder: [AppWorkspace] {
        AppPreferences.workspaceOrder(from: storedWorkspaceOrder)
    }

    private var resolvedProjectRoot: URL {
        AppPreferences.projectRootURL()
    }

    private var projectStorageSection: some View {
        EditorSection("项目存储位置") {
            Text(resolvedProjectRoot.path)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Text("这里保存项目资料和预览缓存，照片保留在原始位置。更改后重启应用生效。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = resolvedProjectRoot
                    panel.prompt = "选择"
                    panel.message = "选择项目存储位置（将在此目录下创建「\(AppPreferences.defaultProjectRootName)」子目录）"
                    if panel.runModal() == .OK, let url = panel.url {
                        let root = url.appendingPathComponent(AppPreferences.defaultProjectRootName, isDirectory: true)
                        projectRootPath = root.path
                        pendingProjectRoot = true
                    }
                } label: {
                    Label("更改位置…", systemImage: "folder")
                }
                if pendingProjectRoot {
                    Text("重启后生效").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
        }
    }

    private var workspaceOrderSettings: some View {
        EditorSection("顶部功能排序") {
            Text("拖动条目，或用上下箭头调整顺序，修改后立即生效。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(workspaceOrder) { workspace in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Label(workspace.title, systemImage: workspace.systemImage)
                        Spacer()
                        Button { moveWorkspace(workspace, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(workspace == workspaceOrder.first)
                        .help("上移")
                        .accessibilityLabel("将\(workspace.title)上移")
                        Button { moveWorkspace(workspace, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(workspace == workspaceOrder.last)
                        .help("下移")
                        .accessibilityLabel("将\(workspace.title)下移")
                    }
                    .buttonStyle(.borderless)
                }
                .onMove(perform: moveWorkspaces)
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 38)
            .frame(height: CGFloat(workspaceOrder.count) * 38 + 16)
            .scrollDisabled(true)
            .accessibilityLabel("顶部功能顺序")
            Button { storedWorkspaceOrder = "" } label: {
                Label("恢复默认顺序", systemImage: "arrow.counterclockwise")
            }
            .disabled(workspaceOrder == AppWorkspace.allCases)
        }
    }

    private func moveWorkspaces(from offsets: IndexSet, to destination: Int) {
        var order = workspaceOrder
        order.move(fromOffsets: offsets, toOffset: destination)
        storedWorkspaceOrder = AppPreferences.encodeWorkspaceOrder(order)
    }

    private func moveWorkspace(_ workspace: AppWorkspace, by offset: Int) {
        var order = workspaceOrder
        guard let index = order.firstIndex(of: workspace), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        storedWorkspaceOrder = AppPreferences.encodeWorkspaceOrder(order)
    }
}
