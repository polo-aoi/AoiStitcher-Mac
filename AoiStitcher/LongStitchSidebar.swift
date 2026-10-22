import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LongStitchSidebar: View {
    @ObservedObject var preferences: LongStitchPreferences
    var includePreferences = false
    var onWillChange: (() -> Void)? = nil
    @Binding var selectedWatermarkEdge: LongStitchEdge?
    var canvasLayout: LongStitchLayout? = nil
    var onLocateWatermark: ((LongStitchEdge) -> Void)? = nil
    var watermarkEditorRequestID: UUID? = nil
    @State private var path: [Route] = []

    init(preferences: LongStitchPreferences, includePreferences: Bool = false,
         onWillChange: (() -> Void)? = nil,
         selectedWatermarkEdge: Binding<LongStitchEdge?> = .constant(nil),
         canvasLayout: LongStitchLayout? = nil,
         onLocateWatermark: ((LongStitchEdge) -> Void)? = nil,
         watermarkEditorRequestID: UUID? = nil) {
        self.preferences = preferences
        self.includePreferences = includePreferences
        self.onWillChange = onWillChange
        self._selectedWatermarkEdge = selectedWatermarkEdge
        self.canvasLayout = canvasLayout
        self.onLocateWatermark = onLocateWatermark
        self.watermarkEditorRequestID = watermarkEditorRequestID
    }

    private enum Route: Hashable {
        case edgeEditor(LongStitchEdge)
        case library(LongStitchEdge?)
        case createWatermark(LongStitchEdge?)
        case metadata(UUID)
        case preferences
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LongStitchLayoutControls(preferences: preferences, onWillChange: onWillChange) {
                        showEdgeEditor($0)
                    } openLibrary: { navigate(.library(nil)) }
                    if includePreferences {
                        Divider()
                        Button {
                            navigate(.preferences)
                        } label: {
                            Label("快捷键与导出", systemImage: "slider.horizontal.3")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                    if let error = preferences.libraryError {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Label("水印库提示", systemImage: "exclamationmark.triangle")
                                .font(.callout.weight(.semibold))
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("重试") { preferences.retryLibraryMigration() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { LongStitchStableScrollViewConfigurator() }
            }
            .opacity(path.isEmpty ? 1 : 0)
            .allowsHitTesting(path.isEmpty)
            .disabled(!path.isEmpty)
            .accessibilityHidden(!path.isEmpty)
            if let route = path.last {
                switch route {
                case .edgeEditor(let edge):
                    LongStitchEdgeEditor(preferences: preferences, edge: edge,
                                         canvasLayout: canvasLayout,
                                         onWillChange: onWillChange,
                                         onBack: goBack,
                                         onSelectEdge: showEdgeEditor,
                                         onLocateWatermark: onLocateWatermark,
                                         openLibrary: { target in
                                             endEditing()
                                             path = [.edgeEditor(target), .library(target)]
                                         })
                case .library(let target):
                    LongStitchWatermarkLibraryPage(
                        preferences: preferences,
                        target: target,
                        onBack: goBack,
                        onAdd: { navigate(.createWatermark(target)) },
                        onEdit: { navigate(.metadata($0)) },
                        onSelected: { itemID in
                            guard let target else { return }
                            onWillChange?()
                            preferences.selectWatermark(itemID, for: target)
                            goBack()
                        }
                    )
                case .createWatermark(let target):
                    LongStitchWatermarkForm(
                        preferences: preferences,
                        onCancel: goBack,
                        onComplete: { item in
                            if let target {
                                onWillChange?()
                                preferences.selectWatermark(item.id, for: target)
                                path = [.edgeEditor(target)]
                            } else { goBack() }
                        }
                    )
                case .metadata(let itemID):
                    LongStitchWatermarkMetadataPage(preferences: preferences, itemID: itemID,
                                                    onBack: goBack, onWillChange: onWillChange)
                case .preferences:
                    LongStitchShortcutAndExportPage(preferences: preferences, onBack: goBack,
                                                   onWillChange: onWillChange)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .transaction { $0.animation = nil }
        .onChange(of: selectedWatermarkEdge) { _, edge in
            if let edge { showEdgeEditor(edge) }
        }
        .onChange(of: watermarkEditorRequestID) { _, _ in
            if let edge = selectedWatermarkEdge { showEdgeEditor(edge) }
        }
    }

    private func endEditing() { NSApp.keyWindow?.makeFirstResponder(nil) }
    private func navigate(_ route: Route) { endEditing(); path.append(route) }
    private func goBack() { endEditing(); if !path.isEmpty { path.removeLast() } }
    private func showEdgeEditor(_ edge: LongStitchEdge) {
        endEditing()
        selectedWatermarkEdge = edge
        path = [.edgeEditor(edge)]
    }
}

struct LongStitchLayoutControls: View {
    @ObservedObject var preferences: LongStitchPreferences
    var onWillChange: (() -> Void)? = nil
    var editEdge: (LongStitchEdge) -> Void
    var openLibrary: () -> Void

    private func update(_ mutation: (inout LongStitchSettings) -> Void) {
        onWillChange?()
        var next = preferences.settings
        mutation(&next)
        preferences.settings = next
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("排版").font(.callout.weight(.semibold))
                Spacer()
                Button("恢复默认") {
                    LongStitchNumericEditing.discardDrafts()
                    onWillChange?()
                    preferences.restoreDefaults()
                }
                .buttonStyle(.borderless)
                .help("恢复长图拼接出厂设置；保留水印素材库和当前照片。")
            }
            Picker("排列方向", selection: Binding(
                get: { preferences.settings.direction },
                set: { value in update { $0.direction = value } }
            )) {
                ForEach(LongStitchDirection.allCases) { direction in Text(direction.title).tag(direction) }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel("长图排列方向")

            VStack(spacing: 6) {
                HStack {
                    Text("图片间距")
                    Spacer()
                    LongStitchNumberField(title: "图片间距", value: Binding(
                        get: { preferences.settings.spacing },
                        set: { value in update { $0.spacing = value } }
                    ), range: 0...16_384, decimals: 0)
                    Text("px").foregroundStyle(.secondary)
                }
                LongStitchIntegerSlider(value: Binding(
                    get: { preferences.settings.spacing },
                    set: { value in update { $0.spacing = value } }
                ), range: 0...300, label: "图片间距")
            }
            Divider()
            Text("四边留白").font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(LongStitchEdge.allCases) { edge in
                    LongStitchMarginSummary(preferences: preferences, edge: edge,
                                            onWillChange: onWillChange,
                                            edit: { editEdge(edge) })
                }
            }
            Button(action: openLibrary) {
                Label("水印素材库", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LongStitchMarginSummary: View {
    @ObservedObject var preferences: LongStitchPreferences
    let edge: LongStitchEdge
    var onWillChange: (() -> Void)?
    var edit: () -> Void

    private var margin: LongStitchMargin { preferences.settings[edge].sanitized() }
    private var watermarkName: String? { preferences.library.item(id: margin.watermarkID)?.name }

    private func binding<Value>(_ keyPath: WritableKeyPath<LongStitchMargin, Value>) -> Binding<Value> {
        Binding {
            preferences.settings[edge][keyPath: keyPath]
        } set: { value in
            onWillChange?()
            var next = preferences.settings
            var margin = next[edge]
            margin[keyPath: keyPath] = value
            next[edge] = margin.sanitized()
            preferences.settings = next
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(edge.title)留白").frame(width: 56, alignment: .leading)
                Toggle("\(edge.title)留白", isOn: binding(\.isEnabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
                Spacer(minLength: 4)
                LongStitchNumberField(title: "\(edge.title)留白大小", value: binding(\.size),
                                      range: 0...16_384, decimals: 0)
                    .disabled(!margin.isEnabled)
                Text("px").foregroundStyle(.secondary).disabled(!margin.isEnabled)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            HStack(spacing: 6) {
                Text("水印：")
                    .foregroundStyle(.secondary)
                Text(watermarkName ?? "未选择")
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(watermarkName == nil ? Color.secondary : Color.primary)
                Button("调整", action: edit)
                    .buttonStyle(.borderless)
                    .disabled(!margin.isEnabled)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .opacity(margin.isEnabled ? 1 : 0.48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LongStitchIntegerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    var body: some View {
        Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                              set: { value = $0.rounded() }), in: range) { editing in
            if editing { LongStitchNumericEditing.discardDrafts() }
        }
            .accessibilityLabel(label)
    }
}

struct LongStitchExportSettingsView: View {
    @ObservedObject var preferences: LongStitchPreferences
    var outputSize: String = ""
    var onWillChange: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("长图导出设置").font(.headline)
                Spacer()
                Button("完成") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
            LongStitchExportSettingsFields(preferences: preferences, onWillChange: onWillChange)
            if !outputSize.isEmpty {
                Text(outputSize).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Divider()
            Button {
                LongStitchNumericEditing.discardDrafts()
                onWillChange?()
                var next = preferences.settings
                let defaults = LongStitchSettings()
                next.exportShortEdge = defaults.exportShortEdge
                next.exportPNG = defaults.exportPNG
                preferences.settings = next
            } label: {
                Label("恢复导出默认设置", systemImage: "arrow.counterclockwise")
            }
        }
        .padding(20).frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct LongStitchExportSettingsFields: View {
    @ObservedObject var preferences: LongStitchPreferences
    var onWillChange: (() -> Void)? = nil
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("短边像素")
                Spacer()
                TextField("2560", text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .accessibilityLabel("长图短边像素，不包含留白")
                Text("px").foregroundStyle(.secondary)
            }
            Text("不包含四边留白，留白会额外增加导出尺寸。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("图片格式")
                Spacer()
                Picker("长图图片格式", selection: Binding(
                    get: { preferences.settings.exportPNG },
                    set: { value in
                        onWillChange?()
                        var next = preferences.settings; next.exportPNG = value; preferences.settings = next
                    }
                )) {
                    Text("PNG").tag(true)
                    Text("JPEG").tag(false)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 170)
            }
            if AppPreferences.exportWidth(draft) == nil {
                Text("短边像素需为 1 到 16384 的整数。")
                    .font(.callout).foregroundStyle(.red)
            }
        }
        .onAppear { draft = preferences.settings.exportShortEdge }
        .onChange(of: preferences.settings.exportShortEdge) { _, value in
            draft = value
        }
        .onReceive(NotificationCenter.default.publisher(for: LongStitchNumericEditing.discardNotification)) { _ in
            draft = preferences.settings.exportShortEdge
        }
        .onChange(of: isFocused) { _, focused in if !focused { commit() } }
        .onDisappear { commit() }
    }

    private func commit() {
        guard AppPreferences.exportWidth(draft) != nil else { return }
        guard preferences.settings.exportShortEdge != draft else { return }
        onWillChange?()
        var next = preferences.settings; next.exportShortEdge = draft; preferences.settings = next
    }
}

struct LongStitchNumberField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var decimals = 0
    var onCommit: (() -> Void)? = nil
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(title, text: $draft)
            .textFieldStyle(.roundedBorder).frame(width: 64)
            .focused($isFocused)
            .onSubmit { commit() }
            .onAppear { draft = formatted(value) }
            .onChange(of: value) { _, newValue in draft = formatted(newValue) }
            .onReceive(NotificationCenter.default.publisher(for: LongStitchNumericEditing.discardNotification)) { _ in
                draft = formatted(value)
            }
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onDisappear { if isFocused { commit() } }
            .accessibilityLabel(title)
    }

    private func formatted(_ value: Double) -> String {
        decimals == 0 ? String(Int(value.rounded())) : String(format: "%.*f", decimals, value)
    }

    private func commit() {
        guard draft != formatted(value) else { return }
        guard let parsed = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.isFinite else {
            draft = formatted(value); return
        }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        if abs(value - clamped) > 0.000_001 {
            onCommit?()
            value = decimals == 0 ? clamped.rounded() : clamped
        }
        draft = formatted(value)
    }
}

enum LongStitchNumericEditing {
    static let discardNotification = Notification.Name("aoipic.longStitch.discardNumericDrafts")

    static func discardDrafts() {
        NotificationCenter.default.post(name: discardNotification, object: nil)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

struct LongStitchStableScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if !scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = true }
            if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
            if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        }
    }
}
