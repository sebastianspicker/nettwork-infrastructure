import ContentSafety
import CryptoKit
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl

enum FloorPlanAnchorMutation: Hashable, Sendable {
    case upsert(FloorPlanAnchor)
    case remove(FloorPlanAnchor)
}

struct FloorPlanWorkOrderMetadata: Hashable, Sendable {
    let title: String
    let ticket: String
    let notes: String

    init(title: String, ticket: String, notes: String = "") {
        self.title = title
        self.ticket = ticket
        self.notes = notes
    }
}

struct FloorPlanWorkOrderRequest: Hashable, Sendable {
    let mutation: FloorPlanAnchorMutation
    let metadata: FloorPlanWorkOrderMetadata
}

/// The only floor-plan write seam exposed to feature integration. The central
/// authority owns draft storage and keeps floor-plan staging out of the read
/// projection protocol.
@MainActor
protocol ProductionFloorPlanWorkOrderStaging: Sendable {
    func stageFloorPlan(
        _ request: FloorPlanWorkOrderRequest, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> ObjectID

    func stageFloorPlanAsset(
        _ asset: PlannedFloorPlanAsset, metadata: FloorPlanWorkOrderMetadata, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> ObjectID
}

/// Implementations must create or amend a work order. They must not directly
/// mutate the mirrored or authoritative floor-plan record.
@MainActor
protocol FloorPlanAnchorMutationAuthorizing: Sendable {
    func request(_ mutation: FloorPlanAnchorMutation, account: AccountContext, authorization: OperationsAuthorization) async throws -> ObjectID

    func requestAssetWorkOrder(_ asset: PlannedFloorPlanAsset, account: AccountContext, authorization: OperationsAuthorization) async throws -> ObjectID
}

/// Platform code may inspect page count only through the importer-owned opaque
/// capability. It must not leak a URL or PDF bytes to the SwiftUI feature.
protocol FloorPlanPDFInspecting: Sendable {
    func inspectPDF(source: any OpaqueContentSource, authorization: AuthorizedOperationContext) async throws -> FloorPlanPDFInspection
}

@MainActor
protocol BoundFloorPlanPreviewRendering: Sendable {
    func renderBoundFloorPlan(_ asset: FloorPlanAssetReadProjection, authorization: AuthorizedOperationContext) async throws -> FloorPlanPreview
}

/// Converts a normalized anchor edit into a full, typed work-order draft. It
/// deliberately has no direct persistence or CloudKit mutation capability.
@MainActor
struct ProductionFloorPlanWorkOrderAuthorizer: FloorPlanAnchorMutationAuthorizing {
    private let staging: any ProductionFloorPlanWorkOrderStaging
    private let metadata: FloorPlanWorkOrderMetadata

    init(staging: any ProductionFloorPlanWorkOrderStaging, metadata: FloorPlanWorkOrderMetadata) {
        self.staging = staging
        self.metadata = metadata
    }

    func request(_ mutation: FloorPlanAnchorMutation, account: AccountContext, authorization: OperationsAuthorization) async throws -> ObjectID {
        try await staging.stageFloorPlan(
            FloorPlanWorkOrderRequest(mutation: mutation, metadata: metadata),
            authorization: authorization,
            in: account.namespace
        )
    }

    func requestAssetWorkOrder(_ asset: PlannedFloorPlanAsset, account: AccountContext, authorization: OperationsAuthorization) async throws -> ObjectID {
        try await staging.stageFloorPlanAsset(asset, metadata: metadata, authorization: authorization, in: account.namespace)
    }
}

enum ProductionFloorPlanServiceError: Error, Equatable, Sendable {
    case staleAuthorization
    case invalidFloor
    case invalidCoordinates
    case pdfInspectionUnavailable
    case invalidPreviewDescriptor
}

/// Production floor-plan orchestration keeps untrusted bytes behind
/// `ContentSafetyService` and sends anchor edits only to a work-order authority.
@MainActor
struct ProductionFloorPlanFeatureService: FloorPlanFeatureService {
    private let account: AccountContext
    private let floorID: ObjectID
    private let contentSafety: ContentSafetyService
    private let sessionAuthorizer: ProductionSessionAuthorizer
    private let anchorMutations: any FloorPlanAnchorMutationAuthorizing
    private let previewRenderer: any FloorPlanPreviewRendering
    private let pdfInspector: (any FloorPlanPDFInspecting)?
    private let assetAuthority: ProductionFloorPlanAssetAuthority
    private let readProjection: any FloorPlanReadProjecting
    private let boundPreviewRenderer: any BoundFloorPlanPreviewRendering
    private let operationBoundary: ProductionOperationBoundary

    init(
        account: AccountContext,
        floorID: ObjectID,
        contentSafety: ContentSafetyService,
        sessionAuthorizer: ProductionSessionAuthorizer,
        anchorMutations: any FloorPlanAnchorMutationAuthorizing,
        previewRenderer: any FloorPlanPreviewRendering,
        pdfInspector: (any FloorPlanPDFInspecting)? = nil,
        assetAuthority: ProductionFloorPlanAssetAuthority,
        readProjection: any FloorPlanReadProjecting,
        boundPreviewRenderer: any BoundFloorPlanPreviewRendering,
        operationBoundary: ProductionOperationBoundary
    ) {
        self.account = account
        self.floorID = floorID
        self.contentSafety = contentSafety
        self.sessionAuthorizer = sessionAuthorizer
        self.anchorMutations = anchorMutations
        self.previewRenderer = previewRenderer
        self.pdfInspector = pdfInspector
        self.assetAuthority = assetAuthority
        self.readProjection = readProjection
        self.boundPreviewRenderer = boundPreviewRenderer
        self.operationBoundary = operationBoundary
    }

    func inspectFloorPlanPDF(source: any OpaqueContentSource, authorization: AuthorizedOperationContext) async throws -> FloorPlanPDFInspection? {
        try await operationBoundary.perform(.assetTransfer) {
            try await self.performInspectFloorPlanPDF(source: source, authorization: authorization)
        }
    }

    private func performInspectFloorPlanPDF(
        source: any OpaqueContentSource, authorization: AuthorizedOperationContext
    ) async throws -> FloorPlanPDFInspection? {
        guard authorization.account == account else {
            throw ProductionFloorPlanServiceError.staleAuthorization
        }
        guard try source.metadata().declaredType == .pdf else { return nil }
        guard let pdfInspector else {
            throw ProductionFloorPlanServiceError.pdfInspectionUnavailable
        }
        return try await pdfInspector.inspectPDF(source: source, authorization: authorization)
    }

    func sanitizeFloorPlan(
        source: any OpaqueContentSource, selectedPDFPage: Int?, authorization: AuthorizedOperationContext
    ) async throws -> SanitizedContentDescriptor {
        try await operationBoundary.perform(.assetTransfer) {
            try await self.performSanitizeFloorPlan(source: source, selectedPDFPage: selectedPDFPage, authorization: authorization)
        }
    }

    private func performSanitizeFloorPlan(
        source: any OpaqueContentSource, selectedPDFPage: Int?, authorization: AuthorizedOperationContext
    ) async throws -> SanitizedContentDescriptor {
        try await contentSafety.sanitizeAndStage(source: source, purpose: .floorPlan, selectedPDFPage: selectedPDFPage, authorization: authorization)
    }

    func renderFloorPlan(_ descriptor: SanitizedContentDescriptor, authorization: AuthorizedOperationContext) async throws -> FloorPlanPreview {
        guard descriptor.namespace == AttachmentNamespace(account: account),
            descriptor.purpose == .floorPlan,
            descriptor.contentType == .jpeg
        else {
            throw ProductionFloorPlanServiceError.invalidPreviewDescriptor
        }
        return try await previewRenderer.renderFloorPlan(descriptor, authorization: authorization)
    }

    func cleanupFloorPlanAttachment(_ descriptor: SanitizedContentDescriptor, authorization: AuthorizedOperationContext) async throws {
        try await operationBoundary.perform(.assetTransfer) {
            try await contentSafety.cleanup(descriptor, authorization: authorization)
        }
    }

    func stageFloorPlanAssetWorkOrder(_ descriptor: SanitizedContentDescriptor, authorization: OperationsAuthorization) async throws -> ObjectID {
        guard descriptor.namespace == AttachmentNamespace(account: account),
            descriptor.purpose == .floorPlan,
            descriptor.contentType == .jpeg,
            descriptor.byteCount > 0
        else {
            throw ProductionFloorPlanServiceError.invalidPreviewDescriptor
        }
        let metadata = try CloudRecordAssetMetadata(
            id: descriptor.id, fieldName: "floorPlanAsset", sha256: descriptor.contentSHA256, contentType: descriptor.contentType.rawValue,
            byteCount: descriptor.byteCount
        )
        let planned = try PlannedFloorPlanAsset(floorID: floorID, assetMetadata: metadata)
        return try await anchorMutations.requestAssetWorkOrder(planned, account: account, authorization: authorization)
    }

    func bindOrReplaceFloorPlanAsset(
        _ descriptor: SanitizedContentDescriptor, workOrderID: ObjectID, authorization: AuthorizedOperationContext
    ) async throws -> OperationReceipt {
        try await operationBoundary.perform(.assetTransfer) {
            try await assetAuthority.bindOrReplace(
                FloorPlanAssetBindingRequest(workOrderID: workOrderID, floorID: floorID, descriptor: descriptor),
                authorization: authorization
            )
        }
    }

    func loadPersistedFloorPlan(authorization: AuthorizedOperationContext) async throws -> PersistedFloorPlanPresentation {
        guard authorization.action == .readAttachment,
            authorization.account == account
        else {
            throw ProductionFloorPlanServiceError.staleAuthorization
        }
        let projection = try await readProjection.floorPlan(for: floorID, in: account.namespace)
        let preview: FloorPlanPreview?
        if let asset = projection.asset {
            preview = try await boundPreviewRenderer.renderBoundFloorPlan(asset, authorization: authorization)
        } else {
            preview = nil
        }
        return PersistedFloorPlanPresentation(anchors: projection.anchors, preview: preview)
    }

    func saveNormalizedAnchor(_ anchor: FloorPlanAnchor, authorization: OperationsAuthorization) async throws -> ObjectID {
        let trusted = try await validate(anchor, authorization: authorization)
        let workOrderID = try await anchorMutations.request(.upsert(anchor), account: account, authorization: authorization)
        try await revalidate(trusted)
        return workOrderID
    }

    func removeNormalizedAnchor(_ anchor: FloorPlanAnchor, authorization: OperationsAuthorization) async throws -> ObjectID {
        let trusted = try await validate(anchor, authorization: authorization)
        let workOrderID = try await anchorMutations.request(.remove(anchor), account: account, authorization: authorization)
        try await revalidate(trusted)
        return workOrderID
    }

    private func validate(_ anchor: FloorPlanAnchor, authorization: OperationsAuthorization) async throws -> TrustedProductionSession {
        let trusted: TrustedProductionSession
        do {
            trusted = try await sessionAuthorizer.authorizeMutation(namespace: account.namespace, presentation: authorization)
        } catch {
            throw ProductionFloorPlanServiceError.staleAuthorization
        }
        guard trusted.account == account else { throw ProductionFloorPlanServiceError.staleAuthorization }
        guard anchor.floorID == floorID else {
            throw ProductionFloorPlanServiceError.invalidFloor
        }
        guard anchor.x.isFinite, anchor.y.isFinite,
            (0...1).contains(anchor.x), (0...1).contains(anchor.y)
        else {
            throw ProductionFloorPlanServiceError.invalidCoordinates
        }
        return trusted
    }

    private func revalidate(_ trusted: TrustedProductionSession) async throws {
        do {
            try await sessionAuthorizer.revalidate(trusted)
        } catch {
            throw ProductionFloorPlanServiceError.staleAuthorization
        }
    }
}
