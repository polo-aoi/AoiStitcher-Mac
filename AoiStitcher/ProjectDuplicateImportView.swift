import SwiftUI

/// A single decision surface for imports that would otherwise silently add a duplicate.
struct ProjectDuplicateImportView: View {
    @ObservedObject var library: ProjectLibraryStore
    let prompt: ProjectDuplicateImportPrompt
    @Environment(\.dismiss) private var dismiss
    @State private var applyToAll = false

    private var currentPrompt: ProjectDuplicateImportPrompt {
        library.duplicateImportRequest ?? prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("发现重复素材")
                .font(.title2.weight(.semibold))
            Text("以下文件与当前项目中的素材重名，或来源路径和大小相同。替换项目素材会改用本次导入的照片，原文件保持不变。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(currentPrompt.duplicates) { duplicate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(duplicate.incomingName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(duplicate.incomingPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("已有：\(duplicate.existingName) · \(duplicate.reasons.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 100, maxHeight: 230)

            if currentPrompt.duplicates.count > 1 {
                Toggle("应用到全部重复文件", isOn: $applyToAll)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Button("取消导入") {
                    library.cancelDuplicateImport()
                    dismiss()
                }
                Spacer()
                Button(ProjectDuplicateResolution.skip.title) {
                    resolve(.skip)
                }
                Button(ProjectDuplicateResolution.overwrite.title) {
                    resolve(.overwrite)
                }
                .buttonStyle(.borderedProminent)
                Button(ProjectDuplicateResolution.keepBoth.title) {
                    resolve(.keepBoth)
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: currentPrompt.duplicates.count > 1 ? 440 : 380)
    }

    private func resolve(_ resolution: ProjectDuplicateResolution) {
        let completesBatch = applyToAll || prompt.duplicates.count == 1
        library.resolveDuplicateImport(resolution, applyToAll: completesBatch)
        if completesBatch { dismiss() }
    }
}
