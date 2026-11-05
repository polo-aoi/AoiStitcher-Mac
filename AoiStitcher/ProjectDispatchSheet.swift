import SwiftUI

/// Keeps grouping and editor import choices together until the user confirms.
struct ProjectDispatchSheet: View {
    let operation: ProjectOperation
    @State var assets: [ProjectAsset]
    let offersGrouping: Bool
    let onSend: ([ProjectAsset], ProjectImportMode, Bool, Bool) -> Void
    @EnvironmentObject private var bridge: ProjectEditorBridge
    @Environment(\.dismiss) private var dismiss
    @State private var shouldCreateGroup = true
    @State private var suppressGroupingPrompt = false

    private var status: ProjectEditorStatus { bridge.status(for: operation) }
    private var isTooMany: Bool { operation.maximumPhotoCount.map { assets.count > $0 } ?? false }
    private var appendExceedsLimit: Bool {
        operation.maximumPhotoCount.map { status.count + assets.count > $0 } ?? false
    }
    private var isBlocked: Bool { status.isBusy || bridge.request != nil || isTooMany || assets.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("将 \(assets.count) 张照片添加到\(operation.title)")
                    .font(.title2.weight(.semibold))
                Text("选择照片整理方式与导入操作。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if offersGrouping { groupingOptions }

            if status.count > 0 {
                editorStatus
                orderControls
            }

            if status.isBusy || bridge.request != nil {
                Text("目标工具正在处理，请完成后再导入。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if isTooMany || appendExceedsLimit {
                Text(isTooMany ? "标准拼图最多容纳 16 张照片，请减少选择。" : "继续添加后将超过 16 张，可选择清空后导入或取消。")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if status.count > 0 {
                    Button("清空后导入", role: .destructive) { send(.replace) }
                        .disabled(isBlocked)
                }
                Button(primaryActionTitle) { send(.append) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBlocked || appendExceedsLimit)
            }
        }
        .padding(24)
        .frame(width: 550)
    }

    private var groupingOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("同时创建照片组", isOn: $shouldCreateGroup)
                .toggleStyle(.checkbox)
            Text("这些照片会归为一组，原始照片仍留在原位置。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("以后不再询问是否分组", isOn: $suppressGroupingPrompt)
                .toggleStyle(.checkbox)
                .font(.callout)
            Text("可在「设置 > 通用 > 使用引导」中重新开启。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var editorStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(status.hasUnexportedChanges ? "当前已有 \(status.count) 项素材，存在尚未导出的内容。" : "当前已有 \(status.count) 项素材，现有内容已导出。",
                  systemImage: status.hasUnexportedChanges ? "exclamationmark.circle" : "checkmark.circle")
                .font(.callout)
                .foregroundStyle(status.hasUnexportedChanges ? Color.orange : Color.secondary)
            Text("继续添加会保留当前编辑结果；清空后导入将从这批照片重新开始。项目素材、照片组和处理状态会保留。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var orderControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本次添加顺序").font(.headline)
            Text("拖动条目或用箭头调整；素材库中的排列位置不会改变。")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                        Text(asset.name).lineLimit(1)
                        Spacer()
                        Button { assets.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).help("提前一位")
                        Button { assets.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == assets.count - 1).help("推后一位")
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 4)
                }
                .onMove { from, to in assets.move(fromOffsets: from, toOffset: to) }
            }
            .frame(height: 220)
        }
    }

    private var primaryActionTitle: String {
        if status.count > 0 { return "继续添加" }
        return offersGrouping ? "开始拼图" : "导入照片"
    }

    private func send(_ mode: ProjectImportMode) {
        onSend(assets, mode, offersGrouping && shouldCreateGroup, offersGrouping && suppressGroupingPrompt)
    }
}
