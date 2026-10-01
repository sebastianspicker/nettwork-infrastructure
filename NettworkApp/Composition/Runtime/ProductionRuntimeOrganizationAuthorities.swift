import WorkspaceServices

extension ProductionRuntimeAssembly {
    static func makeRuntimeOrganizationAuthorities(
        _ input: OrganizationInput, foundation: ProductionRuntimeFoundation, cloud: ProductionRuntimeCloudGraph, transfer: ProductionRuntimeTransferGraph
    ) -> ProductionOrganizationAuthorities {
        ProductionOrganizationAuthorityFactory.make(
            account: input.cloudWorkspace.account, workspaceName: input.cloudWorkspace.workspaceName,
            persistence: foundation.persistence, lifecycle: foundation.lifecycle, workspaceAuthority: foundation.workspaceAuthority,
            sessionAuthorizer: foundation.sessionAuthorizer, transport: cloud.transport, syncCoordinator: cloud.syncCoordinator,
            correctiveBuilder: transfer.correctiveBuilder, auditExporter: transfer.auditExporter, telemetry: foundation.telemetry,
            telemetryRetention: input.cloudWorkspace.telemetryRetention, telemetryExternalSignalProvider: input.cloudWorkspace.telemetryExternalSignalProvider,
            operationBoundary: foundation.operationBoundary, stagedTransferGC: cloud.stagedTransferGC,
            acceptedShareActivation: input.featureContext.acceptedShareActivation, draftStore: input.workspaceStorage.stagedWorkOrderDraftStore,
            policy: input.operationGovernance.workOrderPolicy)
    }
}
