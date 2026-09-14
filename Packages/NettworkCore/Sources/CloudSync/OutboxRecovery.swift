import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum LostReceiptResolution: Hashable, Sendable {
    case accepted(OperationReceipt)
    case retry
    case securityMismatch(OperationReceipt)
}

public enum LostReceiptRecovery {
    public static func resolve(expected: OperationReceipt, observed: OperationReceipt?) -> LostReceiptResolution {
        guard let observed else { return .retry }
        return observed == expected ? .accepted(observed) : .securityMismatch(observed)
    }
}

public struct ReconciliationBuilder {
    public init() {}

    public func make(
        namespace: PersistenceNamespace, operation: OutboxOperation, reason: ReconciliationReason, current: [CloudRecordEnvelope], isSecurityEvent: Bool = false
    ) throws -> ReconciliationCase {
        var intended: [ResourceKey: ReconciliationSnapshot] = [:]
        for save in operation.envelope.mutation.saves {
            intended[save.resourceKey] = ReconciliationSnapshot(
                resourceKey: save.resourceKey, recordType: save.recordType, schemaVersion: save.schemaVersion, encodedRecord: save.encodedRecord,
                systemFields: nil,
                changeTag: nil, isTombstone: false)
        }
        for tombstone in operation.envelope.mutation.tombstones {
            intended[tombstone.resourceKey] = ReconciliationSnapshot(
                resourceKey: tombstone.resourceKey, recordType: tombstone.recordType, schemaVersion: CloudRecordNaming.schemaVersion,
                encodedRecord: tombstone.encodedTombstone, systemFields: nil, changeTag: nil, isTombstone: true)
        }
        let mutation = operation.envelope.mutation
        intended[.object(mutation.workOrder.id)] = ReconciliationSnapshot(
            resourceKey: .object(mutation.workOrder.id), recordType: CloudRecordNaming.workOrderRecordType, schemaVersion: CloudRecordNaming.schemaVersion,
            encodedRecord: mutation.encodedWorkOrder, systemFields: nil, changeTag: nil, isTombstone: false)
        intended[.object(mutation.auditEvent.id)] = ReconciliationSnapshot(
            resourceKey: .object(mutation.auditEvent.id), recordType: CloudRecordNaming.auditRecordType, schemaVersion: CloudRecordNaming.schemaVersion,
            encodedRecord: mutation.encodedAuditEvent, systemFields: nil, changeTag: nil, isTombstone: false)
        intended[mutation.receipt.id] = ReconciliationSnapshot(
            resourceKey: mutation.receipt.id, recordType: CloudRecordNaming.receiptRecordType, schemaVersion: CloudRecordNaming.schemaVersion,
            encodedRecord: mutation.encodedReceipt, systemFields: nil, changeTag: nil, isTombstone: false)
        var currentSnapshots: [ResourceKey: ReconciliationSnapshot] = [:]
        for record in current {
            currentSnapshots[record.resourceKey] = ReconciliationSnapshot(
                resourceKey: record.resourceKey, recordType: record.recordType, schemaVersion: record.schemaVersion, encodedRecord: record.payload,
                systemFields: record.systemFields, changeTag: record.changeTag, isTombstone: record.isDeleted)
        }
        return ReconciliationCase(
            namespace: namespace, operationID: operation.operationID, resourceKeys: operation.resourceKeys, reason: reason,
            base: operation.envelope.baseSnapshots, intended: intended,
            current: currentSnapshots, isSecurityEvent: isSecurityEvent)
    }
}

public struct OutboxReplayPlan: Sendable {
    public let ordered: [OutboxOperation]
    public let deferredOperationIDs: Set<ObjectID>
    public let cyclicOperationIDs: Set<ObjectID>
    public init(ordered: [OutboxOperation], deferredOperationIDs: Set<ObjectID>, cyclicOperationIDs: Set<ObjectID>) {
        self.ordered = ordered
        self.deferredOperationIDs = deferredOperationIDs
        self.cyclicOperationIDs = cyclicOperationIDs
    }
}

