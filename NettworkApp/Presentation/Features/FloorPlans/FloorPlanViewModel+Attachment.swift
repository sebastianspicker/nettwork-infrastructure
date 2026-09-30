import ContentSafety
import CoreGraphics
import FeatureContracts
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
extension FloorPlanViewModel {
    func beginAttachmentImport(
        source: any OpaqueContentSource,
        authorization: AuthorizedOperationContext,
        previewAuthorization: @MainActor () -> AuthorizedOperationContext?
    ) async {
        guard canBeginAttachmentImport else {
            assetActionError = "Clean up or bind the current sanitized floor plan before importing another."
            return
        }
        let generation = UUID()
        attachmentGeneration = generation
        attachmentOperation = .inspecting
        previewGeneration = UUID()
        previewState = .idle
        assetWorkOrderID = nil
        assetBindingReceipt = nil
        assetActionError = nil
        attachmentState = .inspectingPDF
        do {
            if let inspection = try await service.inspectFloorPlanPDF(source: source, authorization: authorization) {
                guard isCurrentAttachmentOperation(generation, .inspecting) else { return }
                pendingPDFSource = source
                selectedPDFPage = 0
                attachmentState = .awaitingPDFPageSelection(inspection)
                attachmentOperation = nil
            } else {
                guard isCurrentAttachmentOperation(generation, .inspecting) else { return }
                attachmentOperation = .sanitizing
                await sanitizeAttachment(
                    source: source,
                    selectedPDFPage: nil,
                    authorization: authorization,
                    previewAuthorization: previewAuthorization,
                    generation: generation
                )
            }
        } catch is CancellationError {
            finishAttachmentOperation(generation, state: .idle, preview: .cancelled)
        } catch {
            finishAttachmentOperation(generation, state: .failed(error.localizedDescription))
        }
    }

    func selectPDFPage(_ page: Int, inspection: FloorPlanPDFInspection) {
        selectedPDFPage = min(max(page, 0), inspection.pageCount - 1)
    }

    func sanitizeSelectedPDFPage(
        authorization: AuthorizedOperationContext,
        previewAuthorization: @MainActor () -> AuthorizedOperationContext?
    ) async {
        guard case let .awaitingPDFPageSelection(inspection) = attachmentState,
            let source = pendingPDFSource,
            let generation = attachmentGeneration,
            attachmentOperation == nil
        else { return }
        let selectedPage = min(max(selectedPDFPage, 0), inspection.pageCount - 1)
        pendingPDFSource = nil
        attachmentOperation = .sanitizing
        await sanitizeAttachment(
            source: source,
            selectedPDFPage: selectedPage,
            authorization: authorization,
            previewAuthorization: previewAuthorization,
            generation: generation
        )
    }

    private func sanitizeAttachment(
        source: any OpaqueContentSource,
        selectedPDFPage: Int?,
        authorization: AuthorizedOperationContext,
        previewAuthorization: @MainActor () -> AuthorizedOperationContext?,
        generation: UUID
    ) async {
        guard isCurrentAttachmentOperation(generation, .sanitizing) else { return }
        attachmentState = .sanitizing
        var sanitizedDescriptor: SanitizedContentDescriptor?
        do {
            let descriptor = try await service.sanitizeFloorPlan(
                source: source,
                selectedPDFPage: selectedPDFPage,
                authorization: authorization
            )
            sanitizedDescriptor = descriptor
            try Task.checkCancellation()
            guard isCurrentAttachmentOperation(generation, .sanitizing) else { return }
            stagedDescriptor = descriptor
            assetActionError = nil
            attachmentState = .staged(descriptor)
            guard let previewAuthorization = previewAuthorization() else {
                previewState = .failed("A current authorization is required to render the sanitized floor plan.")
                attachmentOperation = nil
                return
            }
            attachmentOperation = .rendering
            await renderAttachment(descriptor, authorization: previewAuthorization, generation: generation)
        } catch is CancellationError {
            if let sanitizedDescriptor, attachmentGeneration == generation {
                stagedDescriptor = sanitizedDescriptor
                attachmentState = .staged(sanitizedDescriptor)
                previewState = .cancelled
                attachmentOperation = nil
                return
            }
            finishAttachmentOperation(generation, state: .idle, preview: .cancelled)
        } catch {
            finishAttachmentOperation(generation, state: .failed(error.localizedDescription))
        }
    }

    func cleanupAttachment(authorization: AuthorizedOperationContext) async {
        guard let descriptor = stagedDescriptor,
            let generation = attachmentGeneration,
            attachmentOperation == nil
        else { return }
        attachmentOperation = .cleaningUp
        previewGeneration = UUID()
        attachmentState = .cleaningUp
        previewState = .idle
        do {
            try await service.cleanupFloorPlanAttachment(descriptor, authorization: authorization)
            guard isCurrentAttachmentOperation(generation, .cleaningUp) else { return }
            stagedDescriptor = nil
            assetWorkOrderID = nil
            assetActionError = nil
            attachmentState = .idle
            attachmentGeneration = nil
            attachmentOperation = nil
        } catch is CancellationError {
            finishAttachmentOperation(generation, state: .staged(descriptor), preview: .cancelled)
        } catch {
            guard isCurrentAttachmentOperation(generation, .cleaningUp) else { return }
            assetActionError = error.localizedDescription
            attachmentState = .staged(descriptor)
            attachmentOperation = nil
        }
    }

