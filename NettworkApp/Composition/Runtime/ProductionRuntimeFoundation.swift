import CloudSync
import Foundation
import Persistence
import WorkspaceServices

struct ProductionRuntimeFoundation {
    let operationBoundary: ProductionOperationBoundary
    let telemetry: ProductionOSLogSyncTelemetry
    let persistence: SwiftDataPersistenceStore
    let mirror: SwiftDataCloudMirrorStore
    let lifecycle: CloudSessionLifecycle
    let stateStore: SwiftDataCloudKitSyncEngineStateStore
    let identityIndex: SwiftDataCloudRecordNameIdentityIndex
    let workspaceAuthority: CloudKitWorkspaceAuthority
    let sessionAuthorizer: ProductionSessionAuthorizer
    let activateWorkspace: () async throws -> Void
    let invalidateWorkspace: () async -> Void
}

extension ProductionRuntimeAssembly {
    static func makeRuntimeFoundation(_ input: OrganizationInput) async throws -> ProductionRuntimeFoundation {
        let operationBoundary = try ProductionOperationBoundary(
            policies: input.operationGovernance.operationPolicies,
            budgets: input.operationGovernance.operationPerformanceBudgets,
            measurementSink: input.operationGovernance.operationMeasurementSink
        )
        let telemetry = ProductionOSLogSyncTelemetry(
            subsystem: input.cloudWorkspace.telemetrySubsystem,
            retention: input.cloudWorkspace.telemetryRetention,
            metrics: input.cloudWorkspace.telemetryMetricsStore
        )
        let persistence = SwiftDataPersistenceStore(
            container: input.workspaceStorage.modelContainer,
            attachmentDirectory: input.workspaceStorage.attachmentDirectory
        )
        let mirror = SwiftDataCloudMirrorStore(
            productionPersistence: persistence,
            stagedAssetQuota: input.cloudWorkspace.stagedAssetQuota
        )
        let lifecycle = CloudSessionLifecycle(store: mirror)
        let stateStore = SwiftDataCloudKitSyncEngineStateStore(
            persistence: persistence,
            namespace: input.cloudWorkspace.account.namespace
        )
        let identityIndex = try SwiftDataCloudRecordNameIdentityIndex(
            persistence: persistence,
            namespace: input.cloudWorkspace.account.namespace,
            maximumEntries: input.cloudWorkspace.maximumRecordNameIdentities
        )
        let workspaceAuthority = CloudKitWorkspaceAuthority(
            container: input.cloudWorkspace.cloudKitContainer,
            contextStore: input.cloudWorkspace.workspaceContextStore,
            shareService: input.cloudWorkspace.workspaceShareService,
            bootstrapper: input.cloudWorkspace.workspaceBootstrapper
        )
        let sessionAuthorizer = ProductionSessionAuthorizer(
            lifecycle: lifecycle,
            workspaceAuthority: workspaceAuthority,
            actorProvider: input.cloudWorkspace.actorContextProvider,
            installationSession: input.cloudWorkspace.installationSession
        )
        let activate = makeWorkspaceActivation(input, telemetry: telemetry, lifecycle: lifecycle, authorizer: sessionAuthorizer, identityIndex: identityIndex)
        let invalidate = makeWorkspaceInvalidation(input, telemetry: telemetry, lifecycle: lifecycle)
        try await activate()
        return ProductionRuntimeFoundation(
            operationBoundary: operationBoundary,
            telemetry: telemetry,
            persistence: persistence,
            mirror: mirror,
            lifecycle: lifecycle,
            stateStore: stateStore,
            identityIndex: identityIndex,
            workspaceAuthority: workspaceAuthority,
            sessionAuthorizer: sessionAuthorizer,
            activateWorkspace: activate,
            invalidateWorkspace: invalidate
        )
    }

    private static func makeWorkspaceActivation(
        _ input: OrganizationInput, telemetry: ProductionOSLogSyncTelemetry, lifecycle: CloudSessionLifecycle,
        authorizer: ProductionSessionAuthorizer, identityIndex: SwiftDataCloudRecordNameIdentityIndex
    ) -> () async throws -> Void {
        {
            emitAccountLifecycle(.started, input: input, telemetry: telemetry)
            do {
                _ = try await lifecycle.activate(input.cloudWorkspace.account)
                let trusted = try await authorizer.verifiedSession(namespace: input.cloudWorkspace.account.namespace)
                guard trusted.account == input.cloudWorkspace.account else { throw ProductionRuntimeAssemblyError.verifiedAccountMismatch }
                try await identityIndex.reconcileFromMirroredRecords()
                emitAccountLifecycle(.succeeded, input: input, telemetry: telemetry)
            } catch {
                await lifecycle.invalidateCurrentSession()
                emitAccountLifecycle(.failed, input: input, telemetry: telemetry)
                throw error
            }
        }
    }

    private static func makeWorkspaceInvalidation(
        _ input: OrganizationInput, telemetry: ProductionOSLogSyncTelemetry, lifecycle: CloudSessionLifecycle
    ) -> () async -> Void {
        {
            await lifecycle.invalidateCurrentSession()
            emitAccountLifecycle(.cancelled, input: input, telemetry: telemetry)
        }
    }

    private static func emitAccountLifecycle(_ outcome: PrivacySafeSyncTelemetryOutcome, input: OrganizationInput, telemetry: ProductionOSLogSyncTelemetry) {
        let failure: PrivacySafeSyncTelemetryFailureCategory? = outcome == .failed ? .accountUnavailable : nil
        telemetry.emit(
            PrivacySafeSyncTelemetryEvent(
                operation: .accountLifecycle, outcome: outcome, recordCount: 0, assetCount: 0,
                queueDepth: 0, failureCategory: failure), retention: input.cloudWorkspace.telemetryRetention)
    }
}
