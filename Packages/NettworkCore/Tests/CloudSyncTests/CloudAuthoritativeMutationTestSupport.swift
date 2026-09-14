import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class CloudAuthoritativeMutationRepositoryTests: XCTestCase {}

actor CommitTransport: CloudRecordTransport, CloudReceiptLookupTransport {
    let result: CloudSaveResult
    let saveError: CloudTransportFailure?
    private var receiptResults: [OperationReceipt?]
    private var savedMutation: AtomicCloudMutation?
    private var calls = 0
    init(
        result: CloudSaveResult,
        receiptResults: [OperationReceipt?] = [],
        saveError: CloudTransportFailure? = nil
    ) {
        self.result = result
        self.receiptResults = receiptResults
        self.saveError = saveError
    }
    func fetchChanges() async throws -> CloudChangeBatch { CloudChangeBatch(records: [], newState: Data()) }
    func saveAtomically(_ mutation: AtomicCloudMutation) async throws -> CloudSaveResult {
        calls += 1
        savedMutation = mutation
        if let saveError { throw saveError }
        return result
    }
    func lastSavedMutation() -> AtomicCloudMutation? { savedMutation }
    func saveCallCount() -> Int { calls }
    func receipt(operationID _: ObjectID, in _: AuthoritativeWorkspaceZone) async throws -> OperationReceipt? {
        guard !receiptResults.isEmpty else { return nil }
        return receiptResults.removeFirst()
    }
}

actor DurableOutbox: MutationOutbox {
    private var stored: [ObjectID: OutboxOperation]
    private var attempts: [ObjectID] = []

    init(operations: [OutboxOperation]) {
        self.stored = Dictionary(uniqueKeysWithValues: operations.map { ($0.operationID, $0) })
    }

    func enqueue(_ operation: OutboxOperation) async throws { stored[operation.operationID] = operation }
    func operations(in namespace: PersistenceNamespace) async throws -> [OutboxOperation] {
        stored.values.filter { $0.namespace == namespace }.sorted { $0.createdAt < $1.createdAt }
    }
    func operationsReady(at date: Date, in namespace: PersistenceNamespace) async throws -> [OutboxOperation] {
        let current = try await operations(in: namespace)
        return current.filter { $0.nextRetryAt.map { $0 <= date } ?? true }
    }
    func status(in _: PersistenceNamespace) async throws -> OutboxStatus {
        OutboxStatus(
            totalCount: stored.count, queueDepth: stored.values.filter { $0.state != .accepted }.count,
            acceptedHistoryCount: stored.values.filter { $0.state == .accepted }.count, countsByState: [:], oldestQueuedAt: nil, nextRetryAt: nil)
    }
    func recordAttempt(operationID: ObjectID, at _: Date, namespace _: PersistenceNamespace) async throws {
        guard var operation = stored[operationID] else { return }
        operation.attemptCount += 1
        operation.state = .uploading
        stored[operationID] = operation
        attempts.append(operationID)
    }
    func recordFailure(operationID: ObjectID, failure: SyncFailure, nextRetryAt: Date?, poison: Bool, namespace _: PersistenceNamespace) async throws {
        guard var operation = stored[operationID] else { return }
        operation.lastFailure = failure
        operation.nextRetryAt = nextRetryAt
        operation.state = poison ? .poisoned : .retryScheduled
        stored[operationID] = operation
    }
    func recordAcceptance(operationID: ObjectID, receipt: OperationReceipt, namespace _: PersistenceNamespace) async throws {
        guard var operation = stored[operationID] else { return }
        operation.state = .accepted
        operation.receipt = receipt
        operation.nextRetryAt = nil
        stored[operationID] = operation
    }

    func operation(id: ObjectID) -> OutboxOperation? { stored[id] }
    func attemptedOperationIDs() -> [ObjectID] { attempts }
}

actor NoopConflictResolver: ConflictResolver {
    func capture(_: ReconciliationCase) async throws {}
    func unresolvedCases(in _: PersistenceNamespace) async throws -> [ReconciliationCase] { [] }
}

