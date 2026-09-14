import CloudSync
import ContentSafety
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

@MainActor
struct ProductionFeatureGraphInput {
    let account: AccountContext
    let persistence: SwiftDataPersistenceStore
    let currentAuthorizationContext: any CurrentAuthorizationContextProviding
    let operationBoundary: ProductionOperationBoundary
    let mutations: any ProductionFeatureMutationAuthorizing
    let synchronizer: any ProductionForegroundSynchronizing
    let workspaceAccess: any ProductionWorkspaceAccessReading
    let administration: any WorkspaceAdministrationModel
    let telemetryExternalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding
    let floorPlanService: any FloorPlanFeatureService
    let transferService: any TransferFeatureService
    let scanCapture: (@escaping @MainActor (ObjectID) -> Void) -> any ScanCapturing
    let labelGenerator: any LabelPDFGenerating
    let labelExporter: any LabelPDFExporting
    let labelPrinter: any LabelPrinting
    let operationsAuthorization: OperationsAuthorization
    let cancellationReleaseAuthorization: (CancellationReleaseRequest) -> CancellationReleaseAuthorization?
    let floorID: ObjectID
    let floorPlanAnchors: [FloorPlanAnchor]
    let floorPlanLabels: [ObjectID: String]
    let templatePolicy: TemplateAdministrationPolicy
    let attachmentEvidenceService: any AttachmentEvidenceFeatureService
    let workOrderEvidenceSource: () -> (any OpaqueContentSource)?
    let workOrderEvidenceAuthorization: () -> AuthorizedOperationContext?

    let auditExportAuthorization: (() -> AuthorizedOperationContext?)?
    let floorPlanImportSource: (() -> (any OpaqueContentSource)?)?
    let attachmentAuthorization: (() -> AuthorizedOperationContext?)?
    let floorPlanPreviewAuthorization: (() -> AuthorizedOperationContext?)?
    let csvImportDocument: (() -> CSVImportDocument?)?
    let importAuthorization: (() -> AuthorizedOperationContext?)?
    let csvExportAuthorization: (() -> AuthorizedOperationContext?)?
    let csvExportDestination: (any CSVWorkspaceExportDestination)?
    let archiveExportAuthorization: (() -> AuthorizedOperationContext?)?
    let archiveRestoreSource: (() -> (any ArchiveEntrySource)?)?
    let archiveRestoreAuthorization: (() -> AuthorizedOperationContext?)?
    let workspaceShareMetadata: (() -> Data?)?
    let onWorkspaceInvitationPrepared: ((WorkspaceInviteReceipt) -> Void)?

    init(
        account: AccountContext,
        persistence: SwiftDataPersistenceStore,
        currentAuthorizationContext: any CurrentAuthorizationContextProviding,
        operationBoundary: ProductionOperationBoundary,
        authorities: ProductionOrganizationAuthorities,
        floorPlanService: any FloorPlanFeatureService,
        transferService: any TransferFeatureService,
        scanCapture: @escaping (@escaping @MainActor (ObjectID) -> Void) -> any ScanCapturing,
        labelGenerator: any LabelPDFGenerating,
        labelExporter: any LabelPDFExporting,
        labelPrinter: any LabelPrinting,
        operationsAuthorization: OperationsAuthorization,
        cancellationReleaseAuthorization: @escaping (CancellationReleaseRequest) -> CancellationReleaseAuthorization?,
        floorID: ObjectID,
        floorPlanAnchors: [FloorPlanAnchor] = [],
        floorPlanLabels: [ObjectID: String] = [:],
        templatePolicy: TemplateAdministrationPolicy,
        attachmentEvidenceService: any AttachmentEvidenceFeatureService,
        workOrderEvidenceSource: @escaping () -> (any OpaqueContentSource)?,
        workOrderEvidenceAuthorization: @escaping () -> AuthorizedOperationContext?,
        auditExportAuthorization: (() -> AuthorizedOperationContext?)?,
        floorPlanImportSource: (() -> (any OpaqueContentSource)?)?,
        attachmentAuthorization: (() -> AuthorizedOperationContext?)?,
        floorPlanPreviewAuthorization: (() -> AuthorizedOperationContext?)?,
        csvImportDocument: (() -> CSVImportDocument?)?,
        importAuthorization: (() -> AuthorizedOperationContext?)?,
        csvExportAuthorization: (() -> AuthorizedOperationContext?)?,
        csvExportDestination: (any CSVWorkspaceExportDestination)?,
        archiveExportAuthorization: (() -> AuthorizedOperationContext?)?,
        archiveRestoreSource: (() -> (any ArchiveEntrySource)?)?,
        archiveRestoreAuthorization: (() -> AuthorizedOperationContext?)?,
        workspaceShareMetadata: (() -> Data?)?,
        onWorkspaceInvitationPrepared: ((WorkspaceInviteReceipt) -> Void)?
    ) {
        self.account = account
        self.persistence = persistence
        self.currentAuthorizationContext = currentAuthorizationContext
        self.operationBoundary = operationBoundary
        self.mutations = authorities.mutations
        self.synchronizer = authorities.synchronizer
        self.workspaceAccess = authorities.workspaceAccess
        self.administration = authorities.administration
        self.telemetryExternalSignalProvider = authorities.telemetryExternalSignalProvider
        self.floorPlanService = floorPlanService
        self.transferService = transferService
        self.scanCapture = scanCapture
        self.labelGenerator = labelGenerator
        self.labelExporter = labelExporter
        self.labelPrinter = labelPrinter
        self.operationsAuthorization = operationsAuthorization
        self.cancellationReleaseAuthorization = cancellationReleaseAuthorization
        self.floorID = floorID
        self.floorPlanAnchors = floorPlanAnchors
        self.floorPlanLabels = floorPlanLabels
        self.templatePolicy = templatePolicy
        self.attachmentEvidenceService = attachmentEvidenceService
        self.workOrderEvidenceSource = workOrderEvidenceSource
        self.workOrderEvidenceAuthorization = workOrderEvidenceAuthorization
        self.auditExportAuthorization = auditExportAuthorization
        self.floorPlanImportSource = floorPlanImportSource
        self.attachmentAuthorization = attachmentAuthorization
        self.floorPlanPreviewAuthorization = floorPlanPreviewAuthorization
        self.csvImportDocument = csvImportDocument
        self.importAuthorization = importAuthorization
        self.csvExportAuthorization = csvExportAuthorization
        self.csvExportDestination = csvExportDestination
        self.archiveExportAuthorization = archiveExportAuthorization
        self.archiveRestoreSource = archiveRestoreSource
        self.archiveRestoreAuthorization = archiveRestoreAuthorization
        self.workspaceShareMetadata = workspaceShareMetadata
        self.onWorkspaceInvitationPrepared = onWorkspaceInvitationPrepared
    }
}

@MainActor
enum ProductionFeatureGraphFactory {
    static func make(_ input: ProductionFeatureGraphInput) -> AppFeatureComposition {
        let services = makeFeatureGraphServices(input)
        let models = makeFeatureGraphModels(input, services: services)
        return makeFeatureComposition(input, services: services, models: models)
    }
}

@MainActor
final class ScanModelRelay {
    weak var model: ScanIntakeModel?

    func receive(_ objectID: ObjectID) {
        Task {
            await model?.accept(ObjectLink.url(for: objectID).absoluteString)
        }
    }
}
