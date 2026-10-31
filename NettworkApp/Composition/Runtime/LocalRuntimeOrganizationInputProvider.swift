import CloudSync
import ContentSafety
import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl
import WorkspaceServices

/// Stage-1 local runtime, selected only by the "Alpha Local" build
/// configuration through `NettworkProductionConfigurationProvider`. The app
/// runs fully offline against the durable local record store: one local
/// administrator, one owner-private workspace, no sharing and no CloudKit.
/// This provider is the only place that mints the local administrator's
/// claims; authorities still re-verify them against the persisted identity.
@objc(NettworkLocalRuntimeProvider)
@MainActor
final class LocalRuntimeOrganizationInputProvider: NSObject, ProductionRuntimeOrganizationInputProviding {
    private let layoutOverride: LocalRuntimeLayout?

    override init() {
        layoutOverride = nil
        super.init()
    }

    /// Test seam: a private root instead of Application Support.
    init(rootDirectory: URL) {
        layoutOverride = LocalRuntimeLayout(root: rootDirectory)
        super.init()
    }

    func makeOrganizationInput() throws -> ProductionRuntimeAssembly.OrganizationInput {
        let layout = try layoutOverride ?? LocalRuntimeLayout.applicationSupport()
        let resources = try LocalRuntimeRegistry.resources(for: layout)
        let verifiedAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        let account = resources.identity.ownerContext(sessionGeneration: LocalRuntimePolicies.sessionGeneration, verifiedAt: verifiedAt)
        let claims = LocalRuntimeAdministratorClaims(
            account: account, installationID: resources.installationID, installationSessionID: resources.installationSession.id)
        return ProductionRuntimeAssembly.OrganizationInput(
            workspaceStorage: Self.workspaceStorage(resources),
            cloudWorkspace: try Self.cloudWorkspace(resources, account: account),
            operationGovernance: try Self.operationGovernance(layout, account: account),
            featureContext: Self.featureContext(workspaceID: resources.identity.workspaceID, claims: claims),
            platformCapabilities: nil
        )
    }

    private static func workspaceStorage(_ resources: LocalRuntimeResources) -> ProductionRuntimeAssembly.OrganizationInput.WorkspaceStorage {
        let layout = resources.layout
        return ProductionRuntimeAssembly.OrganizationInput.WorkspaceStorage(
            modelContainer: resources.modelContainer,
            attachmentDirectory: layout.attachmentDirectory,
            attachmentStagingDirectory: layout.attachmentStagingDirectory,
            csvStagingDirectory: layout.csvStagingDirectory,
            archiveRestoreStagingDirectory: layout.archiveRestoreStagingDirectory,
            auditPrivateDirectory: layout.auditPrivateDirectory,
            historyDirectory: layout.historyDirectory(for: resources.identity.workspaceID),
            attachmentStagingLifetime: LocalRuntimePolicies.attachmentStagingLifetime,
            attachmentStagingProtection: FoundationAttachmentStagingFileProtection(),
            stagedWorkOrderDraftStore: resources.draftStore
        )
    }

    private static func cloudWorkspace(
        _ resources: LocalRuntimeResources, account: AccountContext
    ) throws -> ProductionRuntimeAssembly.OrganizationInput.CloudWorkspace {
        let identityDirectory = resources.layout.identityDirectory
        let retention = LocalRuntimePolicies.telemetryRetention
        return ProductionRuntimeAssembly.OrganizationInput.CloudWorkspace(
            account: account,
            workspaceName: LocalRuntimePolicies.workspaceName,
            backend: .local(
                ProductionRuntimeAssembly.OrganizationInput.CloudWorkspace.LocalBackend(
                    makeTransport: transportFactory(store: resources.store, account: account),
                    workspaceAuthority: LocalWorkspaceAuthority(identityDirectory: identityDirectory))),
            maximumRecordNameIdentities: LocalRuntimePolicies.maximumRecordNameIdentities,
            stagedAssetQuota: try LocalRuntimePolicies.stagedAssetQuota(),
            stagedTransferGCPolicy: nil,
            telemetrySubsystem: LocalRuntimePolicies.telemetrySubsystem,
            telemetryRetention: retention,
            telemetryExternalSignalProvider: UnavailablePrivacySafeSyncTelemetryExternalSignalProvider(),
            telemetryMetricsStore: BoundedPrivacySafeSyncTelemetryStore(retention: retention),
            actorContextProvider: LocalActorContextProvider(identityDirectory: identityDirectory, installationID: resources.installationID),
            installationSession: resources.installationSession,
            remoteRecordValidator: CloudRemoteRecordValidator()
        )
    }

