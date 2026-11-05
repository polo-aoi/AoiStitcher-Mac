import AppKit
import QuartzCore

/// Real native toolbar layout in a window that is never ordered on screen.
/// No screen capture, user project, or interactive window session is involved.
@MainActor enum ProjectWindowNavigationRegressionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectWindowNavigationRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1020, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.title = "AoiStitcher"
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        let initialMask = window.styleMask
        let initialBehavior = window.collectionBehavior
        let originalToolbar = NSToolbar(identifier: "navigation-regression-original")
        window.toolbar = originalToolbar

        let navigation = ProjectWindowNavigationController()
        var homes = 0
        var chosen: [String] = []
        func update(_ selection: String?, order: [AppWorkspace] = AppWorkspace.allCases,
                    homeEnabled: Bool = true, navigationEnabled: Bool = true,
                    selectedCount: Int = 0) {
            navigation.update(selectedWorkspace: selection, workspaces: order,
                              homeEnabled: homeEnabled, navigationEnabled: navigationEnabled,
                              materialSelectionCount: selectedCount,
                              onHome: { homes += 1 }, onSelectWorkspace: { chosen.append($0) })
        }
        func settle() {
            for _ in 0..<3 {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            window.contentView?.superview?.layoutSubtreeIfNeeded()
        }

        update("library")
        navigation.attach(to: window)
        try check(window.toolbar === navigation.toolbar && window.titleVisibility == .hidden,
                  "The main window uses the native navigation toolbar with its app title hidden")
        try check(window.title == "AoiStitcher" && window.styleMask == initialMask &&
                  window.collectionBehavior == initialBehavior,
                  "Navigation preserves window identity, standard controls and full-screen behavior")
        try check(navigation.toolbar.centeredItemIdentifiers == [ProjectWindowNavigationController.workspaceIdentifier],
                  "The workspace group is the toolbar's centered native item")

        for width: CGFloat in [1020, 1280, 1920] {
            window.setContentSize(CGSize(width: width, height: 740))
            settle()
            let group = navigation.workspaceControl
            let groupRect = group.convert(group.bounds, to: nil)
            let homeRect = navigation.homeButton.convert(navigation.homeButton.bounds, to: nil)
            try check(group.window === window && groupRect.width > 400 &&
                      abs(groupRect.midX - window.frame.width / 2) <= 0.5,
                      "At \(Int(width)) pt the four workspaces are centered against the entire window: \(groupRect)")
            guard let zoom = window.standardWindowButton(.zoomButton) else {
                throw NSError(domain: "ProjectWindowNavigationRegressionTests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Missing native window controls"])
            }
            let zoomRect = zoom.convert(zoom.bounds, to: nil)
            try check(homeRect.minX >= zoomRect.maxX + 4 && homeRect.maxX < groupRect.minX,
                      "At \(Int(width)) pt Home follows the traffic lights without overlapping navigation")
            try check(abs(homeRect.midY - zoomRect.midY) <= 1 && abs(groupRect.midY - homeRect.midY) <= 1,
                      "At \(Int(width)) pt traffic lights, Home and workspaces share one row")
            try check(!window.isVisible, "Layout checks never display the test window")
        }

        navigation.homeButton.performClick(nil)
        try check(homes == 1, "Home invokes the supplied project-home action")
        let control = navigation.workspaceControl
        for (index, id) in (["library"] + AppWorkspace.allCases.map(\.rawValue)).enumerated() {
            control.selectedSegment = index
            _ = control.sendAction(control.action, to: control.target)
            try check(chosen.last == id, "Native workspace selection routes \(id)")
        }

        let reordered: [AppWorkspace] = [.longStitch, .gridCollage, .freeCanvas]
        update("freeCanvas", order: reordered)
        settle()
        try check(control.selectedSegment == 3 && control.label(forSegment: 1) == "长图拼接",
                  "Saved workspace order updates labels and selection together")
        control.selectedSegment = 1
        _ = control.sendAction(control.action, to: control.target)
        try check(chosen.last == "longStitch", "Reordered controls route by workspace identity")

        let previousChoices = chosen.count
        update("library", homeEnabled: false, navigationEnabled: false)
        navigation.homeButton.performClick(nil)
        control.selectedSegment = 2
        _ = control.sendAction(control.action, to: control.target)
        try check(homes == 1 && chosen.count == previousChoices,
                  "Busy or modal states disable both native navigation callbacks")

        let toolbarIdentity = ObjectIdentifier(navigation.toolbar)
        update(nil)
        settle()
        try check(navigation.toolbar.items.allSatisfy {
            $0.itemIdentifier != ProjectWindowNavigationController.workspaceIdentifier
        } && navigation.homeButton.window === window,
                  "The project homepage keeps Home and removes workspace navigation")
        update("gridCollage")
        settle()
        try check(ObjectIdentifier(navigation.toolbar) == toolbarIdentity &&
                  navigation.toolbar.items.filter {
                    $0.itemIdentifier == ProjectWindowNavigationController.workspaceIdentifier
                  }.count == 1 && control.selectedSegment == 1,
                  "Opening a project reuses the toolbar and inserts exactly one workspace group")
        let restoredRect = control.convert(control.bounds, to: nil)
        try check(abs(restoredRect.midX - window.frame.width / 2) <= 0.5,
                  "Navigation stays centered after returning from the homepage")

        update("library", order: reordered, selectedCount: 3)
        settle()
        try check(control.selectedSegment == 0,
                  "The toolbar keeps the current workspace selected when photos are selected")
        try check(control.toolTip(forSegment: 1) == "将选中的 3 张照片带入长图拼接",
                  "Destination hints track photo count and customized workspace order")
        func outlines() -> [CAShapeLayer] {
            control.layer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        }
        try check(outlines().isEmpty,
                  "Selected photos do not add custom destination outlines to the native toolbar")
        update("library", order: reordered, selectedCount: 5)
        try check(control.toolTip(forSegment: 1) == "将选中的 5 张照片带入长图拼接" && outlines().isEmpty,
                  "Changing the selection updates the hint without adding toolbar decoration")
        control.selectedSegment = 2
        _ = control.sendAction(control.action, to: control.target)
        try check(chosen.last == "gridCollage" && control.selectedSegment == 0,
                  "A destination click requests import without falsely selecting the editor before confirmation")
        update("freeCanvas", selectedCount: 5)
        try check(control.selectedSegment == 2 && outlines().isEmpty,
                  "Entering an editor uses only the native selected-workspace treatment")
        update("library", selectedCount: 0)
        try check(outlines().isEmpty && control.toolTip(forSegment: 1) == "标准拼图",
                  "Clearing selection restores ordinary workspace navigation hints")

        let materialNavigation = ProjectMaterialNavigation()
        for workspace in AppWorkspace.allCases {
            try check(materialNavigation.selectWorkspace(workspace.rawValue, from: "library") == workspace.rawValue
                      && materialNavigation.request == nil,
                      "Without photos, \(workspace.title) opens as ordinary navigation")
        }
        materialNavigation.selectionCount = 3
        for workspace in AppWorkspace.allCases {
            try check(materialNavigation.selectWorkspace(workspace.rawValue, from: "library") == "library",
                      "With selected photos, \(workspace.title) waits for the import flow")
            guard let request = materialNavigation.request else {
                throw NSError(domain: "ProjectWindowNavigationRegressionTests", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Missing material navigation request"])
            }
            try check(request.operation.rawValue == workspace.rawValue,
                      "The selected-photo request uses workspace identity, independent of display order")
            _ = materialNavigation.selectWorkspace("longStitch", from: "library")
            try check(materialNavigation.request?.id == request.id,
                      "Repeated clicks do not replace a pending import request")
            materialNavigation.consumeRequest(id: UUID())
            try check(materialNavigation.request?.id == request.id,
                      "A stale consumer cannot clear the current import request")
            materialNavigation.consumeRequest(id: request.id)
            try check(materialNavigation.request == nil && materialNavigation.selectionCount == 3,
                      "Consuming a request preserves the selected photos for cancellation or retry")
            _ = materialNavigation.selectWorkspace(workspace.rawValue, from: "library")
            try check(materialNavigation.request?.id != request.id,
                      "Clicking the same destination after cancellation creates a fresh request")
            materialNavigation.consumeRequest(id: materialNavigation.request!.id)
        }
        try check(materialNavigation.selectWorkspace("longStitch", from: "freeCanvas") == "longStitch"
                  && materialNavigation.request == nil,
                  "Switching between editors never resends a retained material selection")
        try check(materialNavigation.selectWorkspace("library", from: "library") == "library"
                  && materialNavigation.request == nil,
                  "Clicking the current library segment does not dispatch photos")
        for invalid in ["compression", "unknown"] {
            try check(materialNavigation.selectWorkspace(invalid, from: "library") == "library"
                      && materialNavigation.request == nil,
                      "Retired or unknown destinations cannot receive selected photos")
        }
        _ = materialNavigation.selectWorkspace("gridCollage", from: "library")
        materialNavigation.reset()
        try check(materialNavigation.selectionCount == 0 && materialNavigation.request == nil,
                  "Leaving a project or temporary session discards its selection and pending navigation")

        let domain = "aoistitcher.grouping-guidance-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        try check(!defaults.bool(forKey: AppPreferences.skipGroupingPromptKey),
                  "New users see grouping guidance by default")
        try check(!defaults.bool(forKey: AppPreferences.materialSelectionHintDismissedKey),
                  "Selection guidance is available until the user dismisses it")
        defaults.set(true, forKey: AppPreferences.skipGroupingPromptKey)
        defaults.set(true, forKey: AppPreferences.materialSelectionHintDismissedKey)
        try check(UserDefaults(suiteName: domain)!.bool(forKey: AppPreferences.skipGroupingPromptKey),
                  "The opt-out preference survives reopening preferences")
        AppPreferences.restoreDefaults(in: defaults)
        try check(!defaults.bool(forKey: AppPreferences.skipGroupingPromptKey),
                  "Restoring application defaults can bring grouping guidance back")
        try check(!defaults.bool(forKey: AppPreferences.materialSelectionHintDismissedKey),
                  "Restoring application defaults can bring selection guidance back")

        navigation.detach()
        try check(window.toolbar === originalToolbar && window.titleVisibility == .visible &&
                  window.toolbarStyle == .automatic,
                  "Detaching restores this window's original toolbar and title presentation")
        return checks
    }
}
