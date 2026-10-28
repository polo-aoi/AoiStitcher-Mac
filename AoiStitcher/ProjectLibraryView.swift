import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Keep pending imports alive if the main window closes, and finish metadata writes before quitting.
@MainActor final class ProjectLibraryLifecycle: NSObject, NSApplicationDelegate {
    static var library: ProjectLibraryStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library = Self.library else { return .terminateNow }
        guard library.isImporting else { return library.flushPendingSaves() ? .terminateNow : .terminateCancel }
        Task { @MainActor in
            while library.isImporting { try? await Task.sleep(for: .milliseconds(50)) }
            sender.reply(toApplicationShouldTerminate: library.flushPendingSaves())
        }
        return .terminateLater
    }
}

struct ContentView: View {
    @StateObject private var library = ProjectLibraryStore()
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme
    @AppStorage(AppPreferences.workspaceOrderKey) private var storedWorkspaceOrder = ""
    @State private var mode = "library"
    @State private var homeRequest = 0
    @State private var workspaceBusy = false

    var body: some View {
        Group {
            if let project = library.currentProject {
                ProjectWorkspaceView(library: library, projectID: project.id,
                                     mode: $mode, homeRequest: homeRequest,
                                     navigationBusy: $workspaceBusy)
                    .id(project.id)
            } else {
                ProjectHomeView(library: library)
            }
        }
        .frame(minWidth: 1020, minHeight: 740)
        .preferredColorScheme(theme == 2 ? .dark : .light)
        .background {
            ProjectWindowNavigation(
                selectedWorkspace: library.currentProject == nil ? nil : mode,
                workspaces: AppPreferences.workspaceOrder(from: storedWorkspaceOrder),
                homeEnabled: !workspaceBusy && !library.isImporting,
                onHome: { if library.currentProject != nil { homeRequest += 1 } },
                onSelectWorkspace: { mode = $0 }
            ).frame(width: 0, height: 0)
        }
        .onChange(of: library.currentProject?.id) { _, _ in
            mode = "library"
            workspaceBusy = false
        }
        .onAppear { ProjectLibraryLifecycle.library = library }
        .alert("项目素材库", isPresented: Binding(
            get: { library.message != nil },
            set: { if !$0 { library.message = nil } }
        )) {
            Button("确定") { library.message = nil }
        } message: { Text(library.message ?? "") }
        .sheet(item: $library.duplicateImportRequest, onDismiss: {
            library.cancelDuplicateImport()
        }) { prompt in
            ProjectDuplicateImportView(library: library, prompt: prompt)
        }
    }
}

private struct ProjectHomeView: View {
    @ObservedObject var library: ProjectLibraryStore
    @State private var showingNewProject = false
    @State private var projectName = ""
    @State private var isDropTargeted = false
    @State private var renamingProject: ProjectSummary?
    @State private var renamingText = ""
    @State private var deletingProject: ProjectSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("你的图片项目").font(.largeTitle.bold())
                    Text("先把照片放进一个项目，再整理、拼图和记录成果。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { projectName = ""; showingNewProject = true } label: {
                    Label("新建项目", systemImage: "plus")
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
            }

