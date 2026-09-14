import CloudSync
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Binds detached maintenance to the exact foreground account namespace and
/// obtains a new trusted lease immediately before each destructive GC write.
struct ProductionStagedTransferGCAuthorizer: CloudStagedTransferGCAuthorizing {
    let account: AccountContext
    let sessionAuthorizer: ProductionSessionAuthorizer

    func authorizeStagedTransferGC(in workspaceZone: AuthoritativeWorkspaceZone) async throws {
        guard workspaceZone == account.namespace.workspaceZone else {
            throw ProductionSessionAuthorizationError.namespaceMismatch
        }
        let trusted = try await sessionAuthorizer.verifiedSession(namespace: account.namespace)
        guard CloudAccountContextMatcher.sameScope(trusted.account, account) else {
            throw ProductionSessionAuthorizationError.namespaceMismatch
        }
        try OfficialClientPolicy.authorizeMutation(actor: trusted.actor, account: trusted.account, requiresAdministrator: true)
        try await sessionAuthorizer.revalidate(trusted)
    }
}

actor ProductionForegroundSyncAdapter: ProductionForegroundSynchronizing, SyncCoordinator {
    private let account: AccountContext
    private let coordinator: CloudForegroundSyncCoordinator
    private let telemetry: any PrivacySafeSyncTelemetryEmitting
    private let operationSignposting: any PrivacySafeSyncOperationSignposting
    private let retention: SyncTelemetryRetentionPolicy
    private let externalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding
    private let operationBoundary: ProductionOperationBoundary
    private let stagedTransferGC: CloudStagedTransferGarbageCollector?

    init(
        account: AccountContext,
        coordinator: CloudForegroundSyncCoordinator,
        telemetry: any PrivacySafeSyncTelemetryEmitting,
        retention: SyncTelemetryRetentionPolicy,
        externalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding = UnavailablePrivacySafeSyncTelemetryExternalSignalProvider(),
        operationBoundary: ProductionOperationBoundary,
        stagedTransferGC: CloudStagedTransferGarbageCollector? = nil
    ) {
        self.account = account
        self.coordinator = coordinator
        self.telemetry = telemetry
        self.operationSignposting =
            (telemetry as? any PrivacySafeSyncOperationSignposting)
            ?? NoopPrivacySafeSyncOperationSignposting()
        self.retention = retention
        self.externalSignalProvider = externalSignalProvider
        self.operationBoundary = operationBoundary
        self.stagedTransferGC = stagedTransferGC
    }

    func synchronizeForeground(in namespace: PersistenceNamespace) async -> SyncReceipt {
        let externalSignals = await externalSignalProvider.currentSignals()
        telemetry.emit(
            PrivacySafeSyncTelemetryEvent(
                operation: .synchronize, outcome: .started, recordCount: 0, assetCount: 0, queueDepth: 0,
                externalQuota: externalSignals.quota, externalBackupAge: externalSignals.backupAge
            ),
            retention: retention
        )
        guard namespace == account.namespace else {
            let receipt = SyncReceipt(
                failures: [SyncFailure(category: .security, message: "Foreground synchronization was requested outside the configured workspace.")]
            )
            await emit(receipt, outcome: Self.telemetryOutcome(for: receipt))
            await emitDerivedEvents(receipt)
            return receipt
        }

        let operationSignpost = operationSignposting.beginForegroundSynchronizeOperation()
        let coordinator = coordinator
        let receipt: SyncReceipt
        do {
            receipt = try await operationBoundary.perform(
                .synchronize,
                outputRecordCount: {
                    $0.downloadedRecordCount + $0.downloadedAssetCount + $0.uploadedOperationIDs.count
                }
            ) {
                await coordinator.synchronizeForeground()
            }
        } catch {
            receipt = SyncReceipt(
                failures: [SyncFailure(category: .unknown, message: "Foreground synchronization did not complete within its configured operation boundary.")]
            )
        }
        let outcome = Self.telemetryOutcome(for: receipt)
        // End on receipt classification, before telemetry formatting or external
        // signal reads, so the interval is only the coordinator operation.
        operationSignposting.endForegroundSynchronizeOperation(operationSignpost)
        await emit(receipt, outcome: outcome)
        await emitDerivedEvents(receipt)
        scheduleStagedTransferGC(after: receipt, in: namespace)
        return receipt
    }

    func synchronizeForeground() async -> SyncReceipt {
        await synchronizeForeground(in: account.namespace)
    }

    private func emit(_ receipt: SyncReceipt, outcome: PrivacySafeSyncTelemetryOutcome) async {
        let externalSignals = await externalSignalProvider.currentSignals()
        telemetry.emit(
            telemetryEvent(
                receipt: receipt,
                operation: .synchronize,
                outcome: outcome,
                recordCount: receipt.downloadedRecordCount,
                assetCount: receipt.downloadedAssetCount,
                quotaExceededFailureCount: receipt.failures.filter { $0.category == .quotaExceeded }.count,
                externalSignals: externalSignals
            ),
            retention: retention
        )
    }

    private func emitDerivedEvents(_ receipt: SyncReceipt) async {
        let externalSignals = await externalSignalProvider.currentSignals()
        let quotaFailureCount = receipt.failures.filter { $0.category == .quotaExceeded }.count
        let derived: [(BoundedOperationKind, Int, PrivacySafeSyncTelemetryOutcome)] = [
            (.outboxReplay, receipt.uploadedOperationIDs.count, receipt.failures.isEmpty ? .succeeded : .failed),
            (.conflictHandling, receipt.conflictCount, receipt.conflictCount == 0 ? .succeeded : .failed),
            (.quarantine, receipt.quarantineCount, receipt.quarantineCount == 0 ? .succeeded : .failed),
            (.quotaHealth, quotaFailureCount, quotaFailureCount == 0 ? .succeeded : .failed),
            (.backupHealth, 0, externalSignals.backupAge.seconds == nil ? .failed : .succeeded),
        ]
        for (operation, aggregateCount, outcome) in derived {
            telemetry.emit(
                telemetryEvent(
                    receipt: receipt,
                    operation: operation,
                    outcome: outcome,
                    recordCount: aggregateCount,
                    assetCount: 0,
                    quotaExceededFailureCount: quotaFailureCount,
                    externalSignals: externalSignals
                ),
                retention: retention
            )
        }
    }

    private func telemetryEvent(
        receipt: SyncReceipt,
        operation: BoundedOperationKind,
        outcome: PrivacySafeSyncTelemetryOutcome,
        recordCount: Int,
        assetCount: Int,
        quotaExceededFailureCount: Int,
        externalSignals: PrivacySafeSyncTelemetryExternalSignals
    ) -> PrivacySafeSyncTelemetryEvent {
        PrivacySafeSyncTelemetryEvent(
            operation: operation,
            outcome: outcome,
            recordCount: recordCount,
            assetCount: assetCount,
            queueDepth: receipt.queueDepth,
            oldestQueuedAgeSeconds: receipt.oldestQueuedAt.map(Self.boundedAge),
            quarantineCount: receipt.quarantineCount,
            conflictCount: receipt.conflictCount,
            quotaExceededFailureCount: quotaExceededFailureCount,
            lastSuccessfulServerContactAgeSeconds: receipt.lastSuccessfulServerContact.map(Self.boundedAge),
            externalQuota: externalSignals.quota,
            externalBackupAge: externalSignals.backupAge,
            failureCategory: receipt.failures.first.map(Self.telemetryFailureCategory)
        )
    }

    private static func telemetryFailureCategory(_ failure: SyncFailure) -> PrivacySafeSyncTelemetryFailureCategory {
        switch failure.category {
        case .network, .rateLimited, .quotaExceeded, .accountUnavailable, .permissionDenied:
            transportFailureCategory(failure.category)
        case .validation, .conflict, .malformedRemoteRecord, .security, .unknown:
            dataFailureCategory(failure.category)
        }
    }

    private static func transportFailureCategory(_ category: SyncFailureCategory) -> PrivacySafeSyncTelemetryFailureCategory {
        switch category {
        case .network: .networkFlap
        case .rateLimited: .rateLimited
        case .quotaExceeded: .quotaExceeded
        case .accountUnavailable: .accountUnavailable
        default: .permissionDenied
        }
    }

    private static func dataFailureCategory(_ category: SyncFailureCategory) -> PrivacySafeSyncTelemetryFailureCategory {
        switch category {
        case .validation: .validation
        case .conflict: .conflict
        case .malformedRemoteRecord: .malformedRemoteRecord
        case .security: .security
        default: .unknown
        }
    }

    private static func telemetryOutcome(for receipt: SyncReceipt) -> PrivacySafeSyncTelemetryOutcome {
        if Task.isCancelled { return .cancelled }
        return receipt.failures.isEmpty ? .succeeded : .failed
    }

    private static func boundedAge(since date: Date) -> Int {
        let seconds = Date.now.timeIntervalSince(date)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds >= Double(Int.max) ? Int.max : Int(seconds)
    }

    /// Maintenance is scheduled only after the successful sync receipt has
    /// been recorded. Its failures are intentionally detached from foreground
    /// sync semantics and its bounded core policy prevents indefinite work.
    private func scheduleStagedTransferGC(after receipt: SyncReceipt, in namespace: PersistenceNamespace) {
        guard receipt.failures.isEmpty, let stagedTransferGC else { return }
        Task { try? await stagedTransferGC.collect(in: namespace.workspaceZone) }
    }
}

