import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var library = ProjectLibraryStore()
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme

    var body: some View {
        Group {
            if let project = library.currentProject {
                ProjectWorkspaceView(library: library)
                    .id(project.id)
            } else {
                ProjectHomeView(library: library)
            }
        }
        .frame(minWidth: 1020, minHeight: 740)
        .preferredColorScheme(theme == 2 ? .dark : .light)
        .alert("项目素材库", isPresented: Binding(
            get: { library.message != nil },
            set: { if !$0 { library.message = nil } }
        )) {
            Button("确定") { library.message = nil }
        } message: { Text(library.message ?? "") }
    }
}

private struct ProjectHomeView: View {
    @ObservedObject var library: ProjectLibraryStore
    @State private var showingNewProject = false
    @State private var projectName = ""
    @State private var isDropTargeted = false

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
                    Text("导入照片，自由摆放；用过哪些、导出了什么，都留在项目里。")
                        .foregroundStyle(.secondary)
                    Button("新建第一个项目") { showingNewProject = true }
                        .buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                Text("最近项目").font(.headline)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                        ForEach(library.projects) { project in
                            Button { library.openProject(id: project.id) } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    Image(systemName: "folder").font(.system(size: 30))
                                        .foregroundStyle(Color.accentColor)
                                    Text(project.name).font(.title3.weight(.semibold)).lineLimit(1)
                                    HStack {
                                        Text("\(project.assetCount) 张素材")
                                        Spacer()
                                        Text(project.modifiedAt, style: .date)
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                            }.buttonStyle(.plain)
                        }
                    }.padding(2)
                }
            }
            Text("项目会自动保存素材、摆放位置和导出记录。拼图编辑草稿暂不保存。")
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
                Text("照片会复制到项目素材库。也可以把文件夹拖到这里，直接用文件夹名称创建。")
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

private struct ProjectWorkspaceView: View {
    @ObservedObject var library: ProjectLibraryStore
    @State private var mode = "library"
    @State private var showingCloseConfirmation = false
    @StateObject private var bridge = ProjectEditorBridge()
    @StateObject private var canvasStore = CanvasStore()
    @StateObject private var compressionStore = CompressionWorkspace()
    @StateObject private var gridCollageStore = GridCollageStore()
    @AppStorage(AppPreferences.workspaceOrderKey) private var storedWorkspaceOrder = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { showingCloseConfirmation = true } label: {
                    Label("项目列表", systemImage: "chevron.left")
                }
                .disabled(bridge.activeExportCount > 0 || library.isImporting || compressionStore.isBusy || bridge.request != nil || bridge.statuses.values.contains(where: { $0.isBusy }))
                Text(library.currentProject?.name ?? "项目").font(.headline).lineLimit(1)
                Spacer()
                if bridge.activeExportCount > 0 {
                    ProgressView().controlSize(.small)
                    Text("正在导出…").font(.caption).foregroundStyle(.secondary)
                }
                if mode != "library" {
                    Button { mode = "library" } label: {
                        Label("返回素材库", systemImage: "square.grid.3x3")
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            TabView(selection: $mode) {
                ProjectLibraryView(library: library) { operation, urls, importMode in
                    guard bridge.send(operation: operation, urls: urls, mode: importMode) else {
                        library.message = "目标工具正在处理，或添加后超过容量限制。请稍后重试。"
                        return false
                    }
                    mode = operation.rawValue
                    return true
                }
                .tabItem { Label("项目素材", systemImage: "square.grid.3x3") }
                .tag("library")
                ForEach(AppPreferences.workspaceOrder(from: storedWorkspaceOrder)) { workspace in
                    workspaceView(workspace)
                        .tabItem { Label(workspace.title, systemImage: workspace.systemImage) }
                        .tag(workspace.rawValue)
                }
            }.padding(8)
        }
        .environmentObject(library)
        .environmentObject(bridge)
        .alert("返回项目列表？", isPresented: $showingCloseConfirmation) {
            Button("取消", role: .cancel) {}
            Button("返回项目列表", role: .destructive) { library.closeProject() }
        } message: {
            Text("素材、摆放位置和导出记录已自动保存。各拼图工具中的编辑状态不会保留。")
        }
    }

