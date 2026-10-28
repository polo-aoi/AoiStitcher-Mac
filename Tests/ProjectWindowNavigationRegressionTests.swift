import AppKit

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
                    homeEnabled: Bool = true, navigationEnabled: Bool = true) {
            navigation.update(selectedWorkspace: selection, workspaces: order,
                              homeEnabled: homeEnabled, navigationEnabled: navigationEnabled,
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

        navigation.detach()
        try check(window.toolbar === originalToolbar && window.titleVisibility == .visible &&
                  window.toolbarStyle == .automatic,
                  "Detaching restores this window's original toolbar and title presentation")
        return checks
    }
}