private struct NoopPrivacySafeSyncOperationSignposting: PrivacySafeSyncOperationSignposting {
    func beginForegroundSynchronizeOperation() -> PrivacySafeSyncOperationSignpost {
        PrivacySafeSyncOperationSignpost()
    }

    func endForegroundSynchronizeOperation(_ operation: PrivacySafeSyncOperationSignpost) {}
}

@MainActor
final class ProductionWorkspaceAccessReader: ProductionWorkspaceAccessReading {
    private let account: AccountContext
    private let workspaceName: String
    private let policyVersion: String
    private let sessionAuthorizer: ProductionSessionAuthorizer

    init(account: AccountContext, workspaceName: String, policyVersion: String, sessionAuthorizer: ProductionSessionAuthorizer) {
        self.account = account
        self.workspaceName = workspaceName
        self.policyVersion = policyVersion
        self.sessionAuthorizer = sessionAuthorizer
    }

    func workspaceAccess(in namespace: PersistenceNamespace) async throws -> WorkspaceAccessPresentation {
        guard namespace == account.namespace else {
            throw ProductionAdapterError.namespaceMismatch
        }
        let trusted = try await sessionAuthorizer.verifiedSession(namespace: namespace)
        return WorkspaceAccessPresentation(
            workspaceName: workspaceName, accountRecordName: trusted.actor.cloudKitUserRecordName, role: trusted.actor.role,
            permission: trusted.account.sharePermission, policyVersion: policyVersion, disclosure: OfficialClientPolicy.limitation
        )
    }
}
