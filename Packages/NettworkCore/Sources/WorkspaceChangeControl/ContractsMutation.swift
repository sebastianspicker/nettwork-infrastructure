import Foundation
import NetworkModel

public struct OperationReceipt: Codable, Hashable, Sendable, Identifiable {
    public var id: ResourceKey { .operationReceipt(operationID: operationID) }
    public let workspaceZone: AuthoritativeWorkspaceZone
    public let operationID: ObjectID
    public let intentDigest: IntentDigest
    public let auditEventID: ObjectID
    public init(workspaceZone: AuthoritativeWorkspaceZone, operationID: ObjectID, intentDigest: IntentDigest, auditEventID: ObjectID) {
        self.workspaceZone = workspaceZone
        self.operationID = operationID
        self.intentDigest = intentDigest
        self.auditEventID = auditEventID
    }
}
public struct AuthoritativeMutation: Codable, Hashable, Sendable {
    public let workspaceZone: AuthoritativeWorkspaceZone
    public let operationID: ObjectID
    public let intentDigest: IntentDigest
    public let actor: ActorInstallationSnapshot
    public let workOrder: WorkOrder
    public let expectedWorkOrderRevision: Int
    public let resourceKeys: Set<ResourceKey>
    public let saves: [AuthoritativeRecordSave]
    public let tombstones: [AuthoritativeTombstone]
    public let preconditions: [MutationPrecondition]
    /// Condition-only reads. They intentionally do not contribute to business
    /// resource ownership, reservation coverage, or audit change claims.
    public let readAssertions: [AuthoritativeReadAssertion]
    public let auditEvent: AuditEvent
    public let evidenceHashes: [EvidenceHash]
    public let receipt: OperationReceipt
    /// Immutable bytes generated once and replayed unchanged after restart.
    public let encodedWorkOrder: Data
    public let encodedAuditEvent: Data
    public let encodedReceipt: Data

    public init(
        workspaceZone: AuthoritativeWorkspaceZone, operationID: ObjectID, intentDigest: IntentDigest, actor: ActorInstallationSnapshot, workOrder: WorkOrder,
        expectedWorkOrderRevision: Int,
        resourceKeys: Set<ResourceKey>, saves: [AuthoritativeRecordSave], tombstones: [AuthoritativeTombstone], preconditions: [MutationPrecondition],
        readAssertions: [AuthoritativeReadAssertion] = [],
        auditEvent: AuditEvent, evidenceHashes: [EvidenceHash], receipt: OperationReceipt? = nil, encodedWorkOrder: Data? = nil, encodedAuditEvent: Data? = nil,
        encodedReceipt: Data? = nil
    ) throws {
        self.workspaceZone = workspaceZone
        self.operationID = operationID
        self.intentDigest = intentDigest
        self.actor = actor
        self.workOrder = workOrder
        self.expectedWorkOrderRevision = expectedWorkOrderRevision
        self.resourceKeys = resourceKeys
        self.saves = saves
        self.tombstones = tombstones
        self.preconditions = preconditions
        self.readAssertions = readAssertions
        self.auditEvent = auditEvent
        self.evidenceHashes = evidenceHashes
        self.receipt =
            receipt ?? OperationReceipt(workspaceZone: workspaceZone, operationID: operationID, intentDigest: intentDigest, auditEventID: auditEvent.id)
        self.encodedWorkOrder = try encodedWorkOrder ?? CanonicalJSONCoding.encode(workOrder)
        self.encodedAuditEvent = try encodedAuditEvent ?? CanonicalJSONCoding.encode(auditEvent)
        self.encodedReceipt = try encodedReceipt ?? CanonicalJSONCoding.encode(self.receipt)
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceZone, operationID, intentDigest, actor, workOrder,
            expectedWorkOrderRevision, resourceKeys, saves, tombstones,
            preconditions, readAssertions, auditEvent, evidenceHashes, receipt,
            encodedWorkOrder, encodedAuditEvent, encodedReceipt
    }