            Button(action: chooseProjectFolder) {
                HStack(spacing: 18) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 34, weight: .light))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isDropTargeted ? "松开文件夹，创建项目" : "拖入文件夹，直接开始")
                            .font(.title3.weight(.semibold))
                        Text("以文件夹名称新建项目，导入其中及子文件夹里的照片。也可以直接拖入多张照片。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("选择文件夹…").font(.callout)
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(isDropTargeted ? 0.15 : 0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(isDropTargeted ? 1 : 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if library.projects.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 52, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("也可以先创建空项目").font(.title2.weight(.semibold))
                    Text("导入照片，排序分组；用过哪些、导出了什么，都留在项目里。")
                        .foregroundStyle(.secondary)
                    Button("新建第一个项目") { showingNewProject = true }
                        .buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                Text("最近项目").font(.headline)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                        ForEach(library.projects) { project in
                            ProjectCoverCard(
                                library: library,
                                project: project,
                                onOpen: { library.openProject(id: project.id) },
                                onRename: { renamingProject = project; renamingText = project.name },
                                onReveal: { library.revealProjectInFinder(id: project.id) },
                                onDelete: { deletingProject = project },
                                onRepair: { repairProject(project) }
                            )
                        }
                    }.padding(2).projectOverlayScrollbars()
                }
            }
            Text("项目会自动保存素材、照片组和处理状态。拼图编辑草稿暂不保存。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(36)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            createProjectFromDrop(urls)
        } isTargeted: { isDropTargeted = $0 }
        .sheet(isPresented: $showingNewProject) {
            VStack(alignment: .leading, spacing: 18) {
                Text("新建项目").font(.title2.weight(.semibold))
                TextField("项目名称", text: $projectName).textFieldStyle(.roundedBorder)
                    .onSubmit(createProject)
                Text("项目只记录照片的原始位置，不复制原图；移动原文件后可用「修复项目」重新连接。也可以把文件夹拖到这里，直接用文件夹名称创建。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { showingNewProject = false }.keyboardShortcut(.cancelAction)
                    Button("创建项目", action: createProject)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 410)
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in createProjectFromDrop(urls) }
        }
        .sheet(item: $renamingProject) { project in
            VStack(alignment: .leading, spacing: 18) {
                Text("重命名项目").font(.title2.weight(.semibold))
                TextField("项目名称", text: $renamingText).textFieldStyle(.roundedBorder)
                    .onSubmit(confirmRename)
                HStack {
                    Spacer()
                    Button("取消") { renamingProject = nil }.keyboardShortcut(.cancelAction)
                    Button("重命名", action: confirmRename)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(renamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 380)
        }
        .confirmationDialog("删除项目「\(deletingProject?.name ?? "")」？",
                            isPresented: Binding(get: { deletingProject != nil },
                                                 set: { if !$0 { deletingProject = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let project = deletingProject { library.deleteProject(id: project.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("项目内的照片副本和资料将一并移到废纸篓，不影响电脑上的原文件。此操作不可撤销。")
        }
    }

    private func confirmRename() {
        guard let project = renamingProject else { return }
        library.renameProject(id: project.id, to: renamingText)
        renamingProject = nil
    }

    private func repairProject(_ project: ProjectSummary) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "开始修复"
        panel.message = "选择缺失照片现在所在的位置（会按文件名在子文件夹里自动匹配）。"
        if panel.runModal() == .OK, let folder = panel.url {
            library.repairProject(id: project.id, locatingIn: folder)
        }
    }

    private func createProjectFromDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        showingNewProject = false
        return library.createProject(importing: files)
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "创建项目"
        panel.message = "以所选文件夹命名项目，并导入其中的图片。"
        if panel.runModal() == .OK { _ = createProjectFromDrop(panel.urls) }
    }

    private func createProject() {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        showingNewProject = false
        library.createProject(name: name)
    }
}

private struct ProjectCoverImage: View {
    let library: ProjectLibraryStore
    let projectID: UUID
    let asset: ProjectSummaryCoverAsset
    @State private var image: NSImage?

    var body: some View {
        // The plain Color fixes the layout at the container's size; scaledToFill
        // only paints inside the overlay, so tall photos can never stretch the
        // collage or bleed into neighboring cards.
        Color.gray.opacity(0.12)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: "\(projectID.uuidString)/\(asset.id.uuidString)") {
                if image == nil {
                    image = await library.requestCoverThumbnail(projectID: projectID, asset: asset)
                }
            }
    }
}

private struct ProjectCoverCard: View {
    let library: ProjectLibraryStore
    let project: ProjectSummary
    let onOpen: () -> Void
    let onRename: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onRepair: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                coverArea
                infoArea
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("打开") { onOpen() }
            Button("重命名…") { onRename() }
            Button("修复项目…") { onRepair() }
                .disabled(project.missingCount == 0)
            Button("在访达中显示") { onReveal() }
            Divider()
            Button("删除项目…", role: .destructive) { onDelete() }
        }
    }

    private var coverArea: some View {
        ZStack {
            if project.coverAssets.isEmpty {
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.12))
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28, weight: .light))
                        Text("还没有照片").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 2) {
                    ProjectCoverImage(library: library, projectID: project.id, asset: project.coverAssets[0])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if project.coverAssets.count >= 2 {
                        VStack(spacing: 2) {
                            ProjectCoverImage(library: library, projectID: project.id, asset: project.coverAssets[1])
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if project.coverAssets.count >= 3 {
                                ProjectCoverImage(library: library, projectID: project.id, asset: project.coverAssets[2])
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(width: 110)
                    }
                }
            }
        }
        .frame(height: 190)
        .clipped()
        // The badge lives above the clipped collage so a portrait photo can
        // never cover or displace it.
        .overlay(alignment: .bottomLeading) {
            Text("共 \(project.assetCount) 张")
                .font(.caption2)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(8)
        }
    }

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name).font(.title3.weight(.semibold)).lineLimit(1)
            HStack(spacing: 8) {
                Text(project.modifiedAt, format: .dateTime.year().month().day().hour().minute()
                    .locale(Locale(identifier: "zh_CN")))
                    .font(.caption).foregroundStyle(.secondary)
                if project.missingCount > 0 {
                    Label("\(project.missingCount) 张缺图", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
    }
}

private struct ProjectWorkspaceView: View {
    @ObservedObject var library: ProjectLibraryStore
    let projectID: UUID
    @Binding var mode: String
    let homeRequest: Int
    @Binding var navigationBusy: Bool
    @StateObject private var bridge = ProjectEditorBridge()
    @StateObject private var canvasStore = CanvasStore()
    @StateObject private var gridCollageStore = GridCollageStore()
    @State private var isMaterialDispatchPresented = false
    @State private var confirmsReturnHome = false
    @AppStorage(AppPreferences.workspaceOrderKey) private var storedWorkspaceOrder = ""

    private var isBusy: Bool {
        library.isImporting || bridge.activeExportCount > 0 || bridge.request != nil
            || bridge.statuses.values.contains(where: { $0.isBusy }) || isMaterialDispatchPresented
    }

    var body: some View {
        ZStack {
            ProjectLibraryView(library: library, projectID: projectID,
                               isActive: mode == "library" && library.currentProject?.id == projectID,
                               isDispatchPresented: $isMaterialDispatchPresented) { operation, urls, importMode in
                guard bridge.send(operation: operation, urls: urls, mode: importMode) else {
                    library.message = "目标工具正在处理，或添加后超过容量限制。请稍后重试。"
                    return false
                }
                mode = operation.rawValue
                return true
            }
            .opacity(mode == "library" ? 1 : 0)
            .allowsHitTesting(mode == "library")
            .disabled(mode != "library")
            .accessibilityHidden(mode != "library")
            ForEach(AppPreferences.workspaceOrder(from: storedWorkspaceOrder)) { workspace in
                workspaceView(workspace)
                    .opacity(mode == workspace.rawValue ? 1 : 0)
                    .allowsHitTesting(mode == workspace.rawValue)
                    .disabled(mode != workspace.rawValue)
                    .accessibilityHidden(mode != workspace.rawValue)
            }
        }
        .padding(8)
        .environmentObject(library)
        .environmentObject(bridge)
        .onAppear { navigationBusy = isBusy }
        .onChange(of: isBusy) { _, busy in navigationBusy = busy }
        .onChange(of: homeRequest) { _, _ in requestHome() }
        .alert("返回项目首页？", isPresented: $confirmsReturnHome) {
            Button("继续编辑", role: .cancel) {}
            Button("返回首页", role: .destructive, action: returnHome)
        } message: {
            Text("当前有尚未导出的拼图，返回首页后将清空编辑器。项目素材、照片组和处理状态会自动保存。")
        }
    }

    private func requestHome() {
        guard !isBusy, library.currentProject?.id == projectID else { return }
        if bridge.statuses.values.contains(where: { $0.hasUnexportedChanges }) {
            confirmsReturnHome = true
        } else {
            returnHome()
        }
    }

    private func returnHome() {
        guard !isBusy, library.currentProject?.id == projectID else { return }
        library.closeProject()
    }

    @ViewBuilder private func workspaceView(_ workspace: AppWorkspace) -> some View {
        switch workspace {
        case .freeCanvas: FreeCanvasView(store: canvasStore, isActive: mode == workspace.rawValue)
        case .longStitch: LongStitchView(isActive: mode == workspace.rawValue)
        case .gridCollage: GridCollageView(store: gridCollageStore, isActive: mode == workspace.rawValue)
        }
    }
}

nonisolated struct ProjectMaterialFilter: Equatable {
    enum Status: String, CaseIterable, Identifiable {
        case all, unused, used
        var id: Self { self }
        var title: String {
            switch self {
            case .all: return "全部"
            case .unused: return "未导出"
            case .used: return "已导出"
            }
        }
    }

    var operation: ProjectOperation?
    var status: Status = .all
    var isActive: Bool { operation != nil || status != .all }
    var summary: String { "\(operation?.title ?? "不限用途") · \(status.title)" }

    func includes(operations: Set<ProjectOperation>) -> Bool {
        let exported = operation.map { operations.contains($0) } ?? !operations.isEmpty
        switch status {
        case .all: return true
        case .unused: return !exported
        case .used: return exported
        }
    }
}

/// Rebuilt on document edits, not on selection changes or thumbnail completions.
private struct ProjectMaterialCatalog {
    var assets: [ProjectAsset] = []
    var byID: [UUID: ProjectAsset] = [:]
    var usage: [UUID: Set<ProjectOperation>] = [:]
    var badges: [UUID: String] = [:]

    init(_ document: ProjectDocument? = nil) {
        guard let document else { return }
        assets = document.orderedActiveAssets
        byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var counts: [UUID: [ProjectOperation: Int]] = [:]
        for record in document.exports {
            for id in Set(record.assetIDs) {
                usage[id, default: []].insert(record.operation)
                counts[id, default: [:]][record.operation, default: 0] += 1
            }
        }
        for asset in assets {
            let details = (counts[asset.id] ?? [:]).sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.title) \($0.value) 次" }
            badges[asset.id] = details.isEmpty ? "尚未导出" : details.joined(separator: "、")
        }
    }
}

