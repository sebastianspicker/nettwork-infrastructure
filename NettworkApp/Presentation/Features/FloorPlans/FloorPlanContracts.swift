import ContentSafety
import CoreGraphics
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
protocol FloorPlanFeatureService {
    /// Inspection is capability-bound: neither a source URL nor untrusted raw
    /// bytes cross into the feature layer.
    func inspectFloorPlanPDF(source: any OpaqueContentSource, authorization: AuthorizedOperationContext) async throws -> FloorPlanPDFInspection?
    func sanitizeFloorPlan(
        source: any OpaqueContentSource,
        selectedPDFPage: Int?,
        authorization: AuthorizedOperationContext
    ) async throws -> SanitizedContentDescriptor
    func renderFloorPlan(_ descriptor: SanitizedContentDescriptor, authorization: AuthorizedOperationContext) async throws -> FloorPlanPreview
    func cleanupFloorPlanAttachment(_ descriptor: SanitizedContentDescriptor, authorization: AuthorizedOperationContext) async throws
    func stageFloorPlanAssetWorkOrder(_ descriptor: SanitizedContentDescriptor, authorization: OperationsAuthorization) async throws -> ObjectID
    func bindOrReplaceFloorPlanAsset(
        _ descriptor: SanitizedContentDescriptor,
        workOrderID: ObjectID,
        authorization: AuthorizedOperationContext
    ) async throws -> OperationReceipt
    func loadPersistedFloorPlan(authorization: AuthorizedOperationContext) async throws -> PersistedFloorPlanPresentation
    func saveNormalizedAnchor(_ anchor: FloorPlanAnchor, authorization: OperationsAuthorization) async throws -> ObjectID
    func removeNormalizedAnchor(_ anchor: FloorPlanAnchor, authorization: OperationsAuthorization) async throws -> ObjectID
}

/// Bounded PDF inspection output for a one-based UI page picker. Content
/// safety independently validates the translated zero-based page at decode.
struct FloorPlanPDFInspection: Equatable, Sendable {
    let pageCount: Int

    init(pageCount: Int) throws {
        guard (1...ContentSafetyService.maximumPDFPages).contains(pageCount) else {
            throw FloorPlanPDFInspectionError.invalidPageCount
        }
        self.pageCount = pageCount
    }
}

enum FloorPlanPDFInspectionError: Error, Equatable, Sendable {
    case invalidPageCount
}

/// A display-only derivative of the sanitized staging bytes. This value stays
/// main-actor isolated so the non-Sendable platform image cannot cross into an
/// untrusted or concurrent feature boundary.
@MainActor
struct FloorPlanPreview {
    let image: CGImage
    let accessibilityDescription: String

    init(
        image: CGImage,
        accessibilityDescription: String = "Sanitized floor plan preview. Use the Anchor list for a text alternative to the marked locations."
    ) {
        self.image = image
        self.accessibilityDescription = accessibilityDescription
    }
}

@MainActor
struct PersistedFloorPlanPresentation {
    let anchors: [FloorPlanAnchor]
    let preview: FloorPlanPreview?
}

@MainActor
protocol FloorPlanPreviewRendering {
    func renderFloorPlan(_ descriptor: SanitizedContentDescriptor, authorization: AuthorizedOperationContext) async throws -> FloorPlanPreview
}

enum FloorPlanAttachmentState: Equatable {
    case idle
    case inspectingPDF
    case awaitingPDFPageSelection(FloorPlanPDFInspection)
    case sanitizing
    case staged(SanitizedContentDescriptor)
    case cleaningUp
    case failed(String)
}

enum FloorPlanPreviewState {
    case idle
    case loading
    case rendered(FloorPlanPreview)
    case cancelled
    case failed(String)
}
