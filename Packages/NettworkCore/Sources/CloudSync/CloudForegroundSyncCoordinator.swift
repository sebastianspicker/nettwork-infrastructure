import Foundation
import NetworkModel
import WorkspaceChangeControl

public protocol CloudForegroundActorContextProvider: Sendable {
    func actorContext(for account: AccountContext) async throws -> ActorContext
}

public protocol CloudForegroundMembershipVerifying: Sendable {
    func verifyForegroundMembership() async throws -> CloudSessionEvent
}

/// Foreground-only ingestion coordinator. It deliberately has no fallback to an
/// unscoped local cache and never applies a subset of a rejected remote batch.
public actor CloudForegroundSyncCoordinator: SyncCoordinator {
    private let session: CloudSessionLifecycle
    private let transport: any CloudRecordTransport
    private let mirror: any CloudMirrorStore
    private let membershipVerifier: any CloudForegroundMembershipVerifying
    private let validator: CloudRemoteRecordValidator
    private let outboxReplayer: CloudOutboxReplayer
    private let actorContextProvider: any CloudForegroundActorContextProvider
    private let mutationStateProvider: any AuthoritativeMutationStateProviding

    /// Production composition is deliberately complete: foreground sync always
    /// verifies membership and replays eligible durable work after ingestion.
    public init(
        session: CloudSessionLifecycle, transport: any CloudRecordTransport, mirror: any CloudMirrorStore,
        membershipVerifier: any CloudForegroundMembershipVerifying,
        validator: CloudRemoteRecordValidator = .init(), outboxReplayer: CloudOutboxReplayer, actorContextProvider: any CloudForegroundActorContextProvider,
        mutationStateProvider: any AuthoritativeMutationStateProviding
    ) {
        self.session = session
        self.transport = transport
        self.mirror = mirror
        self.membershipVerifier = membershipVerifier
        self.validator = validator
        self.outboxReplayer = outboxReplayer
        self.actorContextProvider = actorContextProvider
        self.mutationStateProvider = mutationStateProvider
    }

    public func synchronizeForeground() async -> SyncReceipt {
        let started = Date.now
        do { _ = try await membershipVerifier.verifyForegroundMembership() } catch {
            return SyncReceipt(startedAt: started, finishedAt: .now, failures: [CloudFailureClassifier.classify(error)])
        }
        guard let context = await session.activeContext() else { return unavailableReceipt(started: started) }
        guard let lease = await session.activeLease() else { return unavailableReceipt(started: started) }
        return await synchronize(started: started, account: context, lease: lease)
    }

    private func unavailableReceipt(started: Date) -> SyncReceipt {
        SyncReceipt(
            startedAt: started, finishedAt: .now,
            failures: [SyncFailure(category: .accountUnavailable, message: "No active verified CloudKit account context.")]
        )
    }

    private func synchronize(started: Date, account context: AccountContext, lease: CloudSessionLease) async -> SyncReceipt {
        var appliedRecordCount = 0
        var appliedAssetCount = 0
        do {
            let batch = try await transport.fetchChanges()
            guard await session.isCurrent(lease) else {
                return SyncReceipt(
                    startedAt: started, finishedAt: .now,
                    failures: [SyncFailure(category: .accountUnavailable, message: "Cloud account changed during foreground sync.")])
            }
            let verified: [VerifiedCloudRecord]
            do {
                verified = try validator.validate(batch, namespace: context.namespace)
            } catch {
                return await rejectedBatchReceipt(started: started, batch: batch, account: context, lease: lease, error: error)
            }
            guard await session.isCurrent(lease) else {
                return SyncReceipt(
                    startedAt: started, finishedAt: .now,
                    failures: [SyncFailure(category: .accountUnavailable, message: "Cloud account changed before local transaction.")])
            }
            do {
                try await mirror.validateRemoteReferences(verified, namespace: context.namespace)
            } catch {
                return await rejectedBatchReceipt(started: started, batch: batch, account: context, lease: lease, error: error)
            }
            guard await session.isCurrent(lease) else {
                return SyncReceipt(
                    startedAt: started, finishedAt: .now,
                    failures: [SyncFailure(category: .accountUnavailable, message: "Cloud account changed during remote validation.")])
            }
            try await mirror.applyVerifiedBatch(verified, syncState: batch.newState, namespace: context.namespace)
            appliedRecordCount = verified.count
            appliedAssetCount = verified.lazy.filter { $0.envelope.recordAsset != nil }.count
            try await persistAppliedChangeState(batch.newState)
            guard await session.isCurrent(lease) else {
                return SyncReceipt(
                    startedAt: started, finishedAt: .now, downloadedRecordCount: appliedRecordCount, downloadedAssetCount: appliedAssetCount,
                    failures: [
                        SyncFailure(
                            category: .accountUnavailable,
                            message: "Cloud account changed after local transaction.")
                    ])
            }
            let replay = try await replayForegroundOutbox(account: context, lease: lease)
            let status = try await mirror.syncStatus(namespace: context.namespace)
            return receipt(
                started: started, uploadedOperationIDs: replay.uploadedOperationIDs,
                downloadedRecordCount: appliedRecordCount, downloadedAssetCount: appliedAssetCount,
                failures: replay.failures, status: status)
        } catch {
            return await failedSyncReceipt(
                started: started, account: context, lease: lease, error: error,
                downloadedRecordCount: appliedRecordCount, downloadedAssetCount: appliedAssetCount)
        }
    }

    private func persistAppliedChangeState(_ state: Data) async throws {
        guard let statePersistence = transport as? any CloudAppliedChangeStatePersisting else { return }
        try await statePersistence.persistAppliedChangeState(state)
    }

    private func failedSyncReceipt(
        started: Date, account: AccountContext, lease: CloudSessionLease, error: Error, downloadedRecordCount: Int, downloadedAssetCount: Int
    ) async -> SyncReceipt {
        var failures = [CloudFailureClassifier.classify(error)]
        do {
            let replay = try await replayForegroundOutbox(account: account, lease: lease)
            failures.append(contentsOf: replay.failures)
            let status = try await mirror.syncStatus(namespace: account.namespace)
            return receipt(
                started: started, uploadedOperationIDs: replay.uploadedOperationIDs, downloadedRecordCount: downloadedRecordCount,
                downloadedAssetCount: downloadedAssetCount, failures: failures, status: status)
        } catch { failures.append(CloudFailureClassifier.classify(error)) }
        let status = await statusAfterFailure(account: account, failures: &failures)
        return receipt(
            started: started, downloadedRecordCount: downloadedRecordCount, downloadedAssetCount: downloadedAssetCount, failures: failures, status: status)
    }

    private func statusAfterFailure(account: AccountContext, failures: inout [SyncFailure]) async -> CloudMirrorStatus? {
        do { return try await mirror.syncStatus(namespace: account.namespace) } catch {
            failures.append(CloudFailureClassifier.classify(error))
            return nil
        }
    }

    private func rejectedBatchReceipt(started: Date, batch: CloudChangeBatch, account: AccountContext, lease: CloudSessionLease, error: Error) async
        -> SyncReceipt
    {
        var failures = [CloudFailureClassifier.classify(error)]
        for record in CloudRemoteQuarantineSelection.records(in: batch, validator: validator, error: error) {
            guard await session.isCurrent(lease) else {
                failures.append(SyncFailure(category: .accountUnavailable, message: "Cloud account changed before remote quarantine."))
                return receipt(started: started, failures: failures, status: nil)
            }
            do {
                try await mirror.quarantine(try QuarantinedCloudRecord(envelope: record, reason: String(describing: error)), namespace: account.namespace)
            } catch { failures.append(CloudFailureClassifier.classify(error)) }
        }
        var uploadedOperationIDs: [ObjectID] = []
        do {
            let replay = try await replayForegroundOutbox(account: account, lease: lease)
            uploadedOperationIDs = replay.uploadedOperationIDs
            failures.append(contentsOf: replay.failures)
        } catch {
            failures.append(CloudFailureClassifier.classify(error))
        }
        let status: CloudMirrorStatus?
        do { status = try await mirror.syncStatus(namespace: account.namespace) } catch {
            failures.append(CloudFailureClassifier.classify(error))
            status = nil
        }
        return receipt(started: started, uploadedOperationIDs: uploadedOperationIDs, failures: failures, status: status)
    }

    private func replayForegroundOutbox(account: AccountContext, lease: CloudSessionLease) async throws -> CloudReplayResult {
        guard await session.isCurrent(lease) else { throw CloudSessionError.superseded }
        let actor = try await actorContextProvider.actorContext(for: account)
        guard await session.isCurrent(lease) else { throw CloudSessionError.superseded }
        return await outboxReplayer.replay(
            namespace: account.namespace, account: account, actor: actor,
            stateProvider: mutationStateProvider)
    }

    private func receipt(
        started: Date, uploadedOperationIDs: [ObjectID] = [],
        downloadedRecordCount: Int = 0, downloadedAssetCount: Int = 0, failures: [SyncFailure],
        status: CloudMirrorStatus?
    ) -> SyncReceipt {
        SyncReceipt(
            startedAt: started, finishedAt: .now, uploadedOperationIDs: uploadedOperationIDs,
            downloadedRecordCount: downloadedRecordCount, downloadedAssetCount: downloadedAssetCount,
            failures: failures, queueDepth: status?.queueDepth ?? 0, oldestQueuedAt: status?.oldestQueuedAt,
            quarantineCount: status?.quarantineCount ?? 0, conflictCount: status?.conflictCount ?? 0,
            lastSuccessfulServerContact: status?.lastSuccessfulServerContact)
    }
}