/// Produces a deterministic topological order. Operations sharing an affected
/// resource are serialized by creation time even when callers omitted an edge.
public enum OutboxDependencyPlanner {
    public static func plan(_ operations: [OutboxOperation], at date: Date) -> OutboxReplayPlan {
        let eligible = eligibleOperations(in: operations, at: date)
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.operationID, $0) })
        var dependencies = initialDependencies(for: eligible)
        let accepted = acceptedOperationIDs(in: operations)
        let deferred = deferredOperationIDs(eligible: eligible, byID: byID, dependencies: &dependencies, accepted: accepted)
        let pending = topologicalOrder(eligible: eligible, byID: byID, dependencies: dependencies, deferred: deferred)
        return OutboxReplayPlan(ordered: pending.ordered, deferredOperationIDs: deferred, cyclicOperationIDs: pending.cyclic)
    }

    private static func eligibleOperations(in operations: [OutboxOperation], at date: Date) -> [OutboxOperation] {
        operations.filter { operation in
            switch operation.state {
            case .pending, .retryScheduled: return operation.nextRetryAt.map { $0 <= date } ?? true
            case .uploading, .conflicted, .poisoned, .accepted: return false
            }
        }.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.operationID < rhs.operationID : lhs.createdAt < rhs.createdAt
        }
    }

    private static func initialDependencies(for eligible: [OutboxOperation]) -> [ObjectID: Set<ObjectID>] {
        var dependencies = Dictionary(uniqueKeysWithValues: eligible.map { ($0.operationID, Set($0.dependencyOperationIDs)) })
        for index in eligible.indices {
            for otherIndex in eligible.indices where otherIndex < index {
                let later = eligible[index]
                let earlier = eligible[otherIndex]
                if !later.resourceKeys.isDisjoint(with: earlier.resourceKeys) {
                    dependencies[later.operationID, default: []].insert(earlier.operationID)
                }
            }
        }
        return dependencies
    }

    private static func acceptedOperationIDs(in operations: [OutboxOperation]) -> Set<ObjectID> {
        Set(operations.filter { $0.state == .accepted && $0.receipt != nil }.map(\.operationID))
    }

    private static func deferredOperationIDs(
        eligible: [OutboxOperation], byID: [ObjectID: OutboxOperation], dependencies: inout [ObjectID: Set<ObjectID>], accepted: Set<ObjectID>
    ) -> Set<ObjectID> {
        var deferred = Set<ObjectID>()
        for operation in eligible where !operation.dependencyOperationIDs.allSatisfy({ byID[$0] != nil || accepted.contains($0) }) {
            deferred.insert(operation.operationID)
        }
        var addedDeferred = true
        while addedDeferred {
            addedDeferred = false
            for operation in eligible where !deferred.contains(operation.operationID) {
                if !dependencies[operation.operationID, default: []].isDisjoint(with: deferred) {
                    deferred.insert(operation.operationID)
                    addedDeferred = true
                }
            }
        }
        return deferred
    }

    private static func topologicalOrder(
        eligible: [OutboxOperation], byID: [ObjectID: OutboxOperation], dependencies: [ObjectID: Set<ObjectID>], deferred: Set<ObjectID>
    ) -> (ordered: [OutboxOperation], cyclic: Set<ObjectID>) {
        var pending = Set(eligible.map(\.operationID)).subtracting(deferred)
        var ordered: [OutboxOperation] = []
        while let nextID = pending.filter({ dependencies[$0, default: []].isDisjoint(with: pending) }).sorted(by: stableOrder).first {
            pending.remove(nextID)
            if let operation = byID[nextID] { ordered.append(operation) }
        }
        return (ordered, pending)
    }

    private static func stableOrder(_ lhs: ObjectID, _ rhs: ObjectID) -> Bool { lhs < rhs }
}

public enum RetrySchedule {
    public static func nextRetry(after attemptCount: Int, retryAfter: Date?, now: Date = .now) -> Date? {
        if let retryAfter { return retryAfter }
        let exponent = min(max(attemptCount, 0), 8)
        return now.addingTimeInterval(TimeInterval(1 << exponent) * 5)
    }
}

public struct CloudReplayResult: Sendable {
    public let uploadedOperationIDs: [ObjectID]
    public let failures: [SyncFailure]
    public init(uploadedOperationIDs: [ObjectID] = [], failures: [SyncFailure] = []) {
        self.uploadedOperationIDs = uploadedOperationIDs
        self.failures = failures
    }
}

