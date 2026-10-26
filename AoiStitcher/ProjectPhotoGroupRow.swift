import SwiftUI
import AppKit

struct ProjectPhotoGroupRow: View {
    @ObservedObject var library: ProjectLibraryStore
    let group: ProjectPhotoGroup
    let number: Int
    let members: [ProjectAsset]
    let thumbnailSize: CGFloat
    @Binding var selection: Set<UUID>
    let isSelected: Bool
    let isActive: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let badges: [UUID: String]
    let onChoose: () -> Void
    let onFocus: () -> Void
    let onSend: (ProjectOperation, Set<UUID>) -> Void
    @State private var visibleIDs: Set<UUID> = []
    @State private var focusRequest = 0

    private var layout: ProjectMaterialLayout { ProjectMaterialLayout(thumbnailSize: thumbnailSize) }
    private var columnStride: CGFloat { layout.cardSize.width + 4 }

    private var rowAssets: [ProjectAsset] {
        members.enumerated().map { index, asset in
            var display = asset
            display.position = CGPoint(x: CGFloat(index) * columnStride, y: 0)
            return display
        }
    }

    private var thumbnails: [UUID: NSImage] {
        var images: [UUID: NSImage] = [:]
        for asset in members where visibleIDs.contains(asset.id) {
            images[asset.id] = library.thumbnail(for: asset, maximumPixelSize: Int(ceil(layout.thumbnailSize * 2)))
        }
        return images
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onChoose()
                focusRequest += 1
            } label: {
                VStack(spacing: 3) {
                    Text("组 \(number)").fontWeight(.medium)
                    Text("\(members.count) 张").foregroundStyle(.secondary)
                }
                .font(.caption).lineLimit(1)
                .frame(width: 46, height: layout.cardSize.height + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("第 \(number) 组，\(members.count) 张照片")
            .help("选择整组；按 1、2、3 添加至对应拼图")
            ProjectThumbnailRefresh(updates: library.thumbnailUpdates) {
                ProjectMaterialBoard(
                    assets: rowAssets, selection: $selection, thumbnailSize: layout.thumbnailSize,
                    viewZoom: .constant(1), fitRequest: 0,
                    thumbnails: thumbnails,
                    assetURLs: Dictionary(uniqueKeysWithValues: members.map { ($0.id, library.assetURL($0)) }),
                    isActive: isActive, badges: badges,
                    onMove: reorderMembers,
                    onImport: { _, _ in }, onActivate: { _ in },
                    onVisibleAssets: { visibleIDs = $0 },
                    onSend: onSend,
                    onRemove: library.returnAssetsToMaterials,
                    onImportPanel: library.importPanel,
                    onUndo: library.undoLastEdit,
                    isGroupRow: true, onFocus: onFocus,
                    onDropAssets: { library.addAssets($0, to: group.id) },
                    focusRequest: focusRequest
                )
            }.frame(height: layout.cardSize.height + 8)
            Menu {
                Button("选中整组") { onChoose(); focusRequest += 1 }
                Button("将选中照片移回素材") { library.returnAssetsToMaterials(selection) }
                    .disabled(selection.isEmpty)
                if selection.count == 1, let id = selection.first {
                    Button("照片向前一位") { library.moveGroupAsset(id, in: group.id, by: -1) }
                        .disabled(group.assetIDs.first == id)
                    Button("照片向后一位") { library.moveGroupAsset(id, in: group.id, by: 1) }
                        .disabled(group.assetIDs.last == id)
                }
                Divider()
                Button("上移一组") { library.moveGroup(group.id, by: -1) }.disabled(!canMoveUp)
                Button("下移一组") { library.moveGroup(group.id, by: 1) }.disabled(!canMoveDown)
                Divider()
                Button("解散分组，全部移回素材") { library.dissolveGroup(group.id) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 22).padding(.trailing, 4)
                .help("照片组操作")
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
        .disabled(!isActive)
        .onAppear { if isSelected { focusRequest += 1 } }
    }

    private func reorderMembers(_ positions: [UUID: CGPoint]) {
        let moving = members.filter { positions[$0.id] != nil }
        guard !moving.isEmpty, let first = moving.first, let drop = positions[first.id] else { return }
        let remaining = rowAssets.filter { positions[$0.id] == nil }
        let insertion = remaining.firstIndex { $0.position.x >= drop.x } ?? remaining.count
        var ids = remaining.map(\.id)
        ids.insert(contentsOf: moving.map(\.id), at: insertion)
        library.setGroupAssetOrder(ids, in: group.id)
    }
}
