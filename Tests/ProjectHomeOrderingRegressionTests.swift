import Foundation

/// Opening and organizing projects must never change their creation-time order.
@MainActor enum ProjectHomeOrderingRegressionTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ProjectHomeOrderingRegressionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("aoi-home-order-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let older = ProjectDocument(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "旧项目",
                                    createdAt: Date(timeIntervalSince1970: 100), modifiedAt: Date(timeIntervalSince1970: 900),
                                    assets: [], exports: [], thumbnailSize: 128)
        let sameTime = ProjectDocument(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, name: "同时间项目",
                                       createdAt: older.createdAt, modifiedAt: Date(timeIntervalSince1970: 800),
                                       assets: [], exports: [], thumbnailSize: 128)
        let newer = ProjectDocument(id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!, name: "新项目",
                                    createdAt: Date(timeIntervalSince1970: 200), modifiedAt: Date(timeIntervalSince1970: 300),
                                    assets: [], exports: [], thumbnailSize: 128)
        for project in [sameTime, older, newer] {
            let directory = root.appendingPathComponent(project.id.uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(project).write(to: directory.appendingPathComponent("project.json"))
        }
        let expected = [newer.id, older.id, sameTime.id]
        let library = ProjectLibraryStore(projectsDirectory: root)
        try check(library.projects.map(\.id) == expected,
                  "Projects sort by creation time even when the oldest was modified most recently")
        try check(library.projects.map(\.createdAt) == [newer.createdAt, older.createdAt, sameTime.createdAt],
                  "The summary exposes creation times for the date displayed on each home card")

        let olderMetadata = root.appendingPathComponent(older.id.uuidString + "/project.json")
        let beforeOpen = try Data(contentsOf: olderMetadata)
        library.openProject(id: older.id)
        try check(library.currentProject?.id == older.id && library.currentProject?.modifiedAt == older.modifiedAt,
                  "Opening an old project does not mark its content as modified")
        library.closeProject()
        let afterOpen = try Data(contentsOf: olderMetadata)
        try check(library.projects.map(\.id) == expected && beforeOpen == afterOpen,
                  "Returning home after viewing leaves both card positions and stored metadata unchanged")

        library.renameProject(id: older.id, to: "旧项目新名称")
        try check(library.flushPendingSaves(), "A project rename is saved successfully")
        try check(library.projects.map(\.id) == expected && library.projects[1].name == "旧项目新名称",
                  "Renaming updates the card in place without moving it above newer projects")
        library.openProject(id: older.id)
        library.setThumbnailSize(96)
        try check(library.flushPendingSaves(), "A real project edit is saved successfully")
        try check(library.currentProject?.thumbnailSize == 96 && library.currentProject?.createdAt == older.createdAt &&
                  library.currentProject?.modifiedAt != older.modifiedAt,
                  "Real edits update modification time while retaining the original creation time")
        library.closeProject()
        try check(library.projects.map(\.id) == expected,
                  "Returning home after an edit keeps the creation-time order")
        library.refreshProjects()
        try check(library.projects.map(\.id) == expected,
                  "Refreshing the home catalog uses the same deterministic creation-time order")
        let reopened = ProjectLibraryStore(projectsDirectory: root)
        try check(reopened.projects.map(\.id) == expected && reopened.projects[1].name == "旧项目新名称",
                  "A new store restores the same order, including projects sharing a creation timestamp")
        reopened.openProject(id: sameTime.id)
        reopened.closeProject()
        reopened.refreshProjects()
        try check(reopened.projects.map(\.id) == expected,
                  "Opening an equal-time project does not change the stable UUID tie-break order")

        try check(reopened.createProject(name: "刚创建的项目"), "A new project can be created after restoring the catalog")
        let addedID = reopened.currentProject!.id
        reopened.closeProject()
        try check(reopened.projects.map(\.id) == [addedID] + expected,
                  "Only creating a newer project inserts a new card before the existing projects")
        return checks
    }
}