    /// Seeds the empty-workspace sentinel (a no-op once the store has any
    /// record) before the transport exists; the assembly awaits this before
    /// its sync coordinator is built, so the first sync always finds it.
    private static func transportFactory(
        store: LocalWorkspaceRecordStore, account: AccountContext
    ) -> (any CloudKitSyncEngineStateStore) async throws -> any ProductionRuntimeRecordTransport {
        { stateStore in
            _ = try await store.seedBootstrapSentinel(for: account.namespace.workspaceZone)
            return try LocalWorkspaceRecordTransport(store: store, account: account, stateStore: stateStore)
        }
    }

    private static func operationGovernance(
        _ layout: LocalRuntimeLayout, account: AccountContext
    ) throws -> ProductionRuntimeAssembly.OrganizationInput.OperationGovernance {
        ProductionRuntimeAssembly.OrganizationInput.OperationGovernance(
            operationPolicies: LocalRuntimePolicies.operationPolicies,
            operationPerformanceBudgets: LocalRuntimePolicies.operationBudgets,
            operationMeasurementSink: LocalRuntimeOperationMeasurementLog(subsystem: LocalRuntimePolicies.telemetrySubsystem),
            workOrderPolicy: try LocalRuntimePolicies.workOrderPolicy(),
            attachmentPolicy: try LocalRuntimePolicies.attachmentPolicy(),
            correctiveResolutionProvider: LocalRuntimeCorrectiveResolutionUnavailable(),
            auditDestination: LocalRuntimeAuditExportDestination(directory: layout.auditExportDirectory, namespace: account.namespace),
            archiveVerifier: ArchiveVerifier(),
            floorPlanWorkOrderMetadata: LocalRuntimePolicies.floorPlanWorkOrderMetadata
        )
    }

    /// Picked floor plans, evidence, CSV folders and archives come from the
    /// in-app pickers; CSV export uses the in-app file exporter.
    private static func featureContext(
        workspaceID: ObjectID, claims: LocalRuntimeAdministratorClaims
    ) -> ProductionRuntimeAssembly.OrganizationInput.FeatureContext {
        ProductionRuntimeAssembly.OrganizationInput.FeatureContext(
            floorID: LocalRuntimePolicies.floorID(for: workspaceID),
            floorPlanAnchors: [],
            floorPlanLabels: [:],
            templatePolicy: .allowed,
            operationsAuthorization: claims.operations,
            cancellationReleaseAuthorization: { claims.cancellationRelease(for: $0, at: .now) },
            auditExportAuthorization: claims.operation(.exportAudit),
            floorPlanImportSource: { nil },
            attachmentAuthorization: claims.operation(.createAttachment),
            floorPlanPreviewAuthorization: claims.operation(.readAttachment),
            workOrderEvidenceSource: { nil },
            workOrderEvidenceAuthorization: claims.operation(.createAttachment),
            csvImportDocument: { nil },
            importAuthorization: claims.operation(.importCSV),
            csvExportAuthorization: claims.operation(.exportCSV),
            csvExportDestination: nil,
            archiveExportAuthorization: claims.operation(.exportArchive),
            archiveRestoreSource: { nil },
            archiveRestoreAuthorization: claims.operation(.restoreArchive),
            workspaceShareMetadata: { nil },
            onWorkspaceInvitationPrepared: { _ in },
            acceptedShareActivation: { _ in throw LocalRuntimeProviderError.sharingUnavailable }
        )
    }
}
