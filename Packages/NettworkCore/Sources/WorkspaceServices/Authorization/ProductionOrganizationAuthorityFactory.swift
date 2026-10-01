import CloudSync
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// The privileged production authorities that are injected into the feature
/// graph. Keeping this bundle separate from presentation composition makes it
/// impossible for a screen to substitute a local-only writer while retaining
/// the production workspace and synchronization readers.
@MainActor
public struct ProductionOrganizationAuthorities {
    public let mutations: ProductionFeatureMutationAuthority
    public let synchronizer: ProductionForegroundSyncAdapter
    public let workspaceAccess: ProductionWorkspaceAccessReader
    public let administration: ProductionWorkspaceAdministrationAuthority
    public let telemetryExternalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding
}

/// Constructs the complete production workflow boundary from one verified
/// account and one Cloud transport. The same transport supplies conditional
/// atomic writes and exact server snapshots, so reservation acknowledgement
/// cannot be derived from a different database or workspace adapter.
@MainActor
public enum ProductionOrganizationAuthorityFactory {
    public static func make<Transport>(
        account: AccountContext,
        workspaceName: String,
        persistence: SwiftDataPersistenceStore,
        lifecycle: CloudSessionLifecycle,
        workspaceAuthority: any CloudWorkspaceAuthority,
        sessionAuthorizer: ProductionSessionAuthorizer,
        transport: Transport,
        syncCoordinator: CloudForegroundSyncCoordinator,
        correctiveBuilder: any ProductionCorrectiveDraftBuilding,
        auditExporter: any ProductionImmutableAuditExporting,
        telemetry: any PrivacySafeSyncTelemetryEmitting,
        telemetryRetention: SyncTelemetryRetentionPolicy,
        telemetryExternalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding,
        operationBoundary: ProductionOperationBoundary,
        stagedTransferGC: CloudStagedTransferGarbageCollector? = nil,
        acceptedShareActivation: @escaping @MainActor (AccountContext) async throws -> Void,
        draftStore: any ProductionStagedWorkOrderDraftStoring = SessionWorkOrderDraftStore(),
        policy: ProductionWorkOrderPolicy
    ) -> ProductionOrganizationAuthorities where Transport: CloudRecordTransport & CloudExactRecordReading {
        let exactState = CloudExactAuthoritativeMutationStateProvider(reader: transport, account: account)
        let mutationRepository = CloudAuthoritativeMutationRepository(transport: transport, stateProvider: exactState)
        let acknowledgements = CloudReservationAcknowledgementService(exactRecords: transport, mutations: mutationRepository)
        let planner = SwiftDataProductionMutationPlanner(persistence: persistence, account: account)
        let mutations = ProductionFeatureMutationAuthority(
            account: account, sessionAuthorizer: sessionAuthorizer, exactRecords: transport, mutations: mutationRepository,
            acknowledgements: acknowledgements, semanticValidator: planner, completionMaterializer: planner,
            correctiveBuilder: correctiveBuilder, auditExporter: auditExporter, draftStore: draftStore, policy: policy
        )
        return ProductionOrganizationAuthorities(
            mutations: mutations,
            synchronizer: ProductionForegroundSyncAdapter(
                account: account, coordinator: syncCoordinator, telemetry: telemetry, retention: telemetryRetention,
                externalSignalProvider: telemetryExternalSignalProvider, operationBoundary: operationBoundary, stagedTransferGC: stagedTransferGC
            ),
            workspaceAccess: ProductionWorkspaceAccessReader(
                account: account, workspaceName: workspaceName, policyVersion: policy.policyVersion, sessionAuthorizer: sessionAuthorizer
            ),
            administration: ProductionWorkspaceAdministrationAuthority(
                account: account, workspaceName: workspaceName, lifecycle: lifecycle, workspaceAuthority: workspaceAuthority,
                sessionAuthorizer: sessionAuthorizer, acceptedShareActivation: acceptedShareActivation
            ),
            telemetryExternalSignalProvider: telemetryExternalSignalProvider
        )
    }
}
