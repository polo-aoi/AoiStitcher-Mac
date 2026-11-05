import Foundation
import Combine

/// Keeps the library visible until its selected photos have passed the import
/// prompts. A request is consumed once, even when the same tool is clicked again.
@MainActor final class ProjectMaterialNavigation: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let operation: ProjectOperation
    }

    @Published var selectionCount = 0
    @Published private(set) var request: Request?

    func selectWorkspace(_ workspace: String, from currentWorkspace: String) -> String {
        guard workspace == "library" || AppWorkspace(rawValue: workspace) != nil else {
            return currentWorkspace
        }
        guard currentWorkspace == "library", selectionCount > 0,
              let operation = ProjectOperation(rawValue: workspace) else { return workspace }
        if request == nil { request = Request(operation: operation) }
        return currentWorkspace
    }

    func consumeRequest(id: UUID) {
        guard request?.id == id else { return }
        request = nil
    }

    func reset() {
        selectionCount = 0
        request = nil
    }
}