private struct ProjectDispatch: Identifiable {
    let id = UUID()
    let operation: ProjectOperation
    let assets: [ProjectAsset]
}

private struct ProjectLibraryView: View {
    @ObservedObject var library: ProjectLibraryStore
    let projectID: UUID
    let isActive: Bool
    @Binding var isDispatchPresented: Bool
    let onSend: (ProjectOperation, [URL], ProjectImportMode) -> Bool
    @EnvironmentObject private var bridge: ProjectEditorBridge
    @AppStorage(AppPreferences.workspaceOrderKey) private var storedWorkspaceOrder = ""
    @AppStorage("projectLibrary.didAddPhotos") private var didAddPhotos = false
    @AppStorage("projectLibrary.groupSidebarWidth") private var groupSidebarWidth = 340.0
    @State private var selection: Set<UUID> = []
    @State private var selectedGroupID: UUID?
    @State private var selectedWholeGroupID: UUID?
    @State private var groupSelection: Set<UUID> = []
    @State private var catalog = ProjectMaterialCatalog()
    @State private var visibleAssets: [ProjectAsset] = []
    @State private var filter = ProjectMaterialFilter()
    @State private var showsFilter = false
    @State private var search = ""
    @State private var arrangeRequest = 0
    @State private var dispatch: ProjectDispatch?
    @State private var draggedGroupID: UUID?
    @State private var groupDropInsertionIndex: Int?
    @State private var groupDropTargetID: UUID?
    @State private var assetDropTargetGroupID: UUID?