    /// Older durable envelopes did not contain read assertions. Decode them as
    /// empty so their established validation and execution policy is unchanged.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workspaceZone: try container.decode(AuthoritativeWorkspaceZone.self, forKey: .workspaceZone),
            operationID: try container.decode(ObjectID.self, forKey: .operationID),
            intentDigest: try container.decode(IntentDigest.self, forKey: .intentDigest),
            actor: try container.decode(ActorInstallationSnapshot.self, forKey: .actor),
            workOrder: try container.decode(WorkOrder.self, forKey: .workOrder),
            expectedWorkOrderRevision: try container.decode(Int.self, forKey: .expectedWorkOrderRevision),
            resourceKeys: try container.decode(Set<ResourceKey>.self, forKey: .resourceKeys),
            saves: try container.decode([AuthoritativeRecordSave].self, forKey: .saves),
            tombstones: try container.decode([AuthoritativeTombstone].self, forKey: .tombstones),
            preconditions: try container.decode([MutationPrecondition].self, forKey: .preconditions),
            readAssertions: try container.decodeIfPresent([AuthoritativeReadAssertion].self, forKey: .readAssertions) ?? [],
            auditEvent: try container.decode(AuditEvent.self, forKey: .auditEvent),
            evidenceHashes: try container.decode([EvidenceHash].self, forKey: .evidenceHashes),
            receipt: try container.decode(OperationReceipt.self, forKey: .receipt),
            encodedWorkOrder: try container.decode(Data.self, forKey: .encodedWorkOrder),
            encodedAuditEvent: try container.decode(Data.self, forKey: .encodedAuditEvent),
            encodedReceipt: try container.decode(Data.self, forKey: .encodedReceipt))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceZone, forKey: .workspaceZone)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(intentDigest, forKey: .intentDigest)
        try container.encode(actor, forKey: .actor)
        try container.encode(workOrder, forKey: .workOrder)
        try container.encode(expectedWorkOrderRevision, forKey: .expectedWorkOrderRevision)
        try container.encode(resourceKeys, forKey: .resourceKeys)
        try container.encode(saves, forKey: .saves)
        try container.encode(tombstones, forKey: .tombstones)
        try container.encode(preconditions, forKey: .preconditions)
        try container.encode(readAssertions, forKey: .readAssertions)
        try container.encode(auditEvent, forKey: .auditEvent)
        try container.encode(evidenceHashes, forKey: .evidenceHashes)
        try container.encode(receipt, forKey: .receipt)
        try container.encode(encodedWorkOrder, forKey: .encodedWorkOrder)
        try container.encode(encodedAuditEvent, forKey: .encodedAuditEvent)
        try container.encode(encodedReceipt, forKey: .encodedReceipt)
    }
}

public struct AuthoritativeMutationState: Codable, Hashable, Sendable {
    public var knownRecords: [ResourceKey: ExactRecordPrecondition]
    public var currentWorkOrder: WorkOrder?
    public init(knownRecords: [ResourceKey: ExactRecordPrecondition] = [:], currentWorkOrder: WorkOrder? = nil) {
        self.knownRecords = knownRecords
        self.currentWorkOrder = currentWorkOrder
    }
}

public enum AuthoritativeMutationValidationError: Error, Hashable, Sendable {
    case invalidScope
    case invalidActorSnapshot
    case missingWorkOrderIntentDigest
    case intentDigestMismatch
    case invalidWorkOrderPrecondition
    case staleWorkOrderRevision(expected: Int, actual: Int)
    case invalidSubmittedWorkOrderRevision(expected: Int, actual: Int)
    case invalidWorkOrderTransition
    case duplicateTouchedResource(ResourceKey)
    case duplicateReadAssertion(ResourceKey)
    case invalidReadAssertion(ResourceKey)
    case readAssertionOverlapsMutation(ResourceKey)
    case readAssertionPreconditionMismatch(ResourceKey)
    case resourceKeyNotDeclared(ResourceKey)
    case duplicatePrecondition(ResourceKey)
    case missingPrecondition(ResourceKey)
    case invalidExactPrecondition(ResourceKey)
    case resourceAlreadyExists(ResourceKey)
    case missingRecord(ResourceKey)
    case preconditionConflict(ResourceKey)
    case invalidRecordSave(ResourceKey)
    case invalidTombstone(ResourceKey)
    case reservedActivationInfrastructure(ResourceKey)
    case invalidAuditEvent
    case evidenceMismatch
    case invalidReceipt
    case invalidImmutablePayload
    case reservationOwnerMismatch
    case reservationScopeMismatch
    case reservationIntentMismatch
    case reservationExpired
}
