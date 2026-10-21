import SwiftUI
import AppKit

struct CompressionView: View {
    @ObservedObject var workspace: CompressionWorkspace
    var isActive: Bool
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme
    @State private var showingSettings = false
    @State private var dropTarget = false
    @State private var pixelText = "1920"
    @FocusState private var pixelsFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: EditorStyle.sidebarWidth)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                ZStack {
                    Color(NSColor.controlBackgroundColor)
                    if workspace.photos.isEmpty {
                        VStack(spacing: 12) {
                            EditorEmptyState()
                            Text("拖入图片，或点击“添加照片”批量导入")
                                .font(.callout).foregroundStyle(.secondary)
                        }.allowsHitTesting(false)
                    } else { fileTable }
                }
                .overlay {
                    if dropTarget {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).padding(4)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard isActive else { return false }
                    return workspace.importURLs(urls)
                } isTargeted: { dropTarget = $0 }
                if workspace.isExporting || workspace.statusMessage != nil {
                    Divider()
                    resultBar
                }
            }
        }
        .preferredColorScheme(theme == 2 ? .dark : .light)
        .onAppear { pixelText = String(workspace.settings.pixels) }
        .onChange(of: workspace.settings.pixels) { _, pixels in pixelText = String(pixels) }
        .onChange(of: pixelsFocused) { _, focused in if !focused { commitPixels() } }
        .alert("文件处理失败", isPresented: Binding(get: { workspace.errorMessage != nil },
                                                   set: { if !$0 { workspace.errorMessage = nil } })) {
            Button("确定") { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            EditorSidebarHeader(theme: $theme) {
                Button { workspace.importPanel() } label: {
                    Label(workspace.isImporting ? "正在添加…" : "添加照片", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(workspace.isBusy || !isActive)
                    .keyboardShortcut("o", modifiers: .command)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EditorSection("导出用途") {
                        Picker("导出用途", selection: Binding(get: { workspace.settings.preset }, set: {
                            commitPixels(); workspace.applyPreset($0)
                        })) {
                            Text("朋友圈").tag("moments")
                            Text("小红书").tag("redbook")
                            Text("抖音").tag("douyin")
                            Text("自定义").tag("custom")
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    Divider()
                    sizeControls
                    Divider()
                    EditorSection("输出锐化") {
                        Picker("输出锐化", selection: $workspace.settings.sharpening) {
                            ForEach(OutputSharpeningLevel.allCases, id: \.rawValue) { level in
                                Text(level.title).tag(level.rawValue)
                            }
                        }.pickerStyle(.segmented).labelsHidden()
                        Text(workspace.settings.level.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    formatControls
                    Divider()
                    EditorSection("输出位置") {
                        Button { workspace.chooseOutputFolder() } label: {
                            Label(workspace.outputFolder?.lastPathComponent ?? "选择文件夹…", systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        }.help(workspace.outputFolder?.path ?? "选择批量导出的文件夹")
                        Text(workspace.outputFolder?.path ?? "也可以在导出时选择")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                }.padding(EditorStyle.padding)
            }.disabled(workspace.isExporting)
            Divider()
            EditorActionBar(isExporting: workspace.isExporting,
                            disabled: workspace.photos.isEmpty || workspace.isImporting,
                            clearTitle: "清空列表", clear: workspace.clearPhotos,
                            export: { commitPixels(); pixelsFocused = false; workspace.exportAll() },
                            settings: { showingSettings = true })
                .popover(isPresented: $showingSettings) {
                    CompressionOptionsView(workspace: workspace)
                }
        }
    }

    private var sizeControls: some View {
        EditorSection("图片尺寸") {
            if workspace.settings.isPlatformPreset {
                HStack {
                    Text(workspace.settings.recipeLabel).monospacedDigit()
                    Spacer()
                    Text("自动设置").foregroundStyle(.secondary)
                }
                Text("保持比例，小图不放大").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("缩放依据", selection: $workspace.settings.dimension) {
                    ForEach(FitDimension.allCases, id: \.self) { dimension in
                        Text(dimension.title).tag(dimension)
                    }
                }
                if workspace.settings.dimension != .original {
                    HStack {
                        Text("目标尺寸")
                        Spacer()
                        TextField("1920", text: $pixelText)
                            .textFieldStyle(.roundedBorder).frame(width: 74).focused($pixelsFocused)
                            .onSubmit { commitPixels(); pixelsFocused = false }
                            .accessibilityLabel("目标尺寸，像素")
                        Text("px").foregroundStyle(.secondary)
                    }
                    Text("320–4320 px，保持图片比例").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var formatControls: some View {
        EditorSection("图片格式") {
            if workspace.settings.isPlatformPreset {
                HStack {
                    Text("JPG")
                    Spacer()
                    Text("按用途自动决定质量").foregroundStyle(.secondary)
                }
            } else {
                Picker("图片格式", selection: $workspace.settings.format) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in Text(format.title).tag(format) }
                }.pickerStyle(.segmented).labelsHidden()
                if workspace.settings.format == .png {
                    Text("PNG 无损，保留透明区域").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("图片质量")
                        Spacer()
                        Text("\(Int(workspace.settings.quality))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $workspace.settings.quality, in: 50...100, step: 1)
                        .accessibilityLabel("图片质量")
                }
            }
        }
    }

    private var toolbar: some View {
        EditorToolbar {
            Text("\(workspace.photos.count) 张照片").font(.callout).foregroundStyle(.secondary)
            if workspace.isImporting { ProgressView().controlSize(.small) }
            Spacer()
            if workspace.isExporting {
                Button(action: workspace.cancelExport) {
                    Label(workspace.isCancelling ? "正在停止…" : "停止导出", systemImage: "stop.circle")
                }.disabled(workspace.isCancelling)
            } else {
                if workspace.failedCount > 0 {
                    Button { workspace.exportAll(retryFailed: true) } label: {
                        Label("重试失败 \(workspace.failedCount) 项", systemImage: "arrow.clockwise")
                    }.disabled(!workspace.canExport)
                }
                Button { workspace.remove(workspace.selectedIDs) } label: {
                    Label("移除所选", systemImage: "minus.circle")
                }.disabled(workspace.selectedIDs.isEmpty || workspace.isBusy)
            }
        }
    }

    private var fileTable: some View {
        Table(workspace.photos, selection: $workspace.selectedIDs) {
            TableColumn("文件名") { photo in
                Text(photo.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .frame(height: 24).help(photo.url.path)
            }.width(min: 180, ideal: 420)
            TableColumn("状态") { photo in
                Group {
                    switch photo.status {
                    case .waiting: Text("待处理").foregroundStyle(.secondary)
                    case .processing: Label("处理中", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                    case .done: Label("已导出", systemImage: "checkmark.circle").foregroundStyle(.green)
                    case .failed:
                        Button { workspace.showFailure(photo) } label: {
                            Label("失败 · 详情", systemImage: "exclamationmark.circle")
                        }.buttonStyle(.borderless).foregroundStyle(.red)
                    }
                }.help(photo.failure ?? "\(photo.width) × \(photo.height) px · 原文件 \(readableBytes(photo.fileBytes))")
            }.width(110)
            TableColumn("输出大小") { photo in
                Text(photo.outputBytes.map { readableBytes(Int64($0)) } ?? "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }.width(90)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("移除所选") { workspace.remove(ids) }.disabled(ids.isEmpty || workspace.isBusy)
            if ids.count == 1, let photo = workspace.photos.first(where: { ids.contains($0.id) }), photo.failure != nil {
                Button("查看失败详情") { workspace.showFailure(photo) }
            }
        }
        .onDeleteCommand { if isActive { workspace.remove(workspace.selectedIDs) } }
    }

    private var resultBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if workspace.isExporting {
                HStack {
                    Text(workspace.processingName ?? "准备处理…").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(workspace.exportCompleted) / \(workspace.exportTotal)").monospacedDigit()
                }
                ProgressView(value: Double(workspace.exportCompleted), total: Double(max(1, workspace.exportTotal)))
            } else {
                HStack {
                    Text(workspace.statusMessage ?? "").textSelection(.enabled)
                    Spacer()
                    if workspace.lastExportedURL != nil {
                        Button("在访达中查看", action: workspace.revealExport)
                    }
                }
            }
        }.font(.callout).padding(12).background(Color(NSColor.windowBackgroundColor))
    }

    private func commitPixels() {
        guard !workspace.settings.isPlatformPreset else {
            pixelText = String(workspace.settings.pixels); return
        }
        if let value = Int(pixelText) { workspace.setPixels(value) }
        pixelText = String(workspace.settings.pixels)
    }
}

private struct CompressionOptionsView: View {
    @ObservedObject var workspace: CompressionWorkspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("导出设置").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            VStack(alignment: .leading, spacing: 12) {
                if !workspace.settings.isPlatformPreset {
                    Toggle("允许放大小图", isOn: $workspace.settings.allowUpscale)
                }
                Toggle("保留拍摄信息", isOn: $workspace.settings.keepMetadata)
                Toggle("移除位置信息", isOn: $workspace.settings.removeLocation)
                    .disabled(!workspace.settings.keepMetadata)
                Toggle("导出后在访达显示", isOn: $workspace.settings.revealAfterExport)
            }.toggleStyle(.checkbox)
            Text("输出 sRGB 静态图片；多帧图片只处理第一帧。PNG 无损输出不一定比原文件小。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Button(action: workspace.restoreDefaults) {
                Label("恢复压缩默认设置", systemImage: "arrow.counterclockwise")
            }
        }.padding(20).frame(width: 360).disabled(workspace.isExporting)
            .background(Color(NSColor.windowBackgroundColor))
            .preferredColorScheme(theme == 2 ? .dark : .light)
    }
}