    private var showsModal: Bool { dispatch != nil || showsFilter }

    private var assets: [ProjectAsset] { catalog.assets }
    private var groups: [ProjectPhotoGroup] { library.currentProject?.groups ?? [] }
    private var activeSelection: Set<UUID> { selectedGroupID == nil ? selection : groupSelection }
    private var selectedAssets: [ProjectAsset] { orderedForDispatch(activeSelection) }
    private var selectedCount: Int { selectedAssets.count }
    private var assetURLs: [UUID: URL] {
        Dictionary(uniqueKeysWithValues: visibleAssets.map { ($0.id, library.assetURL($0)) })
    }
    private var operations: [ProjectOperation] {
        AppPreferences.workspaceOrder(from: storedWorkspaceOrder).compactMap { ProjectOperation(rawValue: $0.rawValue) }
    }
    private var badges: [UUID: String] {
        catalog.badges
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryToolbar
            Divider()
            ProjectSidebarSplit(isPresented: true, width: $groupSidebarWidth, edge: .trailing,
                                sidebarMinimum: 220, sidebarMaximum: 650, contentMinimum: 260) {
                groupPane
            } content: {
                    ZStack {
                        ProjectThumbnailRefresh(library: library, assets: visibleAssets,
                                                isActive: isActive) { thumbnails, reportVisible in
                        ProjectMaterialBoard(
                            assets: visibleAssets, selection: $selection,
                            thumbnailSize: CGFloat(library.currentProject?.thumbnailSize ?? 128),
                            viewZoom: .constant(1), fitRequest: arrangeRequest,
                            thumbnails: thumbnails, assetURLs: assetURLs, isActive: isActive && !showsModal,
                            badges: badges,
                            onMove: library.moveAssets,
                            onImport: { urls, point in library.importURLs(urls, at: point) },
                            onActivate: { id in selection = [id] },
                            onThumbnailDemand: reportVisible,
                            onViewportChange: { size in
                                guard library.currentProject?.id == projectID else { return }
                                library.boardViewportWidth = size.width
                            },
                            operations: operations,
                            onSend: prepareDispatch,
                            onGather: { ids, _ in createGroup(ids) },
                            onUngroup: library.ungroupAssets,
                            onRemove: library.removeAssets,
                            onImportPanel: library.importPanel,
                            onUndo: library.undoLastEdit,
                            onFocus: { selectedGroupID = nil; selectedWholeGroupID = nil; groupSelection = [] },
                            onDropAssets: library.returnAssetsToMaterials,
                            onReorder: library.reorderMaterials,
                            onThumbnailResize: { size in
                                guard library.currentProject?.id == projectID else { return }
                                library.setThumbnailSize(Double(size))
                            }
                        )
                        }
                        if visibleAssets.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: assets.isEmpty ? "photo.on.rectangle.angled" : "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 36)).foregroundStyle(.secondary)
                                Text(assets.isEmpty ? "把照片或文件夹拖进来" : groups.isEmpty ? "没有符合条件的素材" : "这里显示未分组的照片")
                                    .font(.headline)
                                Text(assets.isEmpty ? "也可以点击上方「导入素材」" : "右侧照片可拖回这里，或按 Delete 移回素材")
                                    .foregroundStyle(.secondary)
                            }.allowsHitTesting(false)
                        }
                    }
            }
            Divider()
            materialActionBar
            HStack {
                Text(library.currentProject?.name ?? "项目")
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
                Text("·")
                Text("未分组 \(visibleAssets.count) 张 · 项目共 \(assets.count) 张")
                if filter.isActive { Text("· \(filter.summary)").lineLimit(1) }
                Spacer()
                Text("空格预览 · 回车分组")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
        }
        .onAppear {
            guard library.currentProject?.id == projectID else { return }
            refreshCatalog()
            library.boardViewZoom = 1
        }
        .onChange(of: library.currentProject?.modifiedAt) { _, _ in refreshCatalog() }
        .onChange(of: filter) { _, _ in refreshFiltering() }
        .onChange(of: search) { _, _ in refreshFiltering() }
        .onChange(of: isActive) { _, active in
            if !active { showsFilter = false }
        }
        .onChange(of: showsModal) { _, value in isDispatchPresented = value }
        .onChange(of: visibleAssets.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
        .sheet(item: $dispatch) { request in
            ProjectDispatchSheet(operation: request.operation, assets: request.assets) { orderedAssets, importMode in
                if onSend(request.operation, orderedAssets.map { library.assetURL($0) }, importMode) {
                    didAddPhotos = true
                    dispatch = nil
                }
            }.environmentObject(bridge)
        }
    }

    private var materialActionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !didAddPhotos {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择想拼在一起的照片，按回车在右侧建一组。")
                        .font(.callout.weight(.medium))
                    Text("在空白处拖动框选，或按住 Shift 逐张选择。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    actionSelectionLabel
                    ForEach(operations) { operation in operationTarget(operation) }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    actionSelectionLabel
                    HStack(spacing: 6) {
                        ForEach(operations) { operation in operationTarget(operation) }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actionSelectionLabel: some View {
        Text(selectedCount == 0 ? "选择照片后，添加至：" : "已选 \(selectedCount) 张，添加至：")
            .font(.callout).foregroundStyle(selectedCount == 0 ? .secondary : .primary)
            .fixedSize()
    }

    private func operationTarget(_ operation: ProjectOperation) -> some View {
        ProjectOperationTarget(
            operation: operation, selectionCount: selectedCount,
            isBusy: bridge.status(for: operation).isBusy || showsModal || !isActive || bridge.request != nil,
            onChoose: { prepareDispatch(operation, ids: activeSelection) },
            onDropIDs: { prepareDispatch(operation, ids: Set($0)) }
        )
    }

    private var libraryToolbar: some View {
        HStack(spacing: 10) {
            Button(action: library.importPanel) { Label("导入素材", systemImage: "plus") }
                .buttonStyle(.borderedProminent).disabled(library.isImporting)
            if library.isImporting { ProgressView().controlSize(.small) }
            TextField("搜索照片名称", text: $search)
                .textFieldStyle(.roundedBorder).frame(minWidth: 90, idealWidth: 180, maxWidth: 220)
            Button { showsFilter.toggle() } label: {
                Label("筛选", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .foregroundStyle(filter.isActive ? Color.accentColor : Color.primary)
            .help(filter.isActive ? filter.summary : "筛选未分组素材")
            .popover(isPresented: $showsFilter, arrowEdge: .bottom) { filterPopover }
            Spacer(minLength: 0)
            Button("整理对齐") { arrangeRequest += 1 }
                .disabled(!assets.contains { $0.groupID == nil })
                .help("素材已按当前顺序自动对齐，点击回到排列起点")
            thumbnailControls
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var thumbnailControls: some View {
        let linked = library.currentProject?.thumbnailSizesLinked ?? true
        return HStack(spacing: 5) {
            Text("素材").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { library.currentProject?.thumbnailSize ?? 128 }, set: { size in
                guard library.currentProject?.id == projectID else { return }
                library.setThumbnailSize(size)
            }), in: ProjectMaterialLayout.thumbnailRange, onEditingChanged: { editing in
                guard editing, let document = library.currentProject, document.id == projectID else { return }
                library.setThumbnailSize(document.thumbnailSize)
            })
                .frame(width: 76)
                .help("项目素材缩略图大小：\(Int(library.currentProject?.thumbnailSize ?? 128))")
                .accessibilityLabel("项目素材缩略图大小")
            Button {
                guard library.currentProject?.id == projectID else { return }
                library.setThumbnailSizesLinked(!linked)
            } label: {
                Image(systemName: linked ? "lock.fill" : "lock.open")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(linked ? Color.accentColor : Color.secondary)
                    .background(linked ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(linked ? "已锁定：任一滑块同时调整两区。点击可独立调整。" : "独立调整。点击锁定后，下一次拖动会同步另一侧。")
            .accessibilityLabel("联动缩略图大小")
            .accessibilityValue(linked ? "已锁定" : "已解锁")
            Slider(value: Binding(get: { library.currentProject?.groupThumbnailSize ?? 128 }, set: { size in
                guard library.currentProject?.id == projectID else { return }
                library.setGroupThumbnailSize(size)
            }), in: ProjectMaterialLayout.thumbnailRange, onEditingChanged: { editing in
                guard editing, let document = library.currentProject, document.id == projectID else { return }
                library.setGroupThumbnailSize(document.groupThumbnailSize)
            })
                .frame(width: 76)
                .help("照片组缩略图大小：\(Int(library.currentProject?.groupThumbnailSize ?? 128))")
                .accessibilityLabel("照片组缩略图大小")
            Text("分组").font(.caption).foregroundStyle(.secondary)
        }.fixedSize()
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("筛选素材").font(.headline)
                Spacer()
                Button("清除筛选") { filter = ProjectMaterialFilter() }.disabled(!filter.isActive)
                    .buttonStyle(.borderless)
            }
            Picker("拼图方式", selection: $filter.operation) {
                Text("不限").tag(Optional<ProjectOperation>.none)
                ForEach(operations) { operation in Text(operation.title).tag(Optional(operation)) }
            }
            Picker("导出状态", selection: $filter.status) {
                ForEach(ProjectMaterialFilter.Status.allCases) { status in Text(status.title).tag(status) }
            }.pickerStyle(.segmented)
            Text("选择拼图方式后，导出状态仅针对该方式。筛选用于中间的未分组素材。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(visibleAssets.count) 张符合条件").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { showsFilter = false }
            }
        }.padding(16).frame(width: 300)
    }

    private var groupPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("照片组").font(.headline)
                Text("\(groups.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text("拖回素材或按 Delete").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { if isActive && !showsModal { clearSelection() } }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            ProjectPhotoGroupRow(
                                library: library, group: group,
                                members: group.assetIDs.compactMap { catalog.byID[$0] },
                                thumbnailSize: CGFloat(library.currentProject?.groupThumbnailSize ?? 128),
                                selection: Binding(
                                    get: { selectedGroupID == group.id ? groupSelection : [] },
                                    set: {
                                        selectedGroupID = group.id
                                        selectedWholeGroupID = nil
                                        groupSelection = $0
                                    }
                                ),
                                isSelected: selectedWholeGroupID == group.id && groupSelection == Set(group.assetIDs),
                                isActive: isActive && !showsModal,
                                canMoveUp: index > 0, canMoveDown: index + 1 < groups.count,
                                badges: badges,
                                onChoose: {
                                    selection = []
                                    selectedGroupID = group.id
                                    selectedWholeGroupID = group.id
                                    groupSelection = Set(group.assetIDs)
                                },
                                onClearSelection: clearSelection,
                                onFocus: {
                                    selection = []
                                    selectedWholeGroupID = nil
                                    if selectedGroupID != group.id { groupSelection = [] }
                                    selectedGroupID = group.id
                                },
                                onSend: prepareDispatch,
                                showDropLineBefore: groupDropTargetID == group.id && draggedGroupID != group.id
                                    && groupDropInsertionIndex == index,
                                showDropLineAfter: groupDropTargetID == group.id && draggedGroupID != group.id
                                    && groupDropInsertionIndex == index + 1,
                                onGroupDragBegan: {
                                    clearGroupDrag()
                                    draggedGroupID = group.id
                                },
                                onGroupDragEnded: clearGroupDrag,
                                onGroupDragHover: { id, before in
                                    guard id != group.id,
                                          groups.contains(where: { $0.id == id }) else { return false }
                                    draggedGroupID = id
                                    groupDropTargetID = group.id
                                    groupDropInsertionIndex = index + (before ? 0 : 1)
                                    return true
                                },
                                onGroupDragExit: {
                                    if groupDropTargetID == group.id {
                                        groupDropTargetID = nil
                                        groupDropInsertionIndex = nil
                                    }
                                },
                                onDropGroup: { id, before in
                                    defer { clearGroupDrag() }
                                    return library.moveGroup(id, relativeTo: group.id, before: before)
                                },
                                onAssetDropTargetChange: { targeted in
                                    if targeted { assetDropTargetGroupID = group.id }
                                    else if assetDropTargetGroupID == group.id { assetDropTargetGroupID = nil }
                                }
                            )
                            .id(group.id)
                            .overlay {
                                if assetDropTargetGroupID == group.id {
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                        if groups.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "rectangle.stack").font(.title)
                                Text("每按一次回车，这里就多一组")
                                Text("照片会展开排列，方便逐组拼图")
                                    .font(.caption)
                            }.foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                    }.padding(4).projectOverlayScrollbars()
                        .projectGroupBlankSelection(isActive: isActive && !showsModal,
                                                    onClearSelection: clearSelection)
                }
                .onChange(of: selectedGroupID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func createGroup(_ ids: Set<UUID>) {
        guard let id = library.createGroup(ids) else { return }
        selection.subtract(ids)
        selectedGroupID = id
        selectedWholeGroupID = id
        groupSelection = ids
    }

    private func clearGroupDrag() {
        draggedGroupID = nil
        groupDropTargetID = nil
        groupDropInsertionIndex = nil
        assetDropTargetGroupID = nil
    }

    private func refreshCatalog() {
        guard library.currentProject?.id == projectID else { return }
        catalog = ProjectMaterialCatalog(library.currentProject)
        refreshFiltering()
        if let id = selectedGroupID {
            if let group = groups.first(where: { $0.id == id }) {
                groupSelection.formIntersection(group.assetIDs)
            } else {
                selectedGroupID = nil
                selectedWholeGroupID = nil
                groupSelection = []
            }
        }
    }

    private func refreshFiltering() {
        let searched = catalog.assets.filter {
            $0.groupID == nil && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
        visibleAssets = searched.filter { filter.includes(operations: catalog.usage[$0.id, default: []]) }
    }

    private func orderedForDispatch(_ ids: Set<UUID>) -> [ProjectAsset] {
        if let group = groups.first(where: { !ids.isEmpty && ids.isSubset(of: Set($0.assetIDs)) }) {
            return group.assetIDs.filter { ids.contains($0) }.compactMap { catalog.byID[$0] }
        }
        return catalog.assets.filter { ids.contains($0.id) }
    }

    private func clearSelection() {
        selection = []
        selectedGroupID = nil
        selectedWholeGroupID = nil
        groupSelection = []
    }

    private func prepareDispatch(_ operation: ProjectOperation, ids: Set<UUID>) {
        guard isActive, !showsModal, bridge.request == nil, ProjectOperation.allCases.contains(operation) else { return }
        let chosen = orderedForDispatch(ids)
        guard !chosen.isEmpty else { return }
        let status = bridge.status(for: operation)
        guard !status.isBusy else {
            library.message = "\(operation.title)正在处理，请完成后再添加照片。"
            return
        }
        guard operation != .gridCollage || chosen.count <= 16 else {
            library.message = "标准拼图最多容纳 16 张照片，请减少选择后重试。"
            return
        }
        if status.count == 0 {
            if onSend(operation, chosen.map { library.assetURL($0) }, .append) { didAddPhotos = true }
        } else {
            dispatch = ProjectDispatch(operation: operation, assets: chosen)
        }
    }


}

struct ProjectThumbnailRefresh<Content: View>: View {
    let library: ProjectLibraryStore
    let assets: [ProjectAsset]
    let isActive: Bool
    @ViewBuilder var content: ([UUID: NSImage], @escaping (ProjectThumbnailDemand) -> Void) -> Content
    @State private var indexedAssets: [UUID: ProjectAsset] = [:]
    @State private var demand = ProjectThumbnailDemand(visibleIDs: [], prefetchIDs: [], maximumPixelSize: 192)
    @State private var isSettled = false
    @State private var isMounted = false
    @State private var upgradeTask: Task<Void, Never>?
    @State private var thumbnailOwner = UUID()
    @State private var images: [UUID: NSImage] = [:]

    private var currentImages: [UUID: NSImage] {
        var result: [UUID: NSImage] = [:]
        // SwiftUI evaluates body before onChange. Never pair an old image with
        // a newly replaced asset while updateAssets is waiting for that callback.
        for asset in assets {
            guard let previous = indexedAssets[asset.id],
                  previous.fileName == asset.fileName,
                  previous.contentRevision == asset.contentRevision,
                  let image = images[asset.id] else { continue }
            result[asset.id] = image
        }
        return result
    }

    var body: some View {
        content(currentImages, reportVisible)
            .onAppear { isMounted = true; updateAssets(); scheduleUpgrade() }
            .onChange(of: assets) { _, _ in updateAssets() }
            .onChange(of: isActive) { _, active in
                if active { refreshImages(); scheduleUpgrade() }
                else {
                    upgradeTask?.cancel()
                    isSettled = false
                    library.releaseThumbnailDemand(owner: thumbnailOwner)
                }
            }
            .onDisappear {
                isMounted = false
                isSettled = false
                upgradeTask?.cancel()
                library.releaseThumbnailDemand(owner: thumbnailOwner)
            }
            .onReceive(library.thumbnailUpdates.completed) { ids in
                guard !ids.isDisjoint(with: demand.assetIDs) else { return }
                refreshImages()
            }
            .transaction { $0.animation = nil }
    }

    private func updateAssets() {
        // Inactive workspaces also discard replaced originals, even though
        // they postpone loading new previews until the user returns.
        let validImages = currentImages
        if images.count != validImages.count { images = validImages }
        indexedAssets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        refreshImages()
    }

    private func reportVisible(_ next: ProjectThumbnailDemand) {
        guard demand != next else { return }
        demand = next
        isSettled = false
        refreshImages()
        scheduleUpgrade()
    }

    private func scheduleUpgrade() {
        upgradeTask?.cancel()
        guard isActive, isMounted, !demand.visibleIDs.isEmpty else { return }
        upgradeTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            guard !Task.isCancelled else { return }
            isSettled = true
            refreshImages()
        }
    }

    private func refreshImages() {
        guard isActive, isMounted else { return }
        library.updateThumbnailDemand(owner: thumbnailOwner,
                                      assetIDs: demand.assetIDs.intersection(indexedAssets.keys))
        var next: [UUID: NSImage] = [:]
        // Scrolling and thumbnail arrivals only update this small subtree. They
        // never publish viewport state back through the entire project workspace.
        for id in demand.visibleIDs {
            guard let asset = indexedAssets[id] else { continue }
            let cached = library.cachedThumbnail(for: asset, maximumPixelSize: demand.maximumPixelSize)
            let retained = images[id]
            let available = betterThumbnail(retained, cached)
            let image: NSImage?
            if let available, library.isThumbnail(available, sufficientForDisplayPixelSize: demand.maximumPixelSize) {
                // Visible images may outlive the global LRU. Their resolution
                // metadata prevents repeatedly decoding an already-sharp photo.
                image = available
            } else if isSettled {
                image = betterThumbnail(available, library.displayThumbnail(for: asset,
                    pixelSize: demand.maximumPixelSize, owner: thumbnailOwner))
            } else {
                // Keep every decoded image while scrolling. Only blank visible
                // cells request the small tier; sharper work waits for rest.
                image = available ?? library.thumbnail(for: asset, maximumPixelSize: 192, owner: thumbnailOwner)
            }
            if let image { next[id] = image }
        }
        for id in demand.prefetchIDs {
            guard let asset = indexedAssets[id] else { continue }
            let retained = images[id]
            let cached = library.cachedThumbnail(for: asset, maximumPixelSize: 192)
            let available = betterThumbnail(retained, cached)
            let image = available ?? (isSettled
                ? library.thumbnail(for: asset, maximumPixelSize: 192, priority: .veryLow, owner: thumbnailOwner)
                : nil)
            if let image { next[id] = image }
        }
        guard images.count != next.count || next.contains(where: { images[$0.key] !== $0.value }) else { return }
        images = next
    }

    private func betterThumbnail(_ first: NSImage?, _ second: NSImage?) -> NSImage? {
        guard let first else { return second }
        guard let second else { return first }
        if library.isDetailedThumbnail(first) { return first }
        if library.isDetailedThumbnail(second) { return second }
        let firstSufficient = library.isThumbnail(first, sufficientForDisplayPixelSize: demand.maximumPixelSize)
        let secondSufficient = library.isThumbnail(second, sufficientForDisplayPixelSize: demand.maximumPixelSize)
        if firstSufficient != secondSufficient { return firstSufficient ? first : second }
        func pixels(_ image: NSImage) -> Int {
            image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        }
        return pixels(first) > pixels(second) ? first : second
    }
}


private struct ProjectOperationTarget: View {
    let operation: ProjectOperation
    let selectionCount: Int
    let isBusy: Bool
    let onChoose: () -> Void
    let onDropIDs: ([UUID]) -> Void
    @ObservedObject private var materialDrag = ProjectMaterialDragState.shared
    @State private var isTargeted = false
    @State private var isHovered = false

    private var shortcut: String {
        switch operation {
        case .gridCollage: return "1"
        case .freeCanvas: return "2"
        case .longStitch: return "3"
        case .compression: return ""
        }
    }

    private var title: String {
        if isTargeted && !isBusy { return "松开添加 \(materialDrag.assetIDs.count) 张" }
        return operation.title
    }

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 6) {
                Image(systemName: operation.systemImage)
                Text(title).lineLimit(1)
                Text(shortcut)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProjectOperationButtonStyle(highlighted: isTargeted || (isHovered && !isBusy),
                                                available: selectionCount > 0 && !isBusy))
        .onHover { isHovered = $0 }
        .disabled(isBusy || selectionCount == 0)
        .help(isBusy ? "当前工具正在处理" : "点击或按 \(shortcut)，将选中照片添加至\(operation.title)")
        .onDrop(of: [ProjectMaterialBoard.assetPasteboardType.rawValue], isTargeted: $isTargeted) { providers in
            guard !isBusy, let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: ProjectMaterialBoard.assetPasteboardType.rawValue) { data, _ in
                guard let data, let strings = try? JSONDecoder().decode([String].self, from: data) else { return }
                let ids = strings.compactMap(UUID.init(uuidString:))
                DispatchQueue.main.async { onDropIDs(ids) }
            }
            return true
        }
    }
}

