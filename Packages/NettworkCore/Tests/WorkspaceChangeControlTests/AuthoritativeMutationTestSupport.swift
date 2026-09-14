import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

let existingWorkOrderRecord = ExactRecordPrecondition(systemFields: Data([9]), changeTag: "work-order-v0")

func makeOrder(reservedResourceIDs: Set<ObjectID> = []) throws -> WorkOrder {
    let digest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 7, count: 32))
    let resourceKeys = Set(reservedResourceIDs.map(ResourceKey.object))
    let workOrderID = ObjectID()
    let reservationID = ObjectID()
    let workspaceZone = AuthoritativeWorkspaceZone(
        workspaceID: ObjectID(), containerIdentifier: "iCloud.example.nettwork", zoneName: "workspace", zoneOwnerRecordName: "owner")
    let acknowledgement = CloudKitAcknowledgement(
        workspaceZone: workspaceZone, cloudKitAccountRecordName: "creator", sessionGeneration: 1, reservationID: reservationID, workOrderID: workOrderID,
        ownerID: "creator", resourceKeys: resourceKeys, intentDigest: digest, systemFields: Data([1]), changeTag: "reservation-v1",
        acknowledgedAt: .distantPast, expiresAt: .distantFuture)
    let reservation =
        resourceKeys.isEmpty
        ? nil : WorkOrderReservation(id: reservationID, ownerID: "creator", resourceKeys: resourceKeys, acknowledgedByCloudKit: acknowledgement)
    let interfaceID = ObjectID()
    let addressID = "ip-address:creator:10.0.0.42"
    let assignment = IPAddressAssignment(addressID: addressID, interfaceID: interfaceID, isPrimary: true)
    let assignmentSet = InterfaceAddressAssignmentSet(
        revisionVRF: VRF(name: "Production", revision: 4),
        interfaceID: interfaceID,
        currentAssignments: [],
        desiredAssignments: [assignment],
        primaryAddressID: addressID
    )
    return WorkOrder(
        id: workOrderID, kind: .connect, title: "Connect desk", reservedResourceIDs: reservedResourceIDs, creatorID: "creator", ticket: "INC-42",
        notes: "Patch after access approval", plannedOperations: [.ipam(.addressAssignment(assignmentSet))], intentDigest: digest, reservation: reservation)
}

func makeMutation(operationID: ObjectID = ObjectID(), saveKeys: [ResourceKey]? = nil, preconditions: [MutationPrecondition]? = nil) throws
    -> AuthoritativeMutation
{
    let key = saveKeys?.first ?? .object(ObjectID())
    let evidence = EvidenceHash(
        id: ObjectID(), digest: try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 4, count: 32)), contentType: "image/jpeg")
    let workOrderID = ObjectID()
    let operations: [PlannedWorkOperation] = [.device(resourceKey: key, description: "Install patch")]
    let reservation = WorkOrderReservation(ownerID: "technician", resourceKeys: [key])
    let digest = try CanonicalWorkIntent(
        workOrderID: workOrderID, kind: .connect, creatorID: "technician", ticket: "CHG-42", notes: nil, operations: operations,
        resourceKeys: reservation.resourceKeys, evidenceHashes: [evidence]
    ).digest()
    let baseOrder = WorkOrder(
        id: workOrderID, kind: .connect, title: "Connect desk", creatorID: "technician", ticket: "CHG-42", plannedOperations: operations,
        intentDigest: digest, reservation: reservation, evidenceHashes: [evidence])
    let order = try WorkOrderStateMachine.transition(baseOrder, to: .reserved)
    let actor = ActorInstallationSnapshot(
        actorID: "technician", installationID: "ipad-1", sessionID: "session-1", sessionGeneration: 1, capturedAt: .distantPast)
    let workspaceZone = AuthoritativeWorkspaceZone(
        workspaceID: ObjectID(), containerIdentifier: "iCloud.example.nettwork", zoneName: "workspace", zoneOwnerRecordName: "owner")
    let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: workspaceZone.workspaceID)
    let sentinelExact = ExactRecordPrecondition(systemFields: Data([8]), changeTag: "workspace-active")
    let sentinelPayload = try JSONEncoder().encode(
        MutationWorkspaceSentinelFixture(
            workspaceID: workspaceZone.workspaceID, zoneName: workspaceZone.zoneName, zoneOwnerRecordName: workspaceZone.zoneOwnerRecordName,
            lifecycle: .active(commit: WorkspaceActivationCommit(transferID: ObjectID(), memberCount: 0, rollingDigest: "active"))))
    let sentinelAssertion = AuthoritativeReadAssertion(
        resourceKey: sentinelKey, recordType: AuthoritativeActivationMutation.workspaceSentinelRecordType, schemaVersion: 1, encodedRecord: sentinelPayload,
        precondition: sentinelExact)
    let keys = saveKeys ?? [key]
    let saves = keys.map { AuthoritativeRecordSave(resourceKey: $0, recordType: "Port", schemaVersion: 1, encodedRecord: Data([1])) }
    let audit = AuditEvent(
        operationID: operationID, actorID: actor.actorID, affectedObjectIDs: [], workOrderID: order.id, occurredAt: .distantPast, result: .accepted,
        installationID: actor.installationID, sessionID: actor.sessionID, sessionGeneration: actor.sessionGeneration,
        affectedResourceKeys: keys + [.object(order.id)], changes: keys.map { AuditRecordChange(resourceKey: $0, after: Data([1])) }, ticket: order.ticket,
        policyVersion: "v1")
    let receiptKey = ResourceKey.operationReceipt(operationID: operationID)
    let mandatoryPreconditions: [MutationPrecondition] = [
        .exactSystemFields(.object(order.id), existingWorkOrderRecord),
        .mustNotExist(.object(audit.id)),
        .mustNotExist(receiptKey),
        .exactSystemFields(sentinelKey, sentinelExact),
    ]
    let businessPreconditions = preconditions ?? keys.map(MutationPrecondition.mustNotExist)
    let resources = Set(keys).union([.object(order.id), .object(audit.id), receiptKey])
    return try AuthoritativeMutation(
        workspaceZone: workspaceZone, operationID: operationID, intentDigest: digest, actor: actor, workOrder: order, expectedWorkOrderRevision: 0,
        resourceKeys: resources, saves: saves, tombstones: [], preconditions: businessPreconditions + mandatoryPreconditions,
        readAssertions: [sentinelAssertion], auditEvent: audit, evidenceHashes: [evidence])
}