    @ViewBuilder private func workspaceView(_ workspace: AppWorkspace) -> some View {
        switch workspace {
        case .border: BorderWorkspaceView(isActive: mode == workspace.rawValue)
        case .freeCanvas: FreeCanvasView(store: canvasStore, isActive: mode == workspace.rawValue)
        case .longStitch: LongStitchView(isActive: mode == workspace.rawValue)
        case .compression: CompressionView(workspace: compressionStore, isActive: mode == workspace.rawValue)
        case .gridCollage: GridCollageView(store: gridCollageStore, isActive: mode == workspace.rawValue)
        }
    }
}

private enum MaterialFilter: Hashable {
    case all, unused, used, operation(ProjectOperation), unusedFor(ProjectOperation)

    var title: String {
        switch self {
        case .all: return "全部素材"
        case .unused: return "未导出"
        case .used: return "已导出"
        case .operation(let operation): return operation.title
        case .unusedFor(let operation): return "未用于\(operation.title)"
        }
    }

    func includes(_ asset: ProjectAsset, records: [ProjectExportRecord]) -> Bool {
        let usage = records.filter { $0.assetIDs.contains(asset.id) }
        switch self {
        case .all: return true
        case .unused: return usage.isEmpty
        case .used: return !usage.isEmpty
        case .operation(let operation): return usage.contains { $0.operation == operation }
        case .unusedFor(let operation): return !usage.contains { $0.operation == operation }
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
    let onSend: (ProjectOperation, [URL], ProjectImportMode) -> Bool
    @EnvironmentObject private var bridge: ProjectEditorBridge
    @AppStorage(AppPreferences.workspaceOrderKey) private var storedWorkspaceOrder = ""
    @AppStorage(AppPreferences.libraryLabelsKey) private var showsRatingsAndColors = true
    @State private var ratingFilter = -1
    @State private var colorFilter = "all"
    @State private var selection: Set<UUID> = []
    @State private var visibleThumbnailIDs: Set<UUID> = []
    @State private var filter: MaterialFilter = .all
    @State private var search = ""
    @State private var viewZoom = 1.0
    @State private var fitRequest = 0
    @State private var boardViewport = CGSize(width: 800, height: 600)
    @State private var didInitializeViewport = false
    @State private var showsInspector = false
    @State private var dispatch: ProjectDispatch?
    @State private var showingResults = false
    @State private var showingArrangeConfirmation = false

    private var assets: [ProjectAsset] { library.currentProject?.activeAssets ?? [] }
    private var records: [ProjectExportRecord] { library.currentProject?.exports ?? [] }
    private var visibleAssets: [ProjectAsset] {
        assets.filter { asset in
            filter.includes(asset, records: records)
                && matchesLabels(asset)
                && (search.isEmpty || asset.name.localizedCaseInsensitiveContains(search))
        }
    }
    private var selectedAssets: [ProjectAsset] { ordered(assets.filter { selection.contains($0.id) }) }
    private var thumbnails: [UUID: NSImage] {
        var result: [UUID: NSImage] = [:]
        let previewPixels = Int(ceil((library.currentProject?.thumbnailSize ?? 128) * viewZoom * 2))
        for asset in visibleAssets where visibleThumbnailIDs.contains(asset.id) {
            if let image = library.thumbnail(for: asset, maximumPixelSize: previewPixels) { result[asset.id] = image }
        }
        return result
    }
    private var operations: [ProjectOperation] {
        AppPreferences.workspaceOrder(from: storedWorkspaceOrder).compactMap { ProjectOperation(rawValue: $0.rawValue) }
    }
    private var selectedUnusedCount: Int {
        selectedAssets.filter { asset in !records.contains { $0.assetIDs.contains(asset.id) } }.count
    }
    private func matchesLabels(_ asset: ProjectAsset) -> Bool {
        (ratingFilter < 0 || asset.rating == ratingFilter)
            && (colorFilter == "all" || asset.colorLabel.rawValue == colorFilter)
    }
    private var badges: [UUID: String] {
        Dictionary(uniqueKeysWithValues: visibleAssets.map { asset in
            let usage = records.filter { $0.assetIDs.contains(asset.id) }
            let details = operations.compactMap { operation -> String? in
                let count = usage.filter { $0.operation == operation }.count
                return count == 0 ? nil : "\(operation.title) \(count) 次"
            }
            let status = details.isEmpty ? "尚未导出" : details.joined(separator: "、")
            return (asset.id, status)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryToolbar
            HStack(spacing: 8) {
                ForEach([MaterialFilter.all, .unused, .used], id: \.self) { value in
                    filterButton(value).fixedSize(horizontal: true, vertical: false)
                }
                Spacer()
                if !selection.isEmpty {
                    Text("选中 \(selection.count) 张，其中 \(selectedUnusedCount) 张尚未导出")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            HStack(spacing: 0) {
                filterSidebar.frame(width: 155)
                Divider()
                VStack(spacing: 0) {
                    ZStack {
                        ProjectMaterialBoard(
                            assets: visibleAssets, selection: $selection,
                            thumbnailSize: CGFloat(library.currentProject?.thumbnailSize ?? 128),
                            viewZoom: $viewZoom, fitRequest: fitRequest,
                            thumbnails: thumbnails, badges: badges,
                            onMove: library.moveAssets,
                            onImport: { urls, point in library.importURLs(urls, at: point) },
                            onActivate: { id in selection = [id]; showsInspector = true },
                            onVisibleAssets: { visibleThumbnailIDs = $0 },
                            onViewportChange: { size in
                                boardViewport = size
                                library.boardViewportWidth = size.width
                            },
                            showsRatingsAndColors: showsRatingsAndColors,
                            operations: operations,
                            onSend: prepareDispatch,
                            onRate: { library.setRating($0, rating: $1) },
                            onColor: { library.setColor($0, color: $1) },
                            onRemove: library.removeAssets,
                            onImportPanel: library.importPanel,
                            onUndo: library.undoLastEdit
                        )
                        if visibleAssets.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: assets.isEmpty ? "photo.on.rectangle.angled" : "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 36)).foregroundStyle(.secondary)
                                Text(assets.isEmpty ? "把照片或文件夹拖进来" : "没有符合条件的素材")
                                    .font(.headline)
                                Text(assets.isEmpty ? "也可以点击上方「导入素材」" : "调整筛选条件，或清空搜索")
                                    .foregroundStyle(.secondary)
                            }.allowsHitTesting(false)
                        }
                    }
                    Divider()
                    HStack(spacing: 10) {
                        ForEach(operations) { operation in
                            ProjectOperationTarget(operation: operation, selectionCount: selection.count, isBusy: bridge.status(for: operation).isBusy,
                                onChoose: { prepareDispatch(operation, ids: selection) },
                                onDropIDs: { prepareDispatch(operation, ids: Set($0)) })
                        }
                    }.padding(12)
                    HStack {
                        Text("\(visibleAssets.count) / \(assets.count) 张 · 已选 \(selection.count) 张")
                        Spacer()
                        Text("⌘ 多选 · 拖动框选 · 点击下方或右键发送")
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
                }
                if showsInspector {
                    Divider()
                    selectionInspector.frame(width: 230)
                }
            }
        }
        .onAppear {
            guard !didInitializeViewport else { return }
            didInitializeViewport = true
            viewZoom = library.currentProject?.viewZoom ?? 1
            library.boardViewZoom = CGFloat(viewZoom)
            if library.currentProject?.viewZoom == nil, !assets.isEmpty { fitRequest += 1 }
        }
        .onChange(of: assets.count) { oldCount, newCount in
            if oldCount == 0, newCount > 0 { fitRequest += 1 }
        }
        .onChange(of: viewZoom) { _, zoom in library.boardViewZoom = CGFloat(zoom) }
        .task(id: viewZoom) {
            // Coalesce slider / pinch updates; the saved coordinates never change with viewing scale.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            library.setViewZoom(viewZoom)
        }
        .onDisappear { library.setViewZoom(viewZoom) }
        .onChange(of: visibleAssets.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
        .sheet(item: $dispatch) { request in
            ProjectDispatchSheet(operation: request.operation, assets: request.assets) { orderedAssets, importMode in
                if onSend(request.operation, orderedAssets.map { library.assetURL($0) }, importMode) {
                    dispatch = nil
                }
            }.environmentObject(bridge)
        }
        .sheet(isPresented: $showingResults) {
            ProjectResultsView(records: records, assets: library.currentProject?.assets ?? []) { record in
                showingResults = false
                filter = .all
                search = ""
                ratingFilter = -1
                colorFilter = "all"
                selection = Set(record.assetIDs).intersection(Set(assets.map(\.id)))
                if selection.isEmpty { library.message = "这次导出的素材已从项目移除，导出记录仍然保留。" }
            }
        }
        .alert("整理全部素材的位置？", isPresented: $showingArrangeConfirmation) {
            Button("取消", role: .cancel) {}
            Button("整理对齐") { library.arrangeAssets(viewportWidth: boardViewport.width, zoom: CGFloat(viewZoom)) }
        } message: { Text("按当前窗口宽度将全部素材排列成整齐网格，包括筛选后暂时隐藏的素材。可以使用「撤销」恢复。") }
    }

    private var libraryToolbar: some View {
        HStack(spacing: 12) {
            Button(action: library.importPanel) { Label("导入素材", systemImage: "plus") }
                .buttonStyle(.borderedProminent).disabled(library.isImporting)
            if library.isImporting { ProgressView().controlSize(.small) }
            TextField("搜索照片名称", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            Spacer(minLength: 0)
            Button { showingResults = true } label: { Label("导出记录", systemImage: "clock.arrow.circlepath") }
            Button(action: library.undoLastEdit) { Image(systemName: "arrow.uturn.backward") }
                .help("撤销上次移动、评分、标色或移除（⌘Z）").disabled(!library.canUndoEdit)
            Button("整理对齐") { showingArrangeConfirmation = true }.disabled(assets.isEmpty)
            Menu {
                Toggle("显示评分与颜色标签", isOn: $showsRatingsAndColors)
            } label: { Image(systemName: "eye") }
            .help("素材显示选项")
            Button("显示全部") { fitRequest += 1 }.disabled(visibleAssets.isEmpty)
                .help("缩放查看当前筛选中的全部照片，保留摆放位置")
            Slider(value: Binding(get: { log2(viewZoom) }, set: { viewZoom = pow(2, $0) }),
                   in: log2(0.02)...log2(2))
                .frame(width: 90).help("整体缩放素材库，照片和间隔一起缩放")
            Text("\(Int((viewZoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 36)
            Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .help(showsInspector ? "收起素材信息" : "显示素材信息")
        }.padding(12)
    }

    private var filterSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("已导出用途").font(.caption).foregroundStyle(.secondary).padding(.top, 18).padding(.leading, 8)
                ForEach(operations) { operation in filterButton(.operation(operation)) }
                Text("还可以处理").font(.caption).foregroundStyle(.secondary).padding(.top, 18).padding(.leading, 8)
                ForEach(operations) { operation in filterButton(.unusedFor(operation)) }
                Divider().padding(.vertical, 10)
                Text("组合筛选").font(.caption).foregroundStyle(.secondary)
                Picker("评分", selection: $ratingFilter) {
                    Text("全部星级").tag(-1)
                    Text("未评分").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) 星").tag($0) }
                }
                Picker("颜色", selection: $colorFilter) {
                    Text("全部颜色").tag("all")
                    ForEach(ProjectColorLabel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Button("清除筛选") { filter = .all; ratingFilter = -1; colorFilter = "all"; search = "" }
                    .font(.caption).padding(.top, 8)
            }.padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func filterButton(_ value: MaterialFilter) -> some View {
        Button { filter = value } label: {
            HStack(spacing: 4) {
                Text(value.title).font(.callout).lineLimit(2)
                Spacer(minLength: 2)
                Text("\(assets.filter { value.includes($0, records: records) && matchesLabels($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(filter == value ? Color.accentColor.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var selectionInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selectedAssets.isEmpty {
                    Text("素材信息").font(.headline)
                    Text("选择照片，查看评分、颜色标签和导出记录。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("每次成功导出会新增记录，同一张照片可以用于多种操作。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(selectedAssets.count == 1 ? selectedAssets[0].name : "已选择 \(selectedAssets.count) 张照片")
                        .font(.headline).textSelection(.enabled)
                    if selectedAssets.count == 1, let asset = selectedAssets.first,
                       let thumbnail = library.thumbnail(for: asset) {
                        Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxHeight: 180)
                    }
                    Text("\(selectedUnusedCount) 张尚未导出")
                        .font(.callout).foregroundStyle(.secondary)
                    Menu {
                        Button("清除评分") { library.setRating(selection, rating: 0) }
                        ForEach(1...5, id: \.self) { rating in
                            Button("\(rating) 星") { library.setRating(selection, rating: rating) }
                        }
                    } label: {
                        Label(ratingDescription, systemImage: "star")
                    }
                    Menu {
                        ForEach(ProjectColorLabel.allCases) { color in
                            Button(color.title) { library.setColor(selection, color: color) }
                        }
                    } label: {
                        Label(colorDescription, systemImage: "tag")
                    }
                    Divider()
                    ForEach(operations) { operation in
                        let count = records.filter { $0.operation == operation && !Set($0.assetIDs).isDisjoint(with: selection) }.count
                        HStack {
                            Label(operation.title, systemImage: operation.systemImage)
                            Spacer()
                            Text("\(count) 次").foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                    Divider()
                    Text("相关导出").font(.subheadline.weight(.semibold))
                    let related = records.filter { !Set($0.assetIDs).isDisjoint(with: selection) }.sorted { $0.createdAt > $1.createdAt }
                    if related.isEmpty {
                        Text("还没有导出记录").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(related) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(URL(fileURLWithPath: record.outputPath).lastPathComponent).lineLimit(2)
                            Text("\(record.operation.title) · \(record.assetIDs.count) 张素材")
                                .foregroundStyle(.secondary)
                            Text(record.createdAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                            Button("在访达显示") { reveal(record) }
                        }.font(.caption)
                        Divider()
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func ordered(_ source: [ProjectAsset]) -> [ProjectAsset] {
        source.sorted {
            if $0.position.y != $1.position.y { return $0.position.y < $1.position.y }
            if $0.position.x != $1.position.x { return $0.position.x < $1.position.x }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private var ratingDescription: String {
        let ratings = Set(selectedAssets.map(\.rating))
        guard ratings.count == 1, let rating = ratings.first else { return "评分：混合" }
        return rating == 0 ? "未评分" : "\(rating) 星"
    }

    private var colorDescription: String {
        let colors = Set(selectedAssets.map(\.colorLabel))
        return colors.count == 1 ? (colors.first?.title ?? "无颜色") : "颜色：混合"
    }

    private func prepareDispatch(_ operation: ProjectOperation, ids: Set<UUID>) {
        let chosen = ordered(assets.filter { ids.contains($0.id) })
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
            _ = onSend(operation, chosen.map { library.assetURL($0) }, .append)
        } else {
            dispatch = ProjectDispatch(operation: operation, assets: chosen)
        }
    }

    private func reveal(_ record: ProjectExportRecord) {
        let url = URL(fileURLWithPath: record.outputPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            library.message = "这个导出文件已被移动或删除，项目仍保留当时的记录。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct ProjectOperationTarget: View {
    let operation: ProjectOperation
    let selectionCount: Int
    let isBusy: Bool
    let onChoose: () -> Void
    let onDropIDs: ([UUID]) -> Void
    @State private var isTargeted = false
    @State private var isHovered = false

    private var guidance: String {
        if isBusy { return "正在处理…" }
        if isTargeted { return selectionCount > 0 ? "松开添加 \(selectionCount) 张" : "松开添加照片" }
        return selectionCount > 0 ? "点击添加选中的 \(selectionCount) 张" : "选择后点击，也可拖入"
    }

    var body: some View {
        Button(action: onChoose) {
            VStack(spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: operation.systemImage)
                    Text(operation.title)
                    if isHovered && selectionCount > 0 && !isBusy {
                        Image(systemName: "arrow.up.right").font(.caption)
                    }
                }.font(.callout.weight(.semibold)).lineLimit(1)
                Text(guidance).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 5).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProjectOperationButtonStyle(highlighted: isTargeted || (isHovered && !isBusy),
                                                available: selectionCount > 0 && !isBusy))
        .onHover { isHovered = $0 }
        .disabled(isBusy)
        .help(isBusy ? "当前工具正在处理" : "选择照片后点击发送到\(operation.title)，也可以拖入照片")
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
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: highlighted)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
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
                Text("继续添加会保留当前编辑结果；清空后导入将开始新的一组，项目中的素材和导出记录会保留。")
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

private struct ProjectResultsView: View {
    let records: [ProjectExportRecord]
    let assets: [ProjectAsset]
    let onSelect: (ProjectExportRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("项目导出记录").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if records.isEmpty {
                Text("从素材库选择照片，处理并成功导出后，结果会出现在这里。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 240)
            } else {
                List(records.sorted { $0.createdAt > $1.createdAt }) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(record.operation.title, systemImage: record.operation.systemImage).font(.headline)
                            Spacer()
                            Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(URL(fileURLWithPath: record.outputPath).lastPathComponent).lineLimit(1)
                        Text(assets.filter { record.assetIDs.contains($0.id) }.map { $0.name + ($0.isRemoved ? "（已移除）" : "") }.joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Button("查看这 \(record.assetIDs.count) 张素材") { onSelect(record) }
                    }.padding(.vertical, 8)
                }.frame(height: 380)
            }
        }.padding(24).frame(width: 610)
    }
}