func account(for workspaceZone: AuthoritativeWorkspaceZone) -> AccountContext {
    AccountContext(
        namespace: PersistenceNamespace(
            containerIdentifier: workspaceZone.containerIdentifier,
            cloudKitAccountRecordName: workspaceZone.zoneOwnerRecordName,
            workspaceID: workspaceZone.workspaceID,
            zoneName: workspaceZone.zoneName,
            zoneOwnerRecordName: workspaceZone.zoneOwnerRecordName,
            sessionGeneration: 1
        ),
        databaseScope: .ownerPrivate,
        sharePermission: .owner,
        verifiedAt: .distantPast
    )
}

func outboxOperation(
    for mutation: AuthoritativeMutation,
    account: AccountContext,
    operationID: ObjectID? = nil,
    createdAt: Date = .distantPast
) -> OutboxOperation {
    let actor = ActorContext(
        cloudKitUserRecordName: account.namespace.cloudKitAccountRecordName,
        role: .administrator,
        installationID: mutation.actor.installationID,
        sessionGeneration: account.namespace.sessionGeneration
    )
    return OutboxOperation(
        operationID: operationID ?? mutation.operationID,
        namespace: account.namespace,
        envelope: ExecutionEnvelope(
            mutation: mutation,
            accountContext: account,
            actorContext: actor,
            clientTime: .distantPast,
            ticket: nil,
            notes: nil,
            baseSnapshots: [:]
        ),
        resourceKeys: mutation.resourceKeys,
        dependencyOperationIDs: [],
        createdAt: createdAt
    )
}

actor CommitStateProvider: AuthoritativeMutationStateProviding {
    let state: AuthoritativeMutationState
    init(state: AuthoritativeMutationState) { self.state = state }
    func state(for _: AuthoritativeMutation) async throws -> AuthoritativeMutationState { state }
}

func acknowledgementServerRecord(
    for workOrder: WorkOrder,
    workspaceZone: AuthoritativeWorkspaceZone,
    serverModifiedAt: Date
) throws -> CloudExactRecordSnapshot {
    CloudExactRecordSnapshot(
        workspaceZone: workspaceZone, resourceKey: .object(workOrder.id),
        recordType: CloudRecordNaming.workOrderRecordType, schemaVersion: CloudRecordNaming.schemaVersion,
        payload: try CloudDeterministicCoding.encode(workOrder),
        exactPrecondition: ExactRecordPrecondition(systemFields: Data("server-system-fields".utf8), changeTag: "work-order-v1"),
        serverModifiedAt: serverModifiedAt
    )
}

struct MutationCommitFixture {
    let mutation: AuthoritativeMutation
    let state: AuthoritativeMutationState