func mutation(from base: AuthoritativeMutation, readAssertions: [AuthoritativeReadAssertion], preconditions: [MutationPrecondition]) throws
    -> AuthoritativeMutation
{
    try AuthoritativeMutation(
        workspaceZone: base.workspaceZone,
        operationID: base.operationID,
        intentDigest: base.intentDigest,
        actor: base.actor,
        workOrder: base.workOrder,
        expectedWorkOrderRevision: base.expectedWorkOrderRevision,
        resourceKeys: base.resourceKeys,
        saves: base.saves,
        tombstones: base.tombstones,
        preconditions: preconditions,
        readAssertions: base.readAssertions
            + readAssertions.filter {
                !base.readAssertions.map(\.resourceKey).contains($0.resourceKey)
            },
        auditEvent: base.auditEvent,
        evidenceHashes: base.evidenceHashes
    )
}

func validationState(for mutation: AuthoritativeMutation, currentWorkOrder: WorkOrder? = nil) -> AuthoritativeMutationState {
    AuthoritativeMutationState(
        knownRecords: Dictionary(
            uniqueKeysWithValues: [
                (.object(mutation.workOrder.id), existingWorkOrderRecord)
            ] + mutation.readAssertions.map { ($0.resourceKey, $0.precondition) }),
        currentWorkOrder: currentWorkOrder ?? baseWorkOrder(for: mutation)
    )
}

func baseWorkOrder(for mutation: AuthoritativeMutation) -> WorkOrder {
    let order = mutation.workOrder
    return WorkOrder(
        id: order.id, kind: order.kind, title: order.title, status: .draft, reservedResourceIDs: order.reservedResourceIDs, creatorID: order.creatorID,
        ticket: order.ticket, notes: order.notes, plannedOperations: order.plannedOperations, revision: mutation.expectedWorkOrderRevision,
        intentDigest: order.intentDigest, reservation: order.reservation, evidenceHashes: order.evidenceHashes)
}

struct IntentSchemaFixture {
    let workOrderID: ObjectID
    let vrf: VRF
    let firstPrefix: Prefix
    let secondPrefix: Prefix
    let legacyKey: ResourceKey
    let legacyOperation: PlannedIPAMOperation
}

enum InMemoryMutationStoreError: Error { case operationIDCollision }

actor InMemoryAtomicMutationStore: AuthoritativeMutationRepository {
    private var records: [ResourceKey: ExactRecordPrecondition] = [:]
    private var currentWorkOrder: WorkOrder?
    private var receipts: [ObjectID: OperationReceipt] = [:]

    init(currentWorkOrder: WorkOrder, workspaceAssertion: AuthoritativeReadAssertion) {
        self.currentWorkOrder = currentWorkOrder
        records[.object(currentWorkOrder.id)] = existingWorkOrderRecord
        records[workspaceAssertion.resourceKey] = workspaceAssertion.precondition
    }

    func commit(_ mutation: AuthoritativeMutation) async throws -> OperationReceipt {
        if let receipt = receipts[mutation.operationID] {
            guard receipt.intentDigest == mutation.intentDigest else { throw InMemoryMutationStoreError.operationIDCollision }
            return receipt
        }
        try AuthoritativeMutationValidator.validate(mutation, against: .init(knownRecords: records, currentWorkOrder: currentWorkOrder))

        var nextRecords = records
        for save in mutation.saves {
            nextRecords[save.resourceKey] = ExactRecordPrecondition(
                systemFields: Data([0]), changeTag: "local-\(mutation.operationID.description)-\(save.resourceKey.description)")
        }
        for tombstone in mutation.tombstones {
            nextRecords[tombstone.resourceKey] = ExactRecordPrecondition(
                systemFields: Data([0]), changeTag: "tombstone-\(mutation.operationID.description)-\(tombstone.resourceKey.description)")
        }
        nextRecords[.object(mutation.workOrder.id)] = ExactRecordPrecondition(
            systemFields: Data([0]), changeTag: "work-order-\(mutation.operationID.description)")
        nextRecords[.object(mutation.auditEvent.id)] = ExactRecordPrecondition(systemFields: Data([0]), changeTag: "audit-\(mutation.operationID.description)")
        nextRecords[mutation.receipt.id] = ExactRecordPrecondition(systemFields: Data([0]), changeTag: "receipt-\(mutation.operationID.description)")
        records = nextRecords
        currentWorkOrder = mutation.workOrder
        receipts[mutation.operationID] = mutation.receipt
        return mutation.receipt
    }

    func recordCount() -> Int { records.count }
}

private struct MutationWorkspaceSentinelFixture: Codable {
    let workspaceID: ObjectID
    let zoneName: String
    let zoneOwnerRecordName: String
    let lifecycle: WorkspaceLifecycle
}
