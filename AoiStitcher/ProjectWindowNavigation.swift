import AppKit
import SwiftUI

/// Installs one native toolbar for the main window. AppKit keeps the window
/// buttons, dragging and full-screen behavior; the workspace item is centered
/// against the entire window, independently of the Home and Settings buttons.
struct ProjectWindowNavigation: NSViewRepresentable {
    var selectedWorkspace: String?
    var workspaces: [AppWorkspace]
    var homeEnabled: Bool
    var navigationEnabled = true
    var showsProjectMaterials = true
    var onHome: () -> Void
    var onSelectWorkspace: (String) -> Void
    var onSettings: () -> Void = {}

    func makeCoordinator() -> ProjectWindowNavigationController {
        ProjectWindowNavigationController()
    }

    func makeNSView(context: Context) -> ProjectWindowNavigationAnchor {
        let view = ProjectWindowNavigationAnchor()
        view.controller = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ProjectWindowNavigationAnchor, context: Context) {
        context.coordinator.update(selectedWorkspace: selectedWorkspace, workspaces: workspaces,
                                   homeEnabled: homeEnabled, navigationEnabled: navigationEnabled,
                                   showsProjectMaterials: showsProjectMaterials,
                                   onHome: onHome, onSelectWorkspace: onSelectWorkspace,
                                   onSettings: onSettings)
        if let window = view.window { context.coordinator.attach(to: window) }
    }

    static func dismantleNSView(_ view: ProjectWindowNavigationAnchor,
                               coordinator: ProjectWindowNavigationController) {
        view.controller = nil
        coordinator.detach()
    }
}

@MainActor final class ProjectWindowNavigationAnchor: NSView {
    weak var controller: ProjectWindowNavigationController?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { controller?.attach(to: window) }
        else { controller?.detach() }
    }
}

@MainActor final class ProjectWindowNavigationController: NSObject, NSToolbarDelegate {
    static let homeIdentifier = NSToolbarItem.Identifier("com.aoistitcher.navigation.home")
    static let workspaceIdentifier = NSToolbarItem.Identifier("com.aoistitcher.navigation.workspaces")
    static let settingsIdentifier = NSToolbarItem.Identifier("com.aoistitcher.navigation.settings")

    let toolbar = NSToolbar(identifier: "com.aoistitcher.navigation")
    let homeButton = NSButton()
    let workspaceControl = NSSegmentedControl()
    let settingsButton = NSButton()
    private let homeItem = NSToolbarItem(itemIdentifier: homeIdentifier)
    private let workspaceItem = NSToolbarItem(itemIdentifier: workspaceIdentifier)
    private let settingsItem = NSToolbarItem(itemIdentifier: settingsIdentifier)
    private weak var installedWindow: NSWindow?
    private var previousToolbar: NSToolbar?
    private var previousTitleVisibility = NSWindow.TitleVisibility.visible
    private var previousToolbarStyle = NSWindow.ToolbarStyle.automatic
    private var selectedWorkspace: String?
    private var workspaceIDs: [String] = []
    private var onHome: (() -> Void)?
    private var onSelectWorkspace: ((String) -> Void)?
    private var onSettings: (() -> Void)?

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifiers = [Self.workspaceIdentifier]

        homeButton.setButtonType(.momentaryPushIn)
        homeButton.bezelStyle = .texturedRounded
        homeButton.isBordered = false
        homeButton.imagePosition = .imageOnly
        homeButton.imageScaling = .scaleProportionallyDown
        homeButton.target = self
        homeButton.action = #selector(chooseHome)
        homeButton.toolTip = "返回项目首页"
        homeButton.setAccessibilityLabel("项目首页")
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            homeButton.widthAnchor.constraint(equalToConstant: 32),
            homeButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        homeItem.view = homeButton
        homeItem.label = "项目首页"
        homeItem.paletteLabel = "项目首页"
        homeItem.isNavigational = true
        homeItem.autovalidates = false
        homeItem.visibilityPriority = .high

        workspaceControl.trackingMode = .selectOne
        workspaceControl.segmentStyle = .texturedRounded
        workspaceControl.font = .systemFont(ofSize: 13, weight: .medium)
        workspaceControl.target = self
        workspaceControl.action = #selector(chooseWorkspace)
        workspaceControl.setAccessibilityLabel("工作区")
        workspaceItem.view = workspaceControl
        workspaceItem.label = "工作区"
        workspaceItem.paletteLabel = "工作区"
        workspaceItem.autovalidates = false
        workspaceItem.visibilityPriority = .high

