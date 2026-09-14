extension ProductionRuntimeAssembly {
    static func makeRuntimeFeatureInput(
        _ input: OrganizationInput,
        platformCapabilities: OrganizationInput.PlatformCapabilities,
        foundation: ProductionRuntimeFoundation,
        attachment: ProductionRuntimeAttachmentGraph,
        transfer: ProductionRuntimeTransferGraph,
        organization: ProductionRuntimeOrganizationGraph,
        floorPlan: ProductionRuntimeFloorPlanGraph
    ) -> ProductionFeatureGraphInput {
        ProductionFeatureGraphInput(
            account: input.cloudWorkspace.account,
            persistence: foundation.persistence,
            currentAuthorizationContext: foundation.sessionAuthorizer,
            operationBoundary: foundation.operationBoundary,
            authorities: organization.authorities,
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
            auditExportAuthorization: input.featureContext.auditExportAuthorization,
            floorPlanImportSource: input.featureContext.floorPlanImportSource,
            attachmentAuthorization: input.featureContext.attachmentAuthorization,
            floorPlanPreviewAuthorization: input.featureContext.floorPlanPreviewAuthorization,
            csvImportDocument: input.featureContext.csvImportDocument,
            importAuthorization: input.featureContext.importAuthorization,
            csvExportAuthorization: input.featureContext.csvExportAuthorization,
            csvExportDestination: input.featureContext.csvExportDestination,
            archiveExportAuthorization: input.featureContext.archiveExportAuthorization,
            archiveRestoreSource: input.featureContext.archiveRestoreSource,
            archiveRestoreAuthorization: input.featureContext.archiveRestoreAuthorization,
            workspaceShareMetadata: input.featureContext.workspaceShareMetadata,
            onWorkspaceInvitationPrepared: input.featureContext.onWorkspaceInvitationPrepared
        )
    }

    static func makeRuntimeAssembly(
        foundation: ProductionRuntimeFoundation,
        cloud: ProductionRuntimeCloudGraph,
        attachment: ProductionRuntimeAttachmentGraph,
        transfer: ProductionRuntimeTransferGraph,
        organization: ProductionRuntimeOrganizationGraph,
        floorPlan: ProductionRuntimeFloorPlanGraph,
        featureInput: ProductionFeatureGraphInput
    ) -> ProductionRuntimeAssembly {
        let composition = AppRuntimeComposition.production(
            featureInput: featureInput, activateWorkspace: foundation.activateWorkspace,
            syncCoordinator: organization.authorities.synchronizer, invalidateWorkspace: foundation.invalidateWorkspace)
        return ProductionRuntimeAssembly(
            composition: composition,
            activateWorkspace: foundation.activateWorkspace,
            invalidateWorkspace: foundation.invalidateWorkspace,
            foundation: foundation,
            cloud: cloud,
            attachment: attachment,
            transfer: transfer,
            organization: organization,
            floorPlan: floorPlan
        )
    }
}
