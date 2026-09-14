import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    public func enqueue(_ operation: OutboxOperation) async throws {
        try transaction {
            try validateActiveLease(for: operation.namespace)
            try validateNewOperation(operation)
            let key = PersistenceNamespaceKey.storageKey(namespace: operation.namespace, identity: "outbox:\(operation.operationID.description)")
            guard try outboxModel(matching: key) == nil else {
                throw PersistenceStoreError.duplicateOperation(operation.operationID)
            }
            let existing = try decodedOperations(namespace: operation.namespace)
            for dependencyID in operation.dependencyOperationIDs {
                guard existing.contains(where: { $0.operationID == dependencyID }) else {
                    throw PersistenceStoreError.missingDependency(operation.operationID, dependencyID)
                }
            }
            for earlier in existing where earlier.state != .accepted && !earlier.resourceKeys.isDisjoint(with: operation.resourceKeys) {
                guard operation.dependencyOperationIDs.contains(earlier.operationID) else {
                    throw PersistenceStoreError.missingSharedResourceDependency(operation.operationID, earlier.operationID)
                }
            }
            modelContext.insert(try OutboxMutationModel(operation: operation))
        }
    }

    public func operationsReady(at date: Date, in namespace: PersistenceNamespace) async throws -> [OutboxOperation] {
        try validateActiveLease(for: namespace)
        let operations = try decodedOperations(namespace: namespace)
        let accepted = Set(operations.filter { $0.state == .accepted && $0.receipt != nil }.map(\.operationID))
        return operations.filter { operation in
            guard operation.state == .pending || operation.state == .retryScheduled else { return false }
            guard operation.nextRetryAt.map({ $0 <= date }) ?? true else { return false }
            return operation.dependencyOperationIDs.isSubset(of: accepted)
        }.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.operationID < rhs.operationID
        }
    }

    public func operations(in namespace: PersistenceNamespace) async throws -> [OutboxOperation] {
        try validateActiveLease(for: namespace)
        return try decodedOperations(namespace: namespace).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.operationID < rhs.operationID
        }
    }

    public func status(in namespace: PersistenceNamespace) async throws -> OutboxStatus {
        try validateActiveLease(for: namespace)
        return OutboxStatus.summarize(try decodedOperations(namespace: namespace))
    }

    /// Retained v1 rows that cannot be executed because their immutable
    /// envelope/base snapshot was never persisted. Callers surface these as
    /// reconciliation evidence; persistence never turns them into mutations.
    public func legacyOutboxEvidence(in namespace: PersistenceNamespace) throws -> [LegacyOutboxEvidence] {
        try validateActiveLease(for: namespace)
        return try outboxModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace)).compactMap { model in
            guard model.operationData.isEmpty,
                let kind = model.kind,
                let payload = model.payload,
                let baseChangeTags = model.baseChangeTags
            else {
                return nil
            }
            return LegacyOutboxEvidence(
                operationID: model.operationID, namespaceKey: model.namespaceKey,
                kind: kind, payload: payload, baseChangeTags: baseChangeTags, createdAt: model.createdAt,
                attemptCount: model.attemptCount, lastError: model.lastError)
        }.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.operationID < rhs.operationID
        }
    }

    public func recordAttempt(operationID: ObjectID, at date: Date, namespace: PersistenceNamespace) async throws {
        try mutateOperation(operationID: operationID, namespace: namespace) { operation in
            guard operation.state == .pending || operation.state == .retryScheduled,
                operation.nextRetryAt.map({ $0 <= date }) ?? true
            else {
                throw PersistenceStoreError.invalidLifecycleTransition(operationID)
            }
            operation.state = .uploading
            operation.attemptCount += 1
            operation.nextRetryAt = nil
        }
    }

    public func recordFailure(operationID: ObjectID, failure: SyncFailure, nextRetryAt: Date?, poison: Bool, namespace: PersistenceNamespace) async throws {
        try mutateOperation(operationID: operationID, namespace: namespace) { operation in
            guard operation.state == .uploading else { throw PersistenceStoreError.invalidLifecycleTransition(operationID) }
            operation.lastFailure = failure
            if poison {
                operation.state = .poisoned
                operation.nextRetryAt = nil
            } else if failure.category == .conflict {
                operation.state = .conflicted
                operation.nextRetryAt = nil
            } else {
                guard let nextRetryAt else { throw PersistenceStoreError.invalidLifecycleTransition(operationID) }
                operation.state = .retryScheduled
                operation.nextRetryAt = nextRetryAt
            }
        }
    }

    public func recordAcceptance(operationID: ObjectID, receipt: OperationReceipt, namespace: PersistenceNamespace) async throws {
        try transaction {
            try validateActiveLease(for: namespace)
            guard receipt.workspaceZone == namespace.workspaceZone, receipt.operationID == operationID else {
                throw PersistenceStoreError.invalidReceipt(operationID)
            }
            let operationKey = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "outbox:\(operationID.description)")
            guard let operationModel = try outboxModel(matching: operationKey) else {
                throw PersistenceStoreError.unknownOperation(operationID)
            }
            var operation = try PersistenceCoding.decode(OutboxOperation.self, from: operationModel.operationData)
            guard operation.namespace == namespace, operation.operationID == operationID,
                operation.state == .uploading,
                receipt.intentDigest == operation.envelope.mutation.intentDigest,
                receipt.auditEventID == operation.envelope.mutation.auditEvent.id
            else {
                throw PersistenceStoreError.invalidReceipt(operationID)
            }
            let receiptKey = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "receipt:\(operationID.description)")
            if let existing = try receiptModel(matching: receiptKey) {
                let existingReceipt = try PersistenceCoding.decode(OperationReceipt.self, from: existing.receiptData)
                guard existingReceipt == receipt else { throw PersistenceStoreError.invalidReceipt(operationID) }
            } else {
                modelContext.insert(try OperationReceiptModel(receipt: receipt, namespace: namespace, acceptedAt: .now))
            }
            operation.state = .accepted
            operation.receipt = receipt
            operation.nextRetryAt = nil
            operation.lastFailure = nil
            operationModel.operationData = try PersistenceCoding.encode(operation)
            operationModel.stateRaw = operation.state.rawValue
            operationModel.attemptCount = operation.attemptCount
            operationModel.nextRetryAt = nil
            operationModel.lastFailureData = nil
            operationModel.receiptData = try PersistenceCoding.encode(receipt)
        }
    }

    public func receipt(for operationID: ObjectID, in namespace: PersistenceNamespace) throws -> OperationReceipt? {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "receipt:\(operationID.description)")
        guard let model = try receiptModel(matching: key) else { return nil }
        return try PersistenceCoding.decode(OperationReceipt.self, from: model.receiptData)
    }

    // MARK: ConflictResolver

    public func capture(_ conflict: ReconciliationCase) async throws {
        try transaction {
            try validateActiveLease(for: conflict.namespace)
            let key = PersistenceNamespaceKey.storageKey(namespace: conflict.namespace, identity: "conflict:\(conflict.id.description)")
            guard try conflictModel(matching: key) == nil else { return }
            modelContext.insert(try LocalConflictModel(case: conflict))
            for resourceKey in conflict.resourceKeys.sorted() {
                modelContext.insert(try LocalConflictResourceIndexModel(case: conflict, resourceKey: resourceKey))
            }
        }
    }

    /// Exact unresolved conflict membership without decoding or truncating the
    /// reconciliation payload list. The index cardinality is bounded and a
    /// limit overflow fails closed rather than producing false negatives.
    public func unresolvedConflictResourceKeys(
        in namespace: PersistenceNamespace, limit: Int = 250_000
    ) throws -> Set<ResourceKey> {
        guard (1...250_000).contains(limit) else { throw PersistenceStoreError.invalidReadLimit }
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        var descriptor = FetchDescriptor<LocalConflictResourceIndexModel>(
            predicate: #Predicate { $0.namespaceKey == key },
            sortBy: [SortDescriptor(\.resourceKeyDescription), SortDescriptor(\.conflictID)])
        descriptor.fetchLimit = limit + 1
        let models = try modelContext.fetch(descriptor)
        guard models.count <= limit else {
            throw PersistenceStoreError.conflictResourceIndexCapacityExceeded(models.count)
        }
        return try Set(
            models.map { model in
                try PersistenceCoding.decode(ResourceKey.self, from: model.resourceKeyData)
            })
    }

    /// Backfills the additive V7 index from durable unresolved cases.
    public func rebuildConflictResourceIndex(in namespace: PersistenceNamespace) throws {
        try transaction {
            try validateActiveLease(for: namespace)
            let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
            let existing = try conflictResourceIndexModels(namespaceKey: namespaceKey)
            existing.forEach(modelContext.delete)
            let conflicts = try conflictModels(namespaceKey: namespaceKey).filter { !$0.isResolved }
                .map { try PersistenceCoding.decode(ReconciliationCase.self, from: $0.conflictData) }
                .filter { $0.namespace == namespace }
            let count = conflicts.reduce(0) { $0 + $1.resourceKeys.count }
            guard count <= 250_000 else {
                throw PersistenceStoreError.conflictResourceIndexCapacityExceeded(count)
            }
            for conflict in conflicts {
                for resourceKey in conflict.resourceKeys.sorted() {
                    modelContext.insert(try LocalConflictResourceIndexModel(case: conflict, resourceKey: resourceKey))
                }
            }
        }
    }

    public func unresolvedCases(in namespace: PersistenceNamespace) async throws -> [ReconciliationCase] {
        try validateActiveLease(for: namespace)
        return try conflictModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            .filter { !$0.isResolved }
            .map { try PersistenceCoding.decode(ReconciliationCase.self, from: $0.conflictData) }
            .filter { $0.namespace == namespace }.sorted { $0.detectedAt < $1.detectedAt }
    }

    public func unresolvedCases(in namespace: PersistenceNamespace, limit: Int) throws -> [ReconciliationCase] {
        guard (1...10_000).contains(limit) else { throw PersistenceStoreError.invalidReadLimit }
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        var descriptor = FetchDescriptor<LocalConflictModel>(predicate: #Predicate { $0.namespaceKey == key && !$0.isResolved })
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
            .map { try PersistenceCoding.decode(ReconciliationCase.self, from: $0.conflictData) }
            .filter { $0.namespace == namespace }.sorted { $0.detectedAt < $1.detectedAt }
    }

    public func unresolvedConflictCount(in namespace: PersistenceNamespace) throws -> Int {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        let descriptor = FetchDescriptor<LocalConflictModel>(predicate: #Predicate { $0.namespaceKey == key && !$0.isResolved })
        return try modelContext.fetchCount(descriptor)
    }
}