        settingsButton.setButtonType(.momentaryPushIn)
        settingsButton.bezelStyle = .texturedRounded
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.imageScaling = .scaleProportionallyDown
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(chooseSettings)
        settingsButton.toolTip = "软件设置"
        settingsButton.setAccessibilityLabel("软件设置")
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            settingsButton.widthAnchor.constraint(equalToConstant: 32),
            settingsButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        settingsItem.view = settingsButton
        settingsItem.label = "软件设置"
        settingsItem.paletteLabel = "软件设置"
        settingsItem.autovalidates = false
        settingsItem.visibilityPriority = .high
    }

    func update(selectedWorkspace: String?, workspaces: [AppWorkspace],
                homeEnabled: Bool, navigationEnabled: Bool,
                showsProjectMaterials: Bool = true,
                onHome: @escaping () -> Void, onSelectWorkspace: @escaping (String) -> Void,
                onSettings: @escaping () -> Void = {}) {
        self.selectedWorkspace = selectedWorkspace
        self.onHome = onHome
        self.onSelectWorkspace = onSelectWorkspace
        self.onSettings = onSettings
        homeButton.isEnabled = homeEnabled
        homeItem.isEnabled = homeEnabled
        homeButton.image = NSImage(systemSymbolName: selectedWorkspace == nil ? "house.fill" : "house",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        homeButton.contentTintColor = selectedWorkspace == nil ? .labelColor : .secondaryLabelColor
        workspaceControl.isEnabled = navigationEnabled
        workspaceItem.isEnabled = navigationEnabled

        let ids = (showsProjectMaterials ? ["library"] : []) + workspaces.map(\.rawValue)
        if workspaceIDs != ids {
            workspaceIDs = ids
            workspaceControl.segmentCount = ids.count
            let labels = (showsProjectMaterials ? ["项目素材"] : []) + workspaces.map(\.title)
            let symbols = (showsProjectMaterials ? ["square.grid.3x3"] : []) + workspaces.map(\.systemImage)
            for index in ids.indices {
                workspaceControl.setLabel(labels[index], forSegment: index)
                workspaceControl.setToolTip(labels[index], forSegment: index)
                let image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
                workspaceControl.setImage(image, forSegment: index)
                workspaceControl.setImageScaling(.scaleProportionallyDown, forSegment: index)
                workspaceControl.setWidth(116, forSegment: index)
            }
        }
        workspaceControl.selectedSegment = selectedWorkspace.flatMap { ids.firstIndex(of: $0) } ?? -1
        updateItems()
    }

    func attach(to window: NSWindow) {
        guard installedWindow !== window else { return }
        detach()
        installedWindow = window
        previousToolbar = window.toolbar
        previousTitleVisibility = window.titleVisibility
        previousToolbarStyle = window.toolbarStyle
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        toolbar.isVisible = true
    }

    func detach() {
        // A new SwiftUI root can install its toolbar before the old root is
        // dismantled. Never remove or restyle that newer owner's toolbar.
        if let window = installedWindow, window.toolbar === toolbar {
            window.toolbar = previousToolbar
            window.titleVisibility = previousTitleVisibility
            window.toolbarStyle = previousToolbarStyle
        }
        installedWindow = nil
        previousToolbar = nil
    }

    private func updateItems() {
        guard installedWindow != nil else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.workspaceIdentifier }
        if selectedWorkspace == nil {
            if let index { toolbar.removeItem(at: index) }
        } else if index == nil {
            toolbar.insertItem(withItemIdentifier: Self.workspaceIdentifier, at: min(2, toolbar.items.count))
        }
    }

    @objc private func chooseHome() {
        guard homeButton.isEnabled else { return }
        onHome?()
    }

    @objc private func chooseWorkspace() {
        let index = workspaceControl.selectedSegment
        guard workspaceControl.isEnabled, workspaceIDs.indices.contains(index) else { return }
        onSelectWorkspace?(workspaceIDs[index])
    }

    @objc private func chooseSettings() {
        onSettings?()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        selectedWorkspace == nil
            ? [Self.homeIdentifier, .flexibleSpace, .flexibleSpace, Self.settingsIdentifier]
            : [Self.homeIdentifier, .flexibleSpace, Self.workspaceIdentifier, .flexibleSpace, Self.settingsIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.homeIdentifier, .flexibleSpace, Self.workspaceIdentifier, Self.settingsIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.homeIdentifier: homeItem
        case Self.workspaceIdentifier: workspaceItem
        case Self.settingsIdentifier: settingsItem
        default: nil
        }
    }
}
