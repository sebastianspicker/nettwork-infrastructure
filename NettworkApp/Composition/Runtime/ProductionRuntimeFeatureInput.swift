import Foundation
import WorkspaceServices

extension ProductionRuntimeAssembly {
    static func makeRuntimeFeatureInput(
        _ input: OrganizationInput,
        platformCapabilities: OrganizationInput.PlatformCapabilities,
        foundation: ProductionRuntimeFoundation,
        attachment: ProductionRuntimeAttachmentGraph,
        transfer: ProductionRuntimeTransferGraph,
        authorities: ProductionOrganizationAuthorities,
        floorPlan: ProductionRuntimeFloorPlanGraph
    ) -> ProductionFeatureGraphInput {
        ProductionFeatureGraphInput(
            account: input.cloudWorkspace.account,
            persistence: foundation.persistence,
            currentAuthorizationContext: foundation.sessionAuthorizer,
            operationBoundary: foundation.operationBoundary,
            authorities: authorities,
            floorPlanService: floorPlan.service,
            transferService: transfer.service,
            scanCapture: platformCapabilities.scanCapture,
            labelGenerator: platformCapabilities.labelGenerator(),
            labelExporter: platformCapabilities.labelExporter(),
            labelPrinter: platformCapabilities.labelPrinter(),
            operationsAuthorization: input.featureContext.operationsAuthorization,
            cancellationReleaseAuthorization: input.featureContext.cancellationReleaseAuthorization,
            floorID: input.featureContext.floorID,
            floorPlanAnchors: input.featureContext.floorPlanAnchors,
            floorPlanLabels: input.featureContext.floorPlanLabels,
            templatePolicy: input.featureContext.templatePolicy,
            attachmentEvidenceService: attachment.service,
            workOrderEvidenceSource: input.featureContext.workOrderEvidenceSource,
            workOrderEvidenceAuthorization: input.featureContext.workOrderEvidenceAuthorization,
            capabilities: makeFeatureCapabilities(input.featureContext)
        )
    }

    /// Selected `.nettworkarchive` packages are always read by the platform
    /// package adapter; the Transfer screen only receives this factory.
    private static func makeFeatureCapabilities(_ context: OrganizationInput.FeatureContext) -> AppFeatureOptionalCapabilities {
        AppFeatureOptionalCapabilities(
            auditExportAuthorization: context.auditExportAuthorization,
            floorPlanImportSource: context.floorPlanImportSource,
            attachmentAuthorization: context.attachmentAuthorization,
            floorPlanPreviewAuthorization: context.floorPlanPreviewAuthorization,
            csvImportDocument: context.csvImportDocument,
            importAuthorization: context.importAuthorization,
            csvExportAuthorization: context.csvExportAuthorization,
            csvExportDestination: context.csvExportDestination,
            archiveExportAuthorization: context.archiveExportAuthorization,
            archiveRestoreSource: context.archiveRestoreSource,
            archivePackageSource: { url in try ProductionArchivePackageEntrySource(url: url) },
            archiveRestoreAuthorization: context.archiveRestoreAuthorization,
            workspaceShareMetadata: context.workspaceShareMetadata,
            onWorkspaceInvitationPrepared: context.onWorkspaceInvitationPrepared
        )
    }
}