private struct ProjectOperationButtonStyle: ButtonStyle {
    let highlighted: Bool
    let available: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.24 : highlighted ? 0.16 : available ? 0.07 : 0.02),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(highlighted || available ? Color.accentColor.opacity(highlighted ? 1 : 0.45) : Color(nsColor: .separatorColor),
                              lineWidth: highlighted ? 1.5 : 1))
    }
}

private struct ProjectDispatchSheet: View {
    let operation: ProjectOperation
    @State var assets: [ProjectAsset]
    let onSend: ([ProjectAsset], ProjectImportMode) -> Void
    @EnvironmentObject private var bridge: ProjectEditorBridge
    @Environment(\.dismiss) private var dismiss

    private var status: ProjectEditorStatus { bridge.status(for: operation) }
    private var isTooMany: Bool { operation == .gridCollage && assets.count > 16 }
    private var appendExceedsLimit: Bool { operation == .gridCollage && status.count + assets.count > 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("将 \(assets.count) 张照片添加到\(operation.title)").font(.title2.weight(.semibold))
            if status.count > 0 {
                Label(status.hasUnexportedChanges ? "当前已有 \(status.count) 项素材，存在尚未导出的内容。" : "当前已有 \(status.count) 项素材，现有内容已导出。",
                      systemImage: status.hasUnexportedChanges ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(status.hasUnexportedChanges ? Color.orange : Color.secondary)
                Text("继续添加会保留当前编辑结果；清空后导入将开始新的一组，项目中的素材、照片组和处理状态会保留。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("本次添加顺序：可拖动条目或用箭头调整，素材库中的排列位置会保留。")
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
                    }.buttonStyle(.borderless).padding(.vertical, 4)
                }.onMove { from, to in assets.move(fromOffsets: from, toOffset: to) }
            }.frame(height: 250)
            if status.isBusy {
                Text("目标工具正在处理，请完成后再导入。").font(.caption).foregroundStyle(.secondary)
            } else if isTooMany || appendExceedsLimit {
                Text(isTooMany ? "标准拼图最多容纳 16 张照片，请减少选择。" : "继续添加后将超过 16 张，可选择清空后导入或取消。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if status.count > 0 {
                    Button("清空后导入", role: .destructive) { onSend(assets, .replace) }
                        .disabled(status.isBusy || isTooMany || assets.isEmpty)
                }
                Button(status.count > 0 ? "继续添加" : "导入照片") { onSend(assets, .append) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(status.isBusy || appendExceedsLimit || assets.isEmpty)
            }
        }.padding(24).frame(width: 550)
    }
}