    func stageAssetWorkOrder(authorization: OperationsAuthorization) async {
        guard let descriptor = stagedDescriptor,
            let generation = attachmentGeneration,
            attachmentOperation == nil,
            authorization.permitsPrivilegedAction
        else { return }
        attachmentOperation = .stagingWorkOrder
        do {
            let workOrderID = try await service.stageFloorPlanAssetWorkOrder(
                descriptor,
                authorization: authorization
            )
            guard isCurrentAttachmentOperation(generation, .stagingWorkOrder) else { return }
            assetWorkOrderID = workOrderID
            await onStagedWorkOrder(workOrderID)
            guard isCurrentAttachmentOperation(generation, .stagingWorkOrder) else { return }
            assetBindingReceipt = nil
            assetActionError = nil
            attachmentOperation = nil
        } catch {
            guard isCurrentAttachmentOperation(generation, .stagingWorkOrder) else { return }
            assetActionError = error.localizedDescription
            attachmentState = .staged(descriptor)
            attachmentOperation = nil
        }
    }

    func bindAsset(authorization: AuthorizedOperationContext) async {
        guard let descriptor = stagedDescriptor,
            let workOrderID = assetWorkOrderID,
            let generation = attachmentGeneration,
            attachmentOperation == nil
        else { return }
        attachmentOperation = .binding
        do {
            let receipt = try await service.bindOrReplaceFloorPlanAsset(
                descriptor,
                workOrderID: workOrderID,
                authorization: authorization
            )
            guard isCurrentAttachmentOperation(generation, .binding) else { return }
            assetBindingReceipt = receipt
            stagedDescriptor = nil
            assetWorkOrderID = nil
            assetActionError = nil
            attachmentState = .idle
            attachmentGeneration = nil
            attachmentOperation = nil
        } catch {
            guard isCurrentAttachmentOperation(generation, .binding) else { return }
            assetActionError = error.localizedDescription
            attachmentState = .staged(descriptor)
            attachmentOperation = nil
        }
    }

    func retryAttachmentPreview(authorization: AuthorizedOperationContext) async {
        guard let descriptor = stagedDescriptor,
            let generation = attachmentGeneration,
            canRetryAttachmentPreview
        else { return }
        attachmentOperation = .rendering
        await renderAttachment(descriptor, authorization: authorization, generation: generation)
    }

    func loadPersistedFloorPlan(authorization: AuthorizedOperationContext) async {
        let generation = previewGeneration
        do {
            let persisted = try await service.loadPersistedFloorPlan(authorization: authorization)
            try Task.checkCancellation()
            guard previewGeneration == generation, attachmentGeneration == nil else { return }
            anchors = persisted.anchors
            pendingAnchorWorkOrderIDs.removeAll()
            if let preview = persisted.preview {
                previewState = .rendered(preview)
            }
        } catch is CancellationError {
            return
        } catch {
            guard previewGeneration == generation, attachmentGeneration == nil else { return }
            previewState = .failed(error.localizedDescription)
        }
    }

    private func renderAttachment(
        _ descriptor: SanitizedContentDescriptor,
        authorization: AuthorizedOperationContext,
        generation: UUID
    ) async {
        guard isCurrentAttachmentOperation(generation, .rendering) else { return }
        previewState = .loading
        do {
            try Task.checkCancellation()
            let preview = try await service.renderFloorPlan(descriptor, authorization: authorization)
            guard isCurrentAttachmentOperation(generation, .rendering) else { return }
            previewState = .rendered(preview)
            attachmentOperation = nil
        } catch is CancellationError {
            guard isCurrentAttachmentOperation(generation, .rendering) else { return }
            previewState = .cancelled
            attachmentOperation = nil
        } catch {
            guard isCurrentAttachmentOperation(generation, .rendering) else { return }
            previewState = .failed(error.localizedDescription)
            attachmentOperation = nil
        }
    }

    private func isCurrentAttachmentOperation(_ generation: UUID, _ operation: AttachmentOperation) -> Bool {
        attachmentGeneration == generation && attachmentOperation == operation
    }

    private func finishAttachmentOperation(
        _ generation: UUID,
        state: FloorPlanAttachmentState,
        preview: FloorPlanPreviewState? = nil
    ) {
        guard attachmentGeneration == generation else { return }
        pendingPDFSource = nil
        attachmentGeneration = nil
        attachmentOperation = nil
        attachmentState = state
        if let preview { previewState = preview }
    }
}
