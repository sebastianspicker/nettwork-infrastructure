import ContentSafety

struct ProductionRuntimeOrganizationGraph {
    let authorities: ProductionOrganizationAuthorities
}

struct ProductionRuntimeFloorPlanGraph {
    let authorizer: ProductionFloorPlanWorkOrderAuthorizer
    let service: ProductionFloorPlanFeatureService
}

extension ProductionRuntimeAssembly {
    static func makeRuntimeOrganizationGraph(
        _ input: OrganizationInput, foundation: ProductionRuntimeFoundation, cloud: ProductionRuntimeCloudGraph, transfer: ProductionRuntimeTransferGraph
    ) -> ProductionRuntimeOrganizationGraph {
        let authorities = ProductionOrganizationAuthorityFactory.make(
            account: input.cloudWorkspace.account, workspaceName: input.cloudWorkspace.workspaceName,
            persistence: foundation.persistence, lifecycle: foundation.lifecycle, workspaceAuthority: foundation.workspaceAuthority,
            sessionAuthorizer: foundation.sessionAuthorizer, transport: cloud.transport, syncCoordinator: cloud.syncCoordinator,
            correctiveBuilder: transfer.correctiveBuilder, auditExporter: transfer.auditExporter, telemetry: foundation.telemetry,
            telemetryRetention: input.cloudWorkspace.telemetryRetention, telemetryExternalSignalProvider: input.cloudWorkspace.telemetryExternalSignalProvider,
            operationBoundary: foundation.operationBoundary, stagedTransferGC: cloud.stagedTransferGC,
            acceptedShareActivation: input.featureContext.acceptedShareActivation, draftStore: input.workspaceStorage.stagedWorkOrderDraftStore,
            policy: input.operationGovernance.workOrderPolicy)
        return ProductionRuntimeOrganizationGraph(authorities: authorities)
    }

    static func makeRuntimeFloorPlanGraph(
        _ input: OrganizationInput, foundation: ProductionRuntimeFoundation, cloud: ProductionRuntimeCloudGraph,
        attachment: ProductionRuntimeAttachmentGraph, organization: ProductionRuntimeOrganizationGraph
    ) -> ProductionRuntimeFloorPlanGraph {
        let preview = ProductionFloorPlanPreviewRenderer(staging: attachment.staging, currentContext: foundation.sessionAuthorizer)
        let authorizer = ProductionFloorPlanWorkOrderAuthorizer(
            staging: organization.authorities.mutations, metadata: input.operationGovernance.floorPlanWorkOrderMetadata)
        let inspector = ProductionFloorPlanPDFInspector(currentContext: foundation.sessionAuthorizer)
        let atomicBinding = ProductionFloorPlanAssetAtomicBinding(
            staging: attachment.staging, sessionAuthorizer: foundation.sessionAuthorizer,
            exactRecords: cloud.transport, mutations: cloud.mutationRepository)
        let assetAuthority = ProductionFloorPlanAssetAuthority(
            account: input.cloudWorkspace.account, floorID: input.featureContext.floorID,
            sessionAuthorizer: foundation.sessionAuthorizer, atomicBinding: atomicBinding)
        let readProjection = SwiftDataFloorPlanReadProjection(account: input.cloudWorkspace.account, persistence: foundation.persistence)
        let boundPreview = ProductionBoundFloorPlanPreviewRenderer(
            persistence: foundation.persistence, account: input.cloudWorkspace.account,
            currentContext: foundation.sessionAuthorizer)
        let service = ProductionFloorPlanFeatureService(
            account: input.cloudWorkspace.account, floorID: input.featureContext.floorID,
            contentSafety: attachment.contentSafety, sessionAuthorizer: foundation.sessionAuthorizer, anchorMutations: authorizer,
            previewRenderer: preview, pdfInspector: inspector, assetAuthority: assetAuthority, readProjection: readProjection,
            boundPreviewRenderer: boundPreview, operationBoundary: foundation.operationBoundary)
        return ProductionRuntimeFloorPlanGraph(authorizer: authorizer, service: service)
    }
}
