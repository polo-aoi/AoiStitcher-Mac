import SwiftUI
import AppKit

struct ProjectPhotoGroupRow: View {
    @ObservedObject var library: ProjectLibraryStore
    let group: ProjectPhotoGroup
    let members: [ProjectAsset]
    let thumbnailSize: CGFloat
    @Binding var selection: Set<UUID>
    let isSelected: Bool
    let isActive: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let badges: [UUID: String]
    let onChoose: () -> Void
    let onClearSelection: () -> Void
    let onFocus: () -> Void
    let onSend: (ProjectOperation, Set<UUID>) -> Void
    let showDropLineBefore: Bool
    let showDropLineAfter: Bool
    let onGroupDragBegan: () -> Void
    let onGroupDragEnded: () -> Void
    let onGroupDragHover: (UUID, Bool) -> Bool
    let onGroupDragExit: () -> Void
    let onDropGroup: (UUID, Bool) -> Bool
    let onAssetDropTargetChange: (Bool) -> Void
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

    var body: some View {
        ProjectThumbnailRefresh(library: library, assets: members,
                                isActive: isActive) { thumbnails, reportVisible in
                ProjectMaterialBoard(
                    assets: rowAssets, selection: $selection, thumbnailSize: layout.thumbnailSize,
                    viewZoom: .constant(1), fitRequest: 0,
                    thumbnails: thumbnails,
                    assetURLs: Dictionary(uniqueKeysWithValues: members.map { ($0.id, library.assetURL($0)) }),
                    isActive: isActive, badges: badges,
                    onMove: reorderMembers,
                    onImport: { _, _ in }, onActivate: { _ in },
                    onThumbnailDemand: reportVisible,
                    onSend: onSend,
                    onRemove: library.returnAssetsToMaterials,
                    onImportPanel: library.importPanel,
                    onUndo: library.undoLastEdit,
                    isGroupRow: true, onFocus: onFocus,
                    onDropAssets: { library.addAssets($0, to: group.id) },
                    onGroupChoose: { onChoose(); focusRequest += 1 },
                    onGroupClearSelection: onClearSelection,
                    isGroupSelected: isSelected,
                    groupDragID: group.id,
                    onGroupDragBegan: onGroupDragBegan,
                    onGroupDragEnded: onGroupDragEnded,
                    onGroupDragHover: onGroupDragHover,
                    onGroupDragExit: onGroupDragExit,
                    onDropGroup: onDropGroup,
                    onAssetDropTargetChange: onAssetDropTargetChange,
                    focusRequest: focusRequest
                )
        }.frame(height: layout.cardSize.height + 8)
        .contextMenu {
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
            Button("上移一组") { library.moveGroup(group.id, by: -1) }
                .disabled(!canMoveUp)
            Button("下移一组") { library.moveGroup(group.id, by: 1) }
                .disabled(!canMoveDown)
            Divider()
            Button("解散分组，全部移回素材") { library.dissolveGroup(group.id) }
        }
        .background {
            (isSelected ? Color.accentColor.opacity(0.04) : Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            ZStack {
                Rectangle().strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                if showDropLineBefore {
                    Rectangle().fill(Color.accentColor).frame(height: 3).frame(maxHeight: .infinity, alignment: .top)
                }
                if showDropLineAfter {
                    Rectangle().fill(Color.accentColor).frame(height: 3).frame(maxHeight: .infinity, alignment: .bottom)
                }
            }.allowsHitTesting(false)
        }
        .contentShape(Rectangle())
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
