import SwiftUI
import AppKit

enum EditorStyle {
    static let sidebarWidth: CGFloat = 304
    static let padding: CGFloat = 16
}

struct EditorSidebarHeader<Actions: View>: View {
    @Binding var theme: Int
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("AoiStitcher").font(.title2.weight(.semibold))
                Spacer()
                Picker("外观", selection: $theme) {
                    Image(systemName: "sun.max").tag(1)
                    Image(systemName: "moon").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 66)
                .help("切换深浅色外观")
                SettingsLink { Image(systemName: "gearshape").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("软件设置").accessibilityLabel("软件设置")
            }
            HStack(spacing: 8, content: actions)
        }.padding(EditorStyle.padding)
    }
}

struct EditorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EditorToolbar<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 12, content: content)
            .buttonStyle(.borderless)
            .frame(height: 42)
            .padding(.horizontal, EditorStyle.padding)
            .background(Color(NSColor.windowBackgroundColor))
    }
}

struct EditorExportButton: View {
    var isExporting: Bool
    var disabled: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isExporting { ProgressView().controlSize(.small) }
                Label(isExporting ? "正在导出…" : "导出图片", systemImage: "square.and.arrow.up")
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(disabled || isExporting)
    }
}

struct EditorActionBar: View {
    var isExporting: Bool
    var disabled: Bool
    var exportDisabled = false
    var clear: () -> Void
    var export: () -> Void
    var settings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(role: .destructive, action: clear) {
                Label("清空画布", systemImage: "trash").fixedSize()
            }.buttonStyle(.bordered).frame(maxWidth: .infinity).disabled(disabled || isExporting)
            EditorExportButton(isExporting: isExporting, disabled: disabled || exportDisabled, action: export)
                .frame(maxWidth: .infinity)
            Button(action: settings) { Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26) }
                .buttonStyle(.borderless).help("导出设置").accessibilityLabel("导出设置")
                .disabled(isExporting)
        }.controlSize(.large).frame(height: 44).padding(12)
    }
}

struct EditorEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("暂无照片").font(.title3.weight(.semibold))
        }.allowsHitTesting(false)
    }
}
