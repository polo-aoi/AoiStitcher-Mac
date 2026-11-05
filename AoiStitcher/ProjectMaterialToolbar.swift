import SwiftUI

struct ProjectMaterialToolbar<ThumbnailControls: View>: View {
    var selectedCount: Int
    var isImporting: Bool
    var onImport: () -> Void
    @ViewBuilder var thumbnailControls: () -> ThumbnailControls

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onImport) { Label("导入素材", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
            if isImporting { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            thumbnailControls()
        }
        .overlay {
            Text(selectedCount > 0
                 ? "已选择 \(selectedCount) 张照片 · 点击上方选择拼图方式"
                 : "选择照片，点击上方选择拼图方式")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("project-material-guidance")
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
