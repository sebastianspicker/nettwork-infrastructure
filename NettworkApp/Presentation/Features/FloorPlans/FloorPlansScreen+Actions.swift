import ContentSafety
import NetworkModel
import SwiftUI
import WorkspaceChangeControl

extension FloorPlansScreen {
    func requestAttachmentImport() {
        guard let source = importSource?(), let context = attachmentAuthorization?() else { return }
        Task {
            await model.beginAttachmentImport(
                source: source,
                authorization: context,
                previewAuthorization: { previewAuthorization?() }
            )
        }
    }

    func requestSelectedPDFPageSanitization() {
        guard let context = attachmentAuthorization?() else { return }
        Task {
            await model.sanitizeSelectedPDFPage(
                authorization: context,
                previewAuthorization: { previewAuthorization?() }
            )
        }
    }

    func requestAttachmentCleanup() {
        guard let context = attachmentAuthorization?() else { return }
        Task { await model.cleanupAttachment(authorization: context) }
    }

    func requestAttachmentPreviewRetry() {
        guard let context = previewAuthorization?() else { return }
        Task { await model.retryAttachmentPreview(authorization: context) }
    }

    func requestAssetWorkOrder() {
        Task { await model.stageAssetWorkOrder(authorization: authorization) }
    }

    func requestAssetBinding() {
        guard let context = attachmentAuthorization?() else { return }
        Task { await model.bindAsset(authorization: context) }
    }

    func addAnchor() {
        guard let uuid = UUID(uuidString: newObjectID) else { return }
        newObjectID = ""
        Task { await model.addAnchor(for: ObjectID(uuid), authorization: authorization) }
    }

    func addSelectedAnchor() {
        guard let object = selectedAnchorObject else { return }
        selectedAnchorObject = nil
        Task { await model.addAnchor(for: object.id, authorization: authorization) }
    }

    func removeAnchor(_ anchor: FloorPlanAnchor) {
        Task { await model.remove(anchor: anchor, authorization: authorization) }
    }

    func floorPlanAttachmentStatus(_ state: FloorPlanAttachmentState) -> String {
        switch state {
        case .idle: "Floor plan attachment is idle."
        case .inspectingPDF: "Inspecting PDF pages safely."
        case .awaitingPDFPageSelection(let inspection): "Choose one of \(inspection.pageCount) PDF pages to sanitize."
        case .sanitizing: "Sanitizing the untrusted floor plan attachment."
        case .staged: "Sanitized floor plan attachment staged."
        case .cleaningUp: "Cleaning up the staged floor plan attachment."
        case .failed(let message): message
        }
    }
}
