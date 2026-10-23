import Foundation
import Combine
import AppKit

nonisolated struct ProjectEditorRequest: Identifiable {
    let id = UUID()
    let operation: ProjectOperation
    let urls: [URL]
    let mode: ProjectImportMode
}

nonisolated struct ProjectEditorStatus: Equatable {
    var count = 0
    var hasUnexportedChanges = false
    var isBusy = false
}

/// Tracks the actual composition independently of the project's export history.
@MainActor
final class ProjectEditorBridge: ObservableObject {
    @Published private(set) var request: ProjectEditorRequest?
    @Published private(set) var statuses: [ProjectOperation: ProjectEditorStatus] = [:]
    @Published private(set) var activeExportCount = 0
    private var signatures: [ProjectOperation: String] = [:]
    private var exportedSignatures: [ProjectOperation: String] = [:]
    private var subscriptions: [ProjectOperation: AnyCancellable] = [:]
    private var observedStores: [ProjectOperation: ObjectIdentifier] = [:]

    func observeCanvas(_ store: CanvasStore) {
        guard observedStores[.freeCanvas] != ObjectIdentifier(store) else { return }
        observedStores[.freeCanvas] = ObjectIdentifier(store)
        subscriptions[.freeCanvas] = store.$document
            .combineLatest(store.$isLoading, store.$isExporting)
            .sink { [weak self] document, loading, exporting in
                self?.update(operation: .freeCanvas, count: document.layers.count,
                    signature: ProjectCompositionSignature.canvas(CanvasRenderSnapshot(document)),
                    isBusy: loading || exporting)
            }
    }

    func observeGrid(_ store: GridCollageStore) {
        guard observedStores[.gridCollage] != ObjectIdentifier(store) else { return }
        observedStores[.gridCollage] = ObjectIdentifier(store)
        subscriptions[.gridCollage] = store.$state
            .combineLatest(store.$isLoading, store.$isExporting)
            .sink { [weak self] state, loading, exporting in
                self?.update(operation: .gridCollage, count: state.orderedSlots.filter(\.hasImage).count,
                    signature: ProjectCompositionSignature.grid(state), isBusy: loading || exporting)
            }
    }

    func status(for operation: ProjectOperation) -> ProjectEditorStatus {
        statuses[operation] ?? ProjectEditorStatus()
    }

    func update(operation: ProjectOperation, count: Int, signature: String, isBusy: Bool) {
        signatures[operation] = signature
        let next = ProjectEditorStatus(count: count,
            hasUnexportedChanges: count > 0 && exportedSignatures[operation] != signature,
            isBusy: isBusy)
        if statuses[operation] != next { statuses[operation] = next }
    }

    func didExport(operation: ProjectOperation, signature: String) {
        exportedSignatures[operation] = signature
        let current = status(for: operation)
        update(operation: operation, count: current.count,
               signature: signatures[operation] ?? "", isBusy: current.isBusy)
    }

    @discardableResult
    func send(operation: ProjectOperation, urls: [URL], mode: ProjectImportMode = .append) -> Bool {
        let current = status(for: operation)
        guard !urls.isEmpty, request == nil, !current.isBusy else { return false }
        let resultingCount = (mode == .append ? current.count : 0) + urls.count
        if let maximum = operation.maximumPhotoCount, resultingCount > maximum { return false }
        request = ProjectEditorRequest(operation: operation, urls: urls, mode: mode)
        return true
    }

    func consume(id: UUID) {
        guard request?.id == id else { return }
        request = nil
    }

    func beginExport() { activeExportCount += 1 }
    func endExport() { activeExportCount = max(0, activeExportCount - 1) }
}

/// Session-local signatures include output-affecting state only. Keeping image
/// identities avoids repeatedly encoding full-resolution pixels while dragging.
@MainActor enum ProjectCompositionSignature {
    static func canvas(_ snapshot: CanvasRenderSnapshot) -> String {
        var hash = Hasher()
        hash.combine(String(describing: snapshot.size))
        hash.combine(String(describing: snapshot.background))
        hash.combine(snapshot.sourceURLs)
        for layer in snapshot.layers {
            hash.combine(layer.image.map(ObjectIdentifier.init))
            hash.combine(layer.texture.map(ObjectIdentifier.init))
            hash.combine(String(describing: layer.center))
            hash.combine(String(describing: layer.size))
            hash.combine(layer.rotation); hash.combine(layer.opacity)
            hash.combine(String(describing: layer.color))
        }
        return String(hash.finalize())
    }

    static func grid(_ state: CollageState) -> String {
        var hash = Hasher()
        hash.combine(state.aspectRatio.rawValue)
        hash.combine(String(reflecting: state.rootNode))
        hash.combine(state.style.gap); hash.combine(state.style.padding)
        hash.combine(state.style.borderRadius)
        hash.combine(String(describing: state.style.backgroundColor))
        hash.combine(state.style.backgroundImageURL)
        hash.combine(state.style.backgroundImage.map(ObjectIdentifier.init))
        for slot in state.orderedSlots {
            hash.combine(slot.id); hash.combine(slot.imageURL); hash.combine(slot.editedImageURL)
            hash.combine(slot.image.map(ObjectIdentifier.init))
            hash.combine(slot.previewImage.map(ObjectIdentifier.init))
            hash.combine(String(describing: slot.transform)); hash.combine(slot.fill.rawValue)
            if let recipe = slot.editRecipe {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                hash.combine(try? encoder.encode(recipe))
            }
        }
        return String(hash.finalize())
    }

    static func longStitch(_ images: [StitchItem], settings: LongStitchSettings) -> String {
        var hash = Hasher()
        var outputSettings = settings
        outputSettings.panMode = .rightMouse; outputSettings.panKey = .space
        outputSettings.zoomModifier = .option; outputSettings.wheelMode = .zoom
        outputSettings.zoomSensitivity = 1
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        hash.combine(try? encoder.encode(outputSettings))
        for item in images {
            hash.combine(item.url)
            hash.combine(ObjectIdentifier(item.displayImage))
            hash.combine(String(describing: item.cropInfo))
            for watermark in item.watermarks {
                hash.combine(ObjectIdentifier(watermark.image))
                hash.combine(String(describing: watermark.offset))
                hash.combine(watermark.scale); hash.combine(watermark.rotation)
            }
        }
        return String(hash.finalize())
    }
}
