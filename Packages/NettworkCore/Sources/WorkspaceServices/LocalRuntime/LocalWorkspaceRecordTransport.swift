import CloudSync
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Record transport of the local backend, with the semantics of
/// `CloudKitRecordTransport` over one durable `LocalWorkspaceRecordStore`.
///
/// Every write is one conditional all-or-nothing store commit: all
/// preconditions are checked against stored state (tombstones included) before
/// anything is written, and a conflict reports a `ReconciliationCase` scoped to
/// the whole batch. Each written record gets a fresh change tag and a
/// millisecond-truncated server time. Fetches are stateless: the change token
/// persisted with the mirror transaction is read back through the state store.
/// The transport serves exactly the namespace it was created for.
public actor LocalWorkspaceRecordTransport: CloudRecordTransport, CloudConditionalBatchTransport, CloudReceiptLookupTransport, CloudExactRecordReading,
    CloudAppliedChangeStatePersisting
{
    static let maximumBatchRecords = 250_000
    static let maximumBatchBytes = 256 * 1_024 * 1_024
    static let maximumCommitAttempts = 3

    let store: LocalWorkspaceRecordStore
    let account: AccountContext
    let stateStore: any CloudKitSyncEngineStateStore
    let now: @Sendable () -> Date
    /// Test-only fault hook (default off): matching mutations commit, then report an indeterminate outcome.
    private var indeterminateAfterCommit: (@Sendable (AtomicCloudMutation) -> Bool)?
    private(set) var injectedIndeterminateCommitCount = 0

    /// Throws `unsupportedNamespace` unless `account` is a local owner-private namespace.
    public init(
        store: LocalWorkspaceRecordStore, account: AccountContext, stateStore: any CloudKitSyncEngineStateStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard account.namespace.containerIdentifier.hasPrefix(LocalWorkspaceIdentity.containerPrefix), account.databaseScope == .ownerPrivate,
            account.sharePermission == .owner
        else { throw LocalWorkspaceRecordTransportError.unsupportedNamespace }
        self.store = store
        self.account = account
        self.stateStore = stateStore
        self.now = now
    }

    /// Test-only: makes every later commit of a mutation matching `predicate` persist and then report indeterminate.
    func injectIndeterminateCommits(where predicate: (@Sendable (AtomicCloudMutation) -> Bool)?) {
        indeterminateAfterCommit = predicate
    }

    var workspaceZone: AuthoritativeWorkspaceZone { account.namespace.workspaceZone }

    public func fetchChanges() async throws -> CloudChangeBatch {
        let persisted = try await stateStore.persistedState(in: account.namespace)
        return try await changeBatch(after: persisted)
    }

    public func persistAppliedChangeState(_ state: Data) async throws {
        try await stateStore.persistAppliedState(state, in: account.namespace)
    }

    public func saveAtomically(_ mutation: AtomicCloudMutation) async throws -> CloudSaveResult {
        guard mutation.workspaceZone == workspaceZone else {
            return .permanentFailure(SyncFailure(category: .security, message: "Atomic mutation escaped the verified workspace zone."))
        }
        let resourceKeys = Set(mutation.records.map(\.resourceKey))
        do {
            try AtomicCloudMutationValidator.validate(mutation)
            let receipt = try Self.receipt(in: mutation)
            switch try await commit(mutation) {
            case .committed: return .accepted(receipt: receipt)
            case let .conflict(envelope, stored): return .conflict(reconciliationCase(for: mutation, conflicting: envelope, stored: stored))
            }
        } catch is LocalSimulatedIndeterminateCommit {
            throw CloudTransportFailure(Self.indeterminateFailure(resourceKeys), possiblyCommitted: true)
        } catch {
            let classified = Self.classify(error, resourceKeys: resourceKeys)
            return classified.isRetryable ? .retryableFailure(classified.failure) : .permanentFailure(classified.failure)
        }
    }

    /// Receipt-free conditional batch for staged transfers, on the same commit core.
    public func saveConditionally(_ mutation: AtomicCloudMutation) async throws -> CloudConditionalBatchResult {
        guard mutation.workspaceZone == workspaceZone else {
            return .permanent(SyncFailure(category: .security, message: "Conditional mutation escaped the verified workspace zone."))
        }
        let resourceKeys = Set(mutation.records.map(\.resourceKey))
        do {
            try AtomicCloudMutationValidator.validate(mutation)
            switch try await commit(mutation) {
            case .committed: return .accepted
            case .conflict: return .conflict
            }
        } catch is LocalSimulatedIndeterminateCommit {
            return .indeterminate(Self.indeterminateFailure(resourceKeys))
        } catch {
            let classified = Self.classify(error, resourceKeys: resourceKeys)
            return classified.isRetryable ? .retryable(classified.failure) : .permanent(classified.failure)
        }
    }

    public func receipt(operationID: ObjectID, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> OperationReceipt? {
        let key = ResourceKey.operationReceipt(operationID: operationID)
        guard let stored = try await liveRecord(for: key, in: workspaceZone) else { return nil }
        guard stored.recordType == CloudRecordNaming.receiptRecordType else { throw LocalWorkspaceRecordTransportError.malformedStoredRecord(key) }
        return try CloudDeterministicCoding.decode(OperationReceipt.self, from: stored.payload)
    }

    public func exactRecord(for resourceKey: ResourceKey, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudExactRecordSnapshot? {
        guard let stored = try await liveRecord(for: resourceKey, in: workspaceZone) else { return nil }
        guard stored.schemaVersion > 0, !stored.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !stored.systemFields.isEmpty else {
            throw LocalWorkspaceRecordTransportError.malformedStoredRecord(resourceKey)
        }
        return CloudExactRecordSnapshot(
            workspaceZone: workspaceZone, resourceKey: resourceKey, recordType: stored.recordType, schemaVersion: stored.schemaVersion,
            payload: stored.payload, exactPrecondition: ExactRecordPrecondition(systemFields: stored.systemFields, changeTag: stored.changeTag),
            serverModifiedAt: stored.serverModifiedAt)
    }

    /// The stored record for `key`, nil if it never existed; throws for another zone or a tombstone.
    private func liveRecord(for key: ResourceKey, in requestedZone: AuthoritativeWorkspaceZone) async throws -> LocalStoredRecord? {
        guard requestedZone == workspaceZone else { throw LocalWorkspaceRecordTransportError.zoneMismatch }
        guard let stored = try await store.record(for: key, workspaceID: requestedZone.workspaceID) else { return nil }
        guard stored.resourceKey == key, stored.workspaceID == requestedZone.workspaceID else {
            throw LocalWorkspaceRecordTransportError.malformedStoredRecord(key)
        }
        guard !stored.isDeleted else { throw LocalWorkspaceRecordTransportError.tombstonedRecord(key) }
        return stored
    }

    /// Consulted by the commit core after a successful store commit.
    func shouldReportIndeterminate(after mutation: AtomicCloudMutation) -> Bool {
        guard let indeterminateAfterCommit, indeterminateAfterCommit(mutation) else { return false }
        injectedIndeterminateCommitCount += 1
        return true
    }

    private static func receipt(in mutation: AtomicCloudMutation) throws -> OperationReceipt {
        guard let envelope = mutation.records.first(where: { $0.recordType == CloudRecordNaming.receiptRecordType }) else {
            throw LocalWorkspaceRecordTransportError.receiptPayloadMissing
        }
        return try CloudDeterministicCoding.decode(OperationReceipt.self, from: envelope.payload)
    }

    private static func indeterminateFailure(_ resourceKeys: Set<ResourceKey>) -> SyncFailure {
        SyncFailure(category: .network, message: "The local commit outcome is indeterminate (simulated).", resourceKeys: resourceKeys)
    }

    /// Store I/O failures commit nothing and are retryable; everything else is permanent.
    static func classify(_ error: any Error, resourceKeys: Set<ResourceKey>) -> (failure: SyncFailure, isRetryable: Bool) {
        let message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        switch error as? LocalWorkspaceRecordStoreError {
        case .readFailed, .writeFailed, .revisionConflict:
            return (SyncFailure(category: .network, message: message, resourceKeys: resourceKeys), true)
        case .snapshotTooLarge:
            return (SyncFailure(category: .quotaExceeded, message: message, resourceKeys: resourceKeys), true)
        case .some, .none:
            return (SyncFailure(category: .validation, message: message, resourceKeys: resourceKeys), false)
        }
    }
}