public actor CloudOutboxReplayer {
    private let transport: any CloudRecordTransport
    private let receiptLookup: (any CloudReceiptLookupTransport)?
    private let outbox: any MutationOutbox
    private let conflicts: any ConflictResolver

    public init(
        transport: any CloudRecordTransport, receiptLookup: (any CloudReceiptLookupTransport)? = nil, outbox: any MutationOutbox,
        conflicts: any ConflictResolver
    ) {
        self.transport = transport
        self.receiptLookup = receiptLookup
        self.outbox = outbox
        self.conflicts = conflicts
    }

    public func replay(
        namespace: PersistenceNamespace, account: AccountContext, actor: ActorContext,
        stateProvider: any AuthoritativeMutationStateProviding, now: Date = .now
    ) async -> CloudReplayResult {
        var failures: [SyncFailure] = []
        var uploaded: [ObjectID] = []
        do {
            let operations = try await outbox.operations(in: namespace)
            let plan = OutboxDependencyPlanner.plan(operations, at: now)
            failures.append(contentsOf: await poisonCycles(plan.cyclicOperationIDs, namespace: namespace, now: now))
            for operation in plan.ordered {
                let result = await replay(operation, namespace: namespace, account: account, actor: actor, stateProvider: stateProvider, now: now)
                failures.append(contentsOf: result.failures)
                uploaded.append(contentsOf: result.uploadedOperationIDs)
            }
        } catch {
            failures.append(CloudFailureClassifier.classify(error))
        }
        return CloudReplayResult(uploadedOperationIDs: uploaded, failures: failures)
    }

    private func poisonCycles(_ cycles: Set<ObjectID>, namespace: PersistenceNamespace, now: Date) async -> [SyncFailure] {
        var failures: [SyncFailure] = []
        for cycle in cycles.sorted() {
            let failure = SyncFailure(category: .validation, message: "Outbox dependency cycle.")
            do {
                try await outbox.recordAttempt(operationID: cycle, at: now, namespace: namespace)
                try await outbox.recordFailure(operationID: cycle, failure: failure, nextRetryAt: nil, poison: true, namespace: namespace)
                failures.append(failure)
            } catch { failures.append(CloudFailureClassifier.classify(error)) }
        }
        return failures
    }

    private func replay(
        _ operation: OutboxOperation, namespace: PersistenceNamespace, account: AccountContext, actor: ActorContext,
        stateProvider: any AuthoritativeMutationStateProviding, now: Date
    ) async -> CloudReplayResult {
        do {
            try await outbox.recordAttempt(operationID: operation.operationID, at: now, namespace: namespace)
            try OfflineExecutionEligibility.validate(operation, account: account, actor: actor)
            try OfficialClientPolicy.authorizeMutation(actor: actor, account: account)
            let state = try await stateProvider.state(for: operation.envelope.mutation)
            let outcome = try await transport.saveAtomically(CloudMutationEncoder.encode(operation.envelope.mutation, against: state))
            return try await recordedResult(outcome, operation: operation, namespace: namespace, now: now)
        } catch { return await failedReplay(operation, namespace: namespace, now: now, error: error) }
    }

    private func recordedResult(_ outcome: CloudSaveResult, operation: OutboxOperation, namespace: PersistenceNamespace, now: Date) async throws
        -> CloudReplayResult
    {
        var failures: [SyncFailure] = []
        var uploaded: [ObjectID] = []
        try await record(outcome: outcome, operation: operation, namespace: namespace, now: now, failures: &failures, uploaded: &uploaded)
        return CloudReplayResult(uploadedOperationIDs: uploaded, failures: failures)
    }

    private func failedReplay(_ operation: OutboxOperation, namespace: PersistenceNamespace, now: Date, error: Error) async -> CloudReplayResult {
        let failure = CloudFailureClassifier.classify(error)
        guard (error as? CloudTransportFailure)?.possiblyCommitted == true else {
            return await recordedFailure(operation, namespace: namespace, now: now, failure: failure)
        }
        var failures: [SyncFailure] = []
        do {
            let accepted = try await recoverLostResponse(operation: operation, namespace: namespace, now: now, fallback: failure, failures: &failures)
            return CloudReplayResult(uploadedOperationIDs: accepted ? [operation.operationID] : [], failures: failures)
        } catch { return CloudReplayResult(failures: [CloudFailureClassifier.classify(error)]) }
    }

    private func recordedFailure(_ operation: OutboxOperation, namespace: PersistenceNamespace, now: Date, failure: SyncFailure) async -> CloudReplayResult {
        do {
            try await outbox.recordFailure(
                operationID: operation.operationID, failure: failure,
                nextRetryAt: RetrySchedule.nextRetry(after: operation.attemptCount + 1, retryAfter: failure.retryAfter, now: now),
                poison: CloudFailureClassifier.isPoison(failure), namespace: namespace)
            return CloudReplayResult(failures: [failure])
        } catch { return CloudReplayResult(failures: [CloudFailureClassifier.classify(error)]) }
    }

    private func record(
        outcome: CloudSaveResult, operation: OutboxOperation, namespace: PersistenceNamespace, now: Date, failures: inout [SyncFailure],
        uploaded: inout [ObjectID]
    ) async throws {
        switch outcome {
        case .accepted(let receipt):
            guard receipt == operation.envelope.mutation.receipt else {
                let failure = SyncFailure(
                    category: .security, message: "Returned operation receipt does not match immutable intent.", resourceKeys: operation.resourceKeys)
                let reconciliation = try ReconciliationBuilder().make(
                    namespace: namespace, operation: operation, reason: .receiptDigestMismatch, current: [], isSecurityEvent: true)
                try await conflicts.capture(reconciliation)
                try await outbox.recordFailure(operationID: operation.operationID, failure: failure, nextRetryAt: nil, poison: true, namespace: namespace)
                failures.append(failure)
                return
            }
            try await outbox.recordAcceptance(operationID: operation.operationID, receipt: receipt, namespace: namespace)
            uploaded.append(operation.operationID)
        case .conflict(let caseValue):
            let transportScope = operation.resourceKeys.union(operation.envelope.mutation.readAssertions.map(\.resourceKey))
            guard caseValue.namespace == namespace, caseValue.operationID == operation.operationID,
                caseValue.resourceKeys == transportScope
            else {
                let failure = SyncFailure(
                    category: .security, message: "Returned conflict is outside the operation namespace or resource set.", resourceKeys: operation.resourceKeys)
                let reconciliation = try ReconciliationBuilder().make(
                    namespace: namespace, operation: operation, reason: .malformedPeerState, current: [], isSecurityEvent: true)
                try await conflicts.capture(reconciliation)
                try await outbox.recordFailure(operationID: operation.operationID, failure: failure, nextRetryAt: nil, poison: true, namespace: namespace)
                failures.append(failure)
                return
            }
            try await conflicts.capture(caseValue)
            let failure = SyncFailure(category: .conflict, message: "Conditional CloudKit save conflicted.", resourceKeys: operation.resourceKeys)
            try await outbox.recordFailure(operationID: operation.operationID, failure: failure, nextRetryAt: nil, poison: false, namespace: namespace)
            failures.append(failure)
        case .retryableFailure(let failure):
            try await outbox.recordFailure(
                operationID: operation.operationID, failure: failure,
                nextRetryAt: RetrySchedule.nextRetry(after: operation.attemptCount + 1, retryAfter: failure.retryAfter, now: now),
                poison: false, namespace: namespace)
            failures.append(failure)
        case .permanentFailure(let failure):
            try await outbox.recordFailure(operationID: operation.operationID, failure: failure, nextRetryAt: nil, poison: true, namespace: namespace)
            failures.append(failure)
        }
    }

    private func recoverLostResponse(
        operation: OutboxOperation, namespace: PersistenceNamespace, now: Date, fallback: SyncFailure, failures: inout [SyncFailure]
    ) async throws -> Bool {
        guard let receiptLookup else {
            try await outbox.recordFailure(
                operationID: operation.operationID, failure: fallback,
                nextRetryAt: RetrySchedule.nextRetry(after: operation.attemptCount + 1, retryAfter: fallback.retryAfter, now: now),
                poison: false, namespace: namespace)
            failures.append(fallback)
            return false
        }
        do {
            switch LostReceiptRecovery.resolve(
                expected: operation.envelope.mutation.receipt,
                observed: try await receiptLookup.receipt(operationID: operation.operationID, in: operation.envelope.mutation.workspaceZone))
            {
            case .accepted(let receipt):
                try await outbox.recordAcceptance(operationID: operation.operationID, receipt: receipt, namespace: namespace)
                return true
            case .retry:
                try await outbox.recordFailure(
                    operationID: operation.operationID, failure: fallback,
                    nextRetryAt: RetrySchedule.nextRetry(after: operation.attemptCount + 1, retryAfter: fallback.retryAfter, now: now),
                    poison: false, namespace: namespace)
                failures.append(fallback)
                return false
            case .securityMismatch:
                let failure = SyncFailure(
                    category: .security, message: "Operation receipt digest does not match immutable intent.", resourceKeys: operation.resourceKeys)
                let reconciliation = try ReconciliationBuilder().make(
                    namespace: namespace, operation: operation, reason: .receiptDigestMismatch, current: [], isSecurityEvent: true)
                try await conflicts.capture(reconciliation)
                try await outbox.recordFailure(operationID: operation.operationID, failure: failure, nextRetryAt: nil, poison: true, namespace: namespace)
                failures.append(failure)
                return false
            }
        } catch {
            let failure = CloudFailureClassifier.classify(error)
            try await outbox.recordFailure(
                operationID: operation.operationID, failure: failure,
                nextRetryAt: RetrySchedule.nextRetry(after: operation.attemptCount + 1, retryAfter: failure.retryAfter, now: now),
                poison: CloudFailureClassifier.isPoison(failure), namespace: namespace)
            failures.append(failure)
            return false
        }
    }
}
