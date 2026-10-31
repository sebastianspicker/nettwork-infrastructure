import CloudSync
import Foundation
import OSLog
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
    let workspaceAuthority: any CloudWorkspaceAuthority
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
        let workspaceAuthority = makeWorkspaceAuthority(input.cloudWorkspace.backend)
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

    private static func makeWorkspaceAuthority(_ backend: OrganizationInput.CloudWorkspace.Backend) -> any CloudWorkspaceAuthority {
        switch backend {
        case .cloudKit(let cloudKit):
            CloudKitWorkspaceAuthority(
                container: cloudKit.cloudKitContainer,
                contextStore: cloudKit.workspaceContextStore,
                shareService: cloudKit.workspaceShareService,
                bootstrapper: cloudKit.workspaceBootstrapper
            )
        case .local(let local):
            local.workspaceAuthority
        }
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
                Logger(subsystem: input.cloudWorkspace.telemetrySubsystem, category: "workspace.activation")
                    .error("activation failed: \(PrivacySafeErrorDiagnostics.label(for: error), privacy: .public)")
                emitAccountLifecycle(.failed, failure: PrivacySafeErrorDiagnostics.telemetryFailureCategory(for: error), input: input, telemetry: telemetry)
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

    private static func emitAccountLifecycle(
        _ outcome: PrivacySafeSyncTelemetryOutcome, failure: PrivacySafeSyncTelemetryFailureCategory? = nil, input: OrganizationInput,
        telemetry: ProductionOSLogSyncTelemetry
    ) {
        telemetry.emit(
            PrivacySafeSyncTelemetryEvent(
                operation: .accountLifecycle, outcome: outcome, recordCount: 0, assetCount: 0,
                queueDepth: 0, failureCategory: failure), retention: input.cloudWorkspace.telemetryRetention)
    }
}