    static func make() throws -> MutationCommitFixture {
        let workspace = ObjectID()
        let zone = AuthoritativeWorkspaceZone(
            workspaceID: workspace, containerIdentifier: "iCloud.example.nettwork", zoneName: CloudRecordNaming.zoneName(for: workspace),
            zoneOwnerRecordName: "owner")
        let actor = ActorInstallationSnapshot(
            actorID: "owner", installationID: "test-installation", sessionID: "test-session", sessionGeneration: 1, capturedAt: .distantPast)
        let key = ResourceKey.object(ObjectID())
        let orderID = ObjectID()
        let operations: [PlannedWorkOperation] = [.device(resourceKey: key, description: "Update")]
        let reservation = WorkOrderReservation(ownerID: actor.actorID, resourceKeys: [key])
        let intent = CanonicalWorkIntent(
            workOrderID: orderID, kind: .device, creatorID: actor.actorID, ticket: nil, notes: nil, operations: operations,
            resourceKeys: reservation.resourceKeys, evidenceHashes: [])
        let digest = try intent.digest()
        let draft = WorkOrder(
            id: orderID, kind: .device, title: "Update device", creatorID: actor.actorID, plannedOperations: operations, intentDigest: digest,
            reservation: reservation)
        let reserved = try WorkOrderStateMachine.transition(draft, to: .reserved, context: .init(actorID: actor.actorID, at: .distantPast))
        let acknowledgement = CloudKitAcknowledgement(
            workspaceZone: zone, cloudKitAccountRecordName: actor.actorID, sessionGeneration: actor.sessionGeneration, reservationID: reservation.id,
            workOrderID: orderID, ownerID: actor.actorID, resourceKeys: reservation.resourceKeys, intentDigest: digest, systemFields: Data([7]),
            changeTag: "reservation-v1", acknowledgedAt: .distantPast, expiresAt: .distantFuture)
        let order = try WorkOrderStateMachine.acknowledgeReservation(reserved, acknowledgement: acknowledgement, observedAt: .distantPast)
        let operationID = ObjectID()
        let audit = AuditEvent(
            operationID: operationID, actorID: actor.actorID, affectedObjectIDs: [], workOrderID: order.id, occurredAt: actor.capturedAt, result: .accepted,
            installationID: actor.installationID, sessionID: actor.sessionID, sessionGeneration: actor.sessionGeneration,
            affectedResourceKeys: [key, .object(order.id)])
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: workspace)
        let sentinelExact = ExactRecordPrecondition(systemFields: Data([8]), changeTag: "workspace-active")
        let sentinelPayload = try CloudDeterministicCoding.encode(
            CloudWorkspaceRecord(
                workspaceID: workspace, zoneName: zone.zoneName, zoneOwnerRecordName: zone.zoneOwnerRecordName,
                lifecycle: .active(commit: .init(transferID: ObjectID(), memberCount: 0, rollingDigest: "active"))))
        let sentinel = AuthoritativeReadAssertion(
            resourceKey: sentinelKey, recordType: AuthoritativeActivationMutation.workspaceSentinelRecordType, schemaVersion: CloudRecordNaming.schemaVersion,
            encodedRecord: sentinelPayload, precondition: sentinelExact)
        let workOrderExact = ExactRecordPrecondition(systemFields: Data([9]), changeTag: "work-order-v1")
        let mutation = try AuthoritativeMutation(
            workspaceZone: zone, operationID: operationID, intentDigest: digest, actor: actor, workOrder: order, expectedWorkOrderRevision: reserved.revision,
            resourceKeys: [key, .object(order.id), .object(audit.id), .operationReceipt(operationID: operationID)],
            saves: [AuthoritativeRecordSave(resourceKey: key, recordType: "NettworkDevice", schemaVersion: 1, encodedRecord: Data("{}".utf8))], tombstones: [],
            preconditions: [
                .mustNotExist(key), .exactSystemFields(.object(order.id), workOrderExact), .exactSystemFields(sentinel.resourceKey, sentinelExact),
                .mustNotExist(.object(audit.id)), .mustNotExist(.operationReceipt(operationID: operationID)),
            ], readAssertions: [sentinel], auditEvent: audit, evidenceHashes: [])
        return MutationCommitFixture(
            mutation: mutation,
            state: AuthoritativeMutationState(
                knownRecords: [.object(order.id): workOrderExact, sentinel.resourceKey: sentinelExact], currentWorkOrder: reserved))
    }

    func mutation(with assertion: AuthoritativeReadAssertion) throws -> AuthoritativeMutation {
        try AuthoritativeMutation(
            workspaceZone: mutation.workspaceZone,
            operationID: mutation.operationID,
            intentDigest: mutation.intentDigest,
            actor: mutation.actor,
            workOrder: mutation.workOrder,
            expectedWorkOrderRevision: mutation.expectedWorkOrderRevision,
            resourceKeys: mutation.resourceKeys,
            saves: mutation.saves,
            tombstones: mutation.tombstones,
            preconditions: mutation.preconditions + [.exactSystemFields(assertion.resourceKey, assertion.precondition)],
            readAssertions: mutation.readAssertions + [assertion],
            auditEvent: mutation.auditEvent,
            evidenceHashes: mutation.evidenceHashes
        )
    }
}
