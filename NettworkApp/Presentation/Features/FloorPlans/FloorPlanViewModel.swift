import ContentSafety
import CoreGraphics
import FeatureContracts
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
@Observable
final class FloorPlanViewModel {
    enum AttachmentOperation: Equatable {
        case inspecting
        case sanitizing
        case rendering
        case stagingWorkOrder
        case binding
        case cleaningUp
    }

    let floorID: ObjectID
    var anchors: [FloorPlanAnchor]
    var labels: [ObjectID: String]
    var searchText = ""
    var visibleLayers: Set<FloorPlanLayer> = Set(FloorPlanLayer.allCases)
    var selectedPDFPage = 0
    var attachmentState: FloorPlanAttachmentState = .idle
    var previewState: FloorPlanPreviewState = .idle
    var assetWorkOrderID: ObjectID?
    var assetBindingReceipt: OperationReceipt?
    var assetActionError: String?
    var anchorActionError: String?
    var pendingAnchorWorkOrderIDs: Set<ObjectID> = []
    var stagedDescriptor: SanitizedContentDescriptor?
    let service: any FloorPlanFeatureService
    let onStagedWorkOrder: @MainActor (ObjectID) async -> Void
    var pendingPDFSource: (any OpaqueContentSource)?
    /// One generation owns the opaque source and any descriptor it produces.
    /// Completion from an earlier generation must never republish over a newer
    /// import, persisted preview, or cleanup result.
    var attachmentGeneration: UUID?
    var attachmentOperation: AttachmentOperation?
    var previewGeneration = UUID()
    var anchorActionGeneration: UUID?

    init(
        floorID: ObjectID,
        anchors: [FloorPlanAnchor] = [],
        labels: [ObjectID: String] = [:],
        service: any FloorPlanFeatureService,
        onStagedWorkOrder: @escaping @MainActor (ObjectID) async -> Void = { _ in }
    ) {
        self.floorID = floorID
        self.anchors = anchors
        self.labels = labels
        self.service = service
        self.onStagedWorkOrder = onStagedWorkOrder
    }

    var filteredAnchors: [FloorPlanAnchor] {
        anchors.filter { anchor in
            guard visibleLayers.contains(.anchor) else { return false }
            return searchText.isEmpty || (labels[anchor.objectID] ?? anchor.objectID.description).localizedCaseInsensitiveContains(searchText)
        }
    }
    var canBeginAttachmentImport: Bool {
        stagedDescriptor == nil && pendingPDFSource == nil && attachmentOperation == nil
    }

    var isAttachmentOperationInFlight: Bool { attachmentOperation != nil }
    var isAnchorActionInFlight: Bool { anchorActionGeneration != nil }

    var canRetryAttachmentPreview: Bool {
        guard stagedDescriptor != nil, attachmentOperation == nil else { return false }
        switch previewState {
        case .cancelled, .failed:
            return true
        case .idle, .loading, .rendered:
            return false
        }
    }
}
