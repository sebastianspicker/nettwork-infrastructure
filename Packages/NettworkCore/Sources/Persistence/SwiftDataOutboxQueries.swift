import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

/// Accepted outbox history is retained (receipts and audit read it), so the hot paths avoid decoding it:
/// they read only the unaccepted rows and the `operationID` column of accepted ones.
extension SwiftDataPersistenceStore {
    func unacceptedOperations(namespace: PersistenceNamespace) throws -> [OutboxOperation] {
        try decodedOperations(
            from: unacceptedOutboxModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace)), namespace: namespace)
    }

    public func unacceptedOperations(
        in namespace: PersistenceNamespace
    ) async throws -> (operations: [OutboxOperation], acceptedIDs: Set<ObjectID>) {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        let accepted = OutboxState.accepted.rawValue
        var descriptor = FetchDescriptor<OutboxMutationModel>(
            predicate: #Predicate { $0.namespaceKey == key && $0.stateRaw == accepted && $0.receiptData != nil })
        descriptor.propertiesToFetch = [\.operationID]
        let acceptedIDs = try modelContext.fetch(descriptor).compactMap { UUID(uuidString: $0.operationID).map(ObjectID.init) }
        return (try unacceptedOperations(namespace: namespace), Set(acceptedIDs))
    }

    func outboxStatus(namespace: PersistenceNamespace) throws -> OutboxStatus {
        let key = PersistenceNamespaceKey.value(for: namespace)
        let accepted = OutboxState.accepted.rawValue
        let acceptedCount = try modelContext.fetchCount(
            FetchDescriptor<OutboxMutationModel>(predicate: #Predicate { $0.namespaceKey == key && $0.stateRaw == accepted }))
        let queued = try unacceptedOutboxModels(namespaceKey: key).filter { !$0.operationData.isEmpty }
        var counts: [OutboxState: Int] = [.pending: 0, .uploading: 0, .retryScheduled: 0, .conflicted: 0, .poisoned: 0, .accepted: acceptedCount]
        for model in queued {
            guard let state = OutboxState(rawValue: model.stateRaw) else { throw PersistenceStoreError.malformedStoredValue("outbox state") }
            counts[state, default: 0] += 1
        }
        return OutboxStatus(
            totalCount: acceptedCount + queued.count, queueDepth: queued.count, acceptedHistoryCount: acceptedCount, countsByState: counts,
            oldestQueuedAt: queued.map(\.createdAt).min(),
            nextRetryAt: queued.filter { $0.stateRaw == OutboxState.retryScheduled.rawValue }.compactMap(\.nextRetryAt).min())
    }

    private func unacceptedOutboxModels(namespaceKey key: String) throws -> [OutboxMutationModel] {
        let accepted = OutboxState.accepted.rawValue
        return try modelContext.fetch(FetchDescriptor<OutboxMutationModel>(predicate: #Predicate { $0.namespaceKey == key && $0.stateRaw != accepted }))
    }
}
