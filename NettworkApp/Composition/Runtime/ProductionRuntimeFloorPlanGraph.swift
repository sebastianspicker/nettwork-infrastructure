import ContentSafety
import WorkspaceServices

struct ProductionRuntimeFloorPlanGraph {
    let authorizer: ProductionFloorPlanWorkOrderAuthorizer
    let service: ProductionFloorPlanFeatureService
}

extension ProductionRuntimeAssembly {
    static func makeRuntimeFloorPlanGraph(
        _ input: OrganizationInput, foundation: ProductionRuntimeFoundation, cloud: ProductionRuntimeCloudGraph,
        attachment: ProductionRuntimeAttachmentGraph, authorities: ProductionOrganizationAuthorities
    ) -> ProductionRuntimeFloorPlanGraph {
        let preview = ProductionFloorPlanPreviewRenderer(staging: attachment.staging, currentContext: foundation.sessionAuthorizer)
        let authorizer = ProductionFloorPlanWorkOrderAuthorizer(
            staging: authorities.mutations, metadata: input.operationGovernance.floorPlanWorkOrderMetadata)
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
