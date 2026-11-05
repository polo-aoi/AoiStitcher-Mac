import SwiftUI
import AppKit
import ImageIO
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
    @StateObject private var materialNavigation = ProjectMaterialNavigation()
    @Environment(\.openSettings) private var openSettings
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme
    @AppStorage(AppPreferences.workspaceOrderKey) private var storedWorkspaceOrder = ""
    @State private var mode = "library"
    @State private var homeRequest = 0
    @State private var workspaceBusy = false
    @State private var directCollage: ProjectEditorRequest?

    var body: some View {
        Group {
            if let project = library.currentProject {
                ProjectWorkspaceView(library: library, projectID: project.id,
                                     mode: $mode, homeRequest: homeRequest,
                                     navigationBusy: $workspaceBusy,
                                     initialRequest: nil, onReturnHome: { library.closeProject() })
                    .id(project.id)
            } else if let session = directCollage {
                DirectCollageWorkspaceView(persistentLibrary: library, request: session,
                                     mode: $mode, homeRequest: homeRequest,
                                     navigationBusy: $workspaceBusy, onReturnHome: {
                                         directCollage = nil
                                         mode = "library"
                                         workspaceBusy = false
                                     })
                    .id(session.id)
            } else {
                ProjectHomeView(library: library) { operation, urls in
                    mode = operation.rawValue
                    directCollage = ProjectEditorRequest(operation: operation, urls: urls, mode: .replace)
                }
            }
        }
        .environmentObject(materialNavigation)
        .frame(minWidth: 1020, minHeight: 740)
        .preferredColorScheme(theme == 2 ? .dark : .light)
        .background {
            ProjectWindowNavigation(
                selectedWorkspace: library.currentProject != nil || directCollage != nil ? mode : nil,
                workspaces: AppPreferences.workspaceOrder(from: storedWorkspaceOrder),
                homeEnabled: !workspaceBusy && !library.isImporting,
                navigationEnabled: !workspaceBusy && !library.isImporting,
                materialSelectionCount: mode == "library" ? materialNavigation.selectionCount : 0,
                onHome: { if library.currentProject != nil || directCollage != nil { homeRequest += 1 } },
                onSelectWorkspace: { workspace in
                    guard !workspaceBusy && !library.isImporting else { return }
                    mode = materialNavigation.selectWorkspace(workspace, from: mode)
                },
                onSettings: { openSettings() }
            ).frame(width: 0, height: 0)
        }
        .onChange(of: library.currentProject?.id) { _, _ in
            materialNavigation.reset()
            mode = "library"
            workspaceBusy = false
        }
        .onChange(of: directCollage?.id) { _, _ in materialNavigation.reset() }
        .onAppear {
            if directCollage == nil { ProjectLibraryLifecycle.library = library }
        }
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
    let onStartCollage: (ProjectOperation, [URL]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @State private var targetedOperation: ProjectOperation?
    @State private var isCreateHovered = false
    @State private var hoveredOperation: ProjectOperation?
    @State private var showsProjectFocus = false
    @State private var renamingProject: ProjectSummary?
    @State private var renamingText = ""
    @State private var deletingProject: ProjectSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("你的图片项目").font(.largeTitle.bold())
                Text("整理照片，或直接开始拼图。")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                createProjectCard
                directCollageCard
            }

            if library.projects.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 52, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("还没有图片项目").font(.title2.weight(.semibold))
                    Text("从左上方创建项目整理照片，也可以从右上方直接开始拼图。")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack {
                    Text("全部项目").font(.headline)
                    Spacer()
                    Text("双击打开 · 按创建时间排序")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                                onRepair: { repairProject(project) },
                                showsFocusRing: $showsProjectFocus
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
        .onKeyPress(.tab) {
            showsProjectFocus = true
            return .ignored
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
            Text("项目资料和预览缓存将移到废纸篓，原始位置的照片会保留。旧项目中已有的照片副本也会随项目移到废纸篓。")
        }
    }

    private var entryShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    private func entryHeading(symbol: String, title: String, subtitle: String,
                              isEmphasized: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .frame(width: 40)
                .foregroundStyle(Color.accentColor)
                .scaleEffect(isEmphasized && !reduceMotion ? 1.06 : 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func entryBackground(isTargeted: Bool = false, isHovered: Bool = false) -> some View {
        entryShape.fill(Color.accentColor.opacity(isTargeted ? 0.15 : (isHovered ? 0.09 : 0.05)))
            .overlay(entryShape.strokeBorder(Color.accentColor.opacity(isTargeted ? 1 : (isHovered ? 0.6 : 0.3)),
                                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
    }

    private var createProjectCard: some View {
        let hovered = isCreateHovered && !library.isImporting
        return Button(action: chooseProjectSources) {
            VStack(alignment: .leading, spacing: 18) {
                entryHeading(symbol: "folder.badge.plus",
                             title: isDropTargeted ? "松开，创建图片项目" : "创建图片项目",
                             subtitle: "先整理、选图和分组，再开始拼图",
                             isEmphasized: hovered || isDropTargeted)
                VStack(alignment: .leading, spacing: 5) {
                    Label("点击选择，或拖入文件夹 / 图片", systemImage: "square.and.arrow.down")
                        .font(.callout.weight(.medium))
                    Text("照片保留在原始位置").font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: 62, alignment: .leading)
            }
            .padding(22)
            .frame(maxWidth: .infinity).frame(height: 194)
            .background(entryBackground(isTargeted: isDropTargeted, isHovered: hovered))
            .contentShape(entryShape)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .disabled(library.isImporting)
        .onHover { isCreateHovered = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            createProjectFromDrop(urls)
        } isTargeted: { isDropTargeted = $0 }
    }

    private var directCollageCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            entryHeading(symbol: "photo.on.rectangle.angled", title: "直接开始拼图",
                         subtitle: "无需创建项目，进入后即可添加照片")
            HStack(spacing: 8) {
                ForEach(ProjectOperation.allCases) { operation in
                    directCollageButton(operation)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity).frame(height: 194)
        .background(entryBackground())
    }

    private func directCollageButton(_ operation: ProjectOperation) -> some View {
        let targeted = targetedOperation == operation
        let hovered = hoveredOperation == operation && !library.isImporting
        return Button { onStartCollage(operation, []) } label: {
            VStack(spacing: 6) {
                Image(systemName: operation.systemImage).font(.system(size: 19))
                    .scaleEffect((hovered || targeted) && !reduceMotion ? 1.06 : 1)
                Text(operation.title).font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity).frame(height: 62)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(targeted ? 0.18 : (hovered ? 0.11 : 0.06)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(targeted ? 1 : (hovered ? 0.55 : 0.2)), lineWidth: targeted ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        }
        .buttonStyle(.plain)
        .disabled(library.isImporting)
        .onHover { isHovered in
            if isHovered { hoveredOperation = operation }
            else if hoveredOperation == operation { hoveredOperation = nil }
        }
        .help("点击进入拼图，或将照片拖到这里")
        .dropDestination(for: URL.self) { urls, _ in
            startCollage(operation, urls: urls)
        } isTargeted: { isTargeted in
            if isTargeted { targetedOperation = operation }
            else if targetedOperation == operation { targetedOperation = nil }
        }
    }

    private func startCollage(_ operation: ProjectOperation, urls: [URL]) -> Bool {
        guard !library.isImporting, !urls.isEmpty else { return false }
        var seen: Set<URL> = []
        var photos: [URL] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let source = CGImageSourceCreateWithURL(url as CFURL,
                      [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0 else {
                library.message = "请选择可读取的图片文件。文件夹可以从左侧创建图片项目。"
                return false
            }
            if seen.insert(url.standardizedFileURL.resolvingSymlinksInPath()).inserted { photos.append(url) }
        }
        if let maximum = operation.maximumPhotoCount, photos.count > maximum {
            library.message = "\(operation.title)最多支持 \(maximum) 张照片，请重新选择。"
            return false
        }
        onStartCollage(operation, photos)
        return true
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
        return library.createProject(importing: files)
    }

    private func chooseProjectSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "创建项目"
        panel.message = "选择照片文件夹或多张图片创建项目。文件夹中的子文件夹也会一并读取，原图保留在原始位置。"
        if panel.runModal() == .OK { _ = createProjectFromDrop(panel.urls) }
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
    @Binding var showsFocusRing: Bool
    @FocusState private var isFocused: Bool

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverArea
            infoArea
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: cardShape)
        .clipShape(cardShape)
        .overlay {
            cardShape.strokeBorder(.quaternary).allowsHitTesting(false)
            if isFocused && showsFocusRing {
                cardShape.strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .contentShape(cardShape)
        .onTapGesture(count: 2, perform: onOpen)
        .simultaneousGesture(TapGesture().onEnded {
            showsFocusRing = true
            isFocused = true
        })
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) { onOpen(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.name)，共 \(project.assetCount) 张照片" +
                            (project.missingCount > 0 ? "，\(project.missingCount) 张缺图" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .help("双击打开项目素材")
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
                Text(project.createdAt, format: .dateTime.year().month().day().hour().minute()
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

private struct DirectCollageWorkspaceView: View {
    let persistentLibrary: ProjectLibraryStore
    let request: ProjectEditorRequest
    @Binding var mode: String
    let homeRequest: Int
    @Binding var navigationBusy: Bool
    let onReturnHome: () -> Void
    @StateObject private var library = ProjectLibraryStore(temporarySession: true)

    var body: some View {
        ProjectWorkspaceView(library: library, projectID: library.currentProject?.id,
                             mode: $mode, homeRequest: homeRequest,
                             navigationBusy: $navigationBusy, initialRequest: request,
                             onReturnHome: onReturnHome)
        .onAppear { ProjectLibraryLifecycle.library = library }
        .onDisappear {
            if ProjectLibraryLifecycle.library === library {
                ProjectLibraryLifecycle.library = persistentLibrary
            }
        }
        .alert("项目素材", isPresented: Binding(
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

private struct ProjectWorkspaceView: View {
    @ObservedObject var library: ProjectLibraryStore
    let projectID: UUID?
    @Binding var mode: String
    let homeRequest: Int
    @Binding var navigationBusy: Bool
    let initialRequest: ProjectEditorRequest?
    let onReturnHome: () -> Void
    @StateObject private var bridge = ProjectEditorBridge()
    @StateObject private var canvasStore = CanvasStore()
    @StateObject private var gridCollageStore = GridCollageStore()
    @State private var isMaterialDispatchPresented = false
    @State private var confirmsReturnHome = false
    @State private var didSendInitialRequest = false
    @AppStorage(AppPreferences.workspaceOrderKey) private var storedWorkspaceOrder = ""

    private var isBusy: Bool {
        library.isImporting || library.duplicateImportRequest != nil
            || bridge.activeExportCount > 0 || bridge.request != nil
            || bridge.statuses.values.contains(where: { $0.isBusy }) || isMaterialDispatchPresented
    }

    var body: some View {
        ZStack {
            if let projectID {
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
                .zIndex(mode == "library" ? 1 : 0)
                .allowsHitTesting(mode == "library")
                .disabled(mode != "library")
                .accessibilityHidden(mode != "library")
            }
            ForEach(AppPreferences.workspaceOrder(from: storedWorkspaceOrder)) { workspace in
                workspaceView(workspace)
                    .opacity(mode == workspace.rawValue ? 1 : 0)
                    .zIndex(mode == workspace.rawValue ? 1 : 0)
                    .allowsHitTesting(mode == workspace.rawValue)
                    .disabled(mode != workspace.rawValue)
                    .accessibilityHidden(mode != workspace.rawValue)
            }
        }
        .padding(8)
        .environmentObject(library)
        .environmentObject(bridge)
        .onAppear {
            if let request = initialRequest, !request.urls.isEmpty, !didSendInitialRequest {
                didSendInitialRequest = true
                if request.operation == .gridCollage { gridCollageStore.setSlotCount(request.urls.count) }
                bridge.send(operation: request.operation, urls: request.urls, mode: request.mode)
            }
            navigationBusy = isBusy
        }
        .onChange(of: isBusy) { _, busy in navigationBusy = busy }
        .onChange(of: homeRequest) { _, _ in requestHome() }
        .alert("返回项目首页？", isPresented: $confirmsReturnHome) {
            Button("继续编辑", role: .cancel) {}
            Button("返回首页", role: .destructive, action: returnHome)
        } message: {
            Text(library.isTemporarySession
                 ? "返回首页后将清空本次拼图和临时素材、照片组。原始照片会保留，请先导出需要保留的作品。"
                 : "当前有尚未导出的拼图，返回首页后将清空编辑器。项目素材、照片组和处理状态会自动保存。")
        }
    }

    private func requestHome() {
        guard !isBusy, library.currentProject?.id == projectID else { return }
        if bridge.statuses.values.contains(where: { $0.hasUnexportedChanges })
            || (library.isTemporarySession && library.currentProject?.activeAssets.isEmpty == false) {
            confirmsReturnHome = true
        } else {
            returnHome()
        }
    }

    private func returnHome() {
        guard !isBusy, library.currentProject?.id == projectID else { return }
        onReturnHome()
    }

    @ViewBuilder private func workspaceView(_ workspace: AppWorkspace) -> some View {
        switch workspace {
        case .freeCanvas: FreeCanvasView(store: canvasStore, isActive: mode == workspace.rawValue)
        case .longStitch: LongStitchView(isActive: mode == workspace.rawValue)
        case .gridCollage: GridCollageView(store: gridCollageStore, isActive: mode == workspace.rawValue)
        }
    }
}

/// Rebuilt on document edits, not on selection changes or thumbnail completions.
private struct ProjectMaterialCatalog {
    var assets: [ProjectAsset] = []
    var materialAssets: [ProjectAsset] = []
    var byID: [UUID: ProjectAsset] = [:]
    var badges: [UUID: String] = [:]

    init(_ document: ProjectDocument? = nil) {
        guard let document else { return }
        assets = document.orderedActiveAssets
        materialAssets = assets.filter { $0.groupID == nil }
        byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var counts: [UUID: [ProjectOperation: Int]] = [:]
        for record in document.exports {
            for id in Set(record.assetIDs) {
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
    let offersGrouping: Bool
}

private struct ProjectLibraryView: View {
    @ObservedObject var library: ProjectLibraryStore
    let projectID: UUID
    let isActive: Bool
    @Binding var isDispatchPresented: Bool
    let onSend: (ProjectOperation, [URL], ProjectImportMode) -> Bool
    @EnvironmentObject private var bridge: ProjectEditorBridge
    @EnvironmentObject private var materialNavigation: ProjectMaterialNavigation
    @AppStorage(AppPreferences.workspaceOrderKey) private var storedWorkspaceOrder = ""
    @AppStorage(AppPreferences.skipGroupingPromptKey) private var skipGroupingPrompt = false
    @AppStorage("projectLibrary.groupSidebarWidth") private var groupSidebarWidth = 340.0
    @State private var selection: Set<UUID> = []
    @State private var selectedGroupID: UUID?
    @State private var selectedWholeGroupID: UUID?
    @State private var groupSelection: Set<UUID> = []
    @State private var catalog = ProjectMaterialCatalog()
    @State private var dispatch: ProjectDispatch?
    @State private var draggedGroupID: UUID?
    @State private var groupDropInsertionIndex: Int?
    @State private var groupDropTargetID: UUID?
    @State private var assetDropTargetGroupID: UUID?
    @State private var isBlankGroupDropTarget = false

    private var showsModal: Bool { dispatch != nil }

    private var assets: [ProjectAsset] { catalog.assets }
    private var materialAssets: [ProjectAsset] { catalog.materialAssets }
    private var groups: [ProjectPhotoGroup] { library.currentProject?.groups ?? [] }
    private var activeSelection: Set<UUID> { selectedGroupID == nil ? selection : groupSelection }
    private var selectedAssets: [ProjectAsset] { orderedForDispatch(activeSelection) }
    private var selectedCount: Int { selectedAssets.count }
    private var assetURLs: [UUID: URL] {
        Dictionary(uniqueKeysWithValues: materialAssets.map { ($0.id, library.assetURL($0)) })
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
                        ProjectThumbnailRefresh(library: library, assets: materialAssets,
                                                isActive: isActive) { thumbnails, reportVisible in
                        ProjectMaterialBoard(
                            assets: materialAssets, selection: $selection,
                            thumbnailSize: CGFloat(library.currentProject?.thumbnailSize ?? 128),
                            viewZoom: .constant(1), fitRequest: 0,
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
                            onGather: { ids, _ in _ = createGroup(ids) },
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
                        if materialAssets.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: assets.isEmpty ? "photo.on.rectangle.angled" : "rectangle.stack")
                                    .font(.system(size: 36)).foregroundStyle(.secondary)
                                Text(assets.isEmpty ? "把照片或文件夹拖进来" : "这里显示未分组的照片")
                                    .font(.headline)
                                Text(assets.isEmpty ? "也可以点击上方「导入素材」" : "右侧照片可拖回这里，或按 Delete 移回素材")
                                    .foregroundStyle(.secondary)
                            }.allowsHitTesting(false)
                        }
                    }
            }
            Divider()
            HStack {
                Text(library.isTemporarySession ? "本次拼图素材（仅本次保留）" : (library.currentProject?.name ?? "项目"))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
                Text("·")
                Text("未分组 \(materialAssets.count) 张 · 项目共 \(assets.count) 张")
                Spacer()
                Text("空格预览 · 回车分组")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear {
            guard library.currentProject?.id == projectID else { return }
            refreshCatalog()
            library.boardViewZoom = 1
            publishSelectionCount()
        }
        .onChange(of: selectedCount) { _, _ in publishSelectionCount() }
        .onChange(of: isActive) { _, _ in publishSelectionCount() }
        .onDisappear { materialNavigation.reset() }
        .onChange(of: materialNavigation.request?.id) { _, _ in
            guard let request = materialNavigation.request else { return }
            materialNavigation.consumeRequest(id: request.id)
            prepareDispatch(request.operation, ids: activeSelection)
        }
        .onChange(of: library.currentProject?.modifiedAt) { _, _ in refreshCatalog() }
        .onChange(of: showsModal) { _, value in isDispatchPresented = value }
        .onChange(of: materialAssets.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
        .sheet(item: $dispatch) { request in
            ProjectDispatchSheet(operation: request.operation, assets: request.assets,
                                 offersGrouping: request.offersGrouping) { orderedAssets, importMode, shouldGroup, suppressPrompt in
                if onSend(request.operation, orderedAssets.map { library.assetURL($0) }, importMode) {
                    // Delay organization and preferences until all prompts are
                    // accepted. Cancelling never moves photos or hides guidance.
                    if shouldGroup { createGroup(Set(orderedAssets.map(\.id))) }
                    if suppressPrompt { skipGroupingPrompt = true }
                    dispatch = nil
                }
            }.environmentObject(bridge)
        }
    }

    private func publishSelectionCount() {
        materialNavigation.selectionCount = isActive ? selectedCount : 0
    }

    private var libraryToolbar: some View {
        ProjectMaterialToolbar(selectedCount: selectedCount, isImporting: library.isImporting,
                               onImport: library.importPanel) {
            thumbnailControls
        }
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

    private var groupPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("照片组").font(.headline)
                Text("\(groups.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text("拖到空白处建组").font(.caption).foregroundStyle(.secondary)
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
                                },
                                operations: operations
                            )
                            .id(group.id)
                            .overlay {
                                if assetDropTargetGroupID == group.id {
                                    ProjectPhotoGroupRow.outline
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                        if groups.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "rectangle.stack").font(.title)
                                Text("拖入一张或多张照片，新建一组")
                                Text("也可选中照片后按回车")
                                    .font(.caption)
                            }.foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                    }.padding(4).projectOverlayScrollbars()
                        .projectGroupBlankSelection(isActive: isActive && !showsModal,
                                                    onClearSelection: clearSelection)
                        .projectGroupBlankDrop(isActive: isActive && !showsModal,
                                               validAssetIDs: Set(assets.map(\.id)),
                                               onCreateGroup: createGroup,
                                               onTargetChange: { isBlankGroupDropTarget = $0 })
                }
                .onChange(of: selectedGroupID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .overlay(alignment: .bottom) {
                    if isBlankGroupDropTarget {
                        Label("松开新建照片组", systemImage: "plus.rectangle.on.rectangle")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    @discardableResult
    private func createGroup(_ ids: Set<UUID>) -> Bool {
        guard let id = library.createGroup(ids) else { return false }
        selection.subtract(ids)
        selectedGroupID = id
        selectedWholeGroupID = id
        groupSelection = ids
        return true
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
        guard isActive, !showsModal, !library.isImporting,
              library.currentProject?.id == projectID,
              bridge.request == nil, ProjectOperation.allCases.contains(operation) else { return }
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
        let offersGrouping = !skipGroupingPrompt && chosen.allSatisfy { $0.groupID == nil }
        if status.count == 0 && !offersGrouping {
            _ = onSend(operation, chosen.map { library.assetURL($0) }, .append)
        } else {
            dispatch = ProjectDispatch(operation: operation, assets: chosen, offersGrouping: offersGrouping)
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
