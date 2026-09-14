import Foundation
import NetworkModel

/// A work-order-free privileged mutation for bootstrap, bulk, and quota
/// activations. Every changed record, the accepted audit event, and the
/// receipt are committed through one conditional authoritative boundary.
public struct AuthoritativeActivationMutation: Codable, Hashable, Sendable {
    public static let workspaceSentinelRecordType = "NettworkWorkspace"
    public static let transferSessionRecordType = "NettworkWorkspaceTransferSession"
    public static let floorPlanAssetBindingRecordType = "NettworkFloorPlanAssetBinding"
    public static let attachmentEvidenceActivationRecordTypes: Set<String> = [
        "NettworkAttachmentEvidenceQuotaLedger", "NettworkAttachmentEvidenceReservationRelease",
        "NettworkAttachmentEvidenceBinding",
    ]
    public static let noSessionActivationRecordTypes: Set<String> =
        attachmentEvidenceActivationRecordTypes.union([floorPlanAssetBindingRecordType])

    public let workspaceZone: AuthoritativeWorkspaceZone
    public let operationID: ObjectID
    public let intentDigest: IntentDigest
    public let actor: ActorInstallationSnapshot
    public let saves: [AuthoritativeRecordSave]
    public let tombstones: [AuthoritativeTombstone]
    public let preconditions: [MutationPrecondition]
    /// Condition-only reads are bound into the same conditional CloudKit write
    /// but never become an audit change or a visible activation resource.
    public let readAssertions: [AuthoritativeReadAssertion]
    public let auditEvent: AuditEvent
    public let receipt: OperationReceipt
    /// Immutable payloads generated once and reused unchanged after a retry.
    public let encodedAuditEvent: Data
    public let encodedReceipt: Data

    /// The workspace bootstrap record is a conditional save, not a local
    /// emptiness check. It serializes bootstrap and later bulk activations in
    /// the authoritative zone.
    public static func bootstrapSentinelResourceKey(for workspaceID: ObjectID) -> ResourceKey {
        .string("workspace-bootstrap-sentinel:\(workspaceID.description)")
    }

    public var bootstrapSentinelResourceKey: ResourceKey {
        Self.bootstrapSentinelResourceKey(for: workspaceZone.workspaceID)
    }

    /// Transfer sessions are owned by the staged-transfer protocol, never by
    /// the work-order mutation boundary. Keep the identity rule here so the
    /// generic domain validator can reject it without importing CloudSync.
    public static func isTransferInfrastructureResourceKey(_ key: ResourceKey) -> Bool {
        guard case let .string(value) = key else { return false }
        return value.hasPrefix("workspace-transfer-session:")
    }

    public var resourceKeys: Set<ResourceKey> {
        Set(saves.map(\.resourceKey))
            .union(tombstones.map(\.resourceKey))
            .union([.object(auditEvent.id), receipt.id])
    }

    public init(
        workspaceZone: AuthoritativeWorkspaceZone, operationID: ObjectID, intentDigest: IntentDigest,
        actor: ActorInstallationSnapshot, saves: [AuthoritativeRecordSave],
        tombstones: [AuthoritativeTombstone], preconditions: [MutationPrecondition],
        readAssertions: [AuthoritativeReadAssertion] = [], auditEvent: AuditEvent,
        receipt: OperationReceipt? = nil, encodedAuditEvent: Data? = nil, encodedReceipt: Data? = nil
    ) throws {
        self.workspaceZone = workspaceZone
        self.operationID = operationID
        self.intentDigest = intentDigest
        self.actor = actor
        self.saves = saves
        self.tombstones = tombstones
        self.preconditions = preconditions
        self.readAssertions = readAssertions
        self.auditEvent = auditEvent
        self.receipt =
            receipt
            ?? OperationReceipt(
                workspaceZone: workspaceZone, operationID: operationID,
                intentDigest: intentDigest, auditEventID: auditEvent.id)
        self.encodedAuditEvent = try encodedAuditEvent ?? StableActivationPayloadCoding.encode(auditEvent)
        self.encodedReceipt = try encodedReceipt ?? StableActivationPayloadCoding.encode(self.receipt)
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceZone, operationID, intentDigest, actor, saves, tombstones,
            preconditions, readAssertions, auditEvent, receipt, encodedAuditEvent, encodedReceipt
    }

    /// V1 activation envelopes predate condition-only reads. They retain their
    /// exact previous semantics when replayed after an app upgrade.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workspaceZone: container.decode(AuthoritativeWorkspaceZone.self, forKey: .workspaceZone),
            operationID: container.decode(ObjectID.self, forKey: .operationID),
            intentDigest: container.decode(IntentDigest.self, forKey: .intentDigest),
            actor: container.decode(ActorInstallationSnapshot.self, forKey: .actor),
            saves: container.decode([AuthoritativeRecordSave].self, forKey: .saves),
            tombstones: container.decode([AuthoritativeTombstone].self, forKey: .tombstones),
            preconditions: container.decode([MutationPrecondition].self, forKey: .preconditions),
            readAssertions: container.decodeIfPresent([AuthoritativeReadAssertion].self, forKey: .readAssertions) ?? [],
            auditEvent: container.decode(AuditEvent.self, forKey: .auditEvent),
            receipt: container.decode(OperationReceipt.self, forKey: .receipt),
            encodedAuditEvent: container.decode(Data.self, forKey: .encodedAuditEvent),
            encodedReceipt: container.decode(Data.self, forKey: .encodedReceipt))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceZone, forKey: .workspaceZone)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(intentDigest, forKey: .intentDigest)
        try container.encode(actor, forKey: .actor)
        try container.encode(saves, forKey: .saves)
        try container.encode(tombstones, forKey: .tombstones)
        try container.encode(preconditions, forKey: .preconditions)
        try container.encode(readAssertions, forKey: .readAssertions)
        try container.encode(auditEvent, forKey: .auditEvent)
        try container.encode(receipt, forKey: .receipt)
        try container.encode(encodedAuditEvent, forKey: .encodedAuditEvent)
        try container.encode(encodedReceipt, forKey: .encodedReceipt)
    }
}

enum StableActivationPayloadCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

public struct AuthoritativeActivationMutationState: Codable, Hashable, Sendable {
    public var knownRecords: [ResourceKey: ExactRecordPrecondition]
    /// Exact payload snapshots for every existing activation input. Capability
    /// validation uses these bytes to prove that condition-only reads are
    /// unchanged and that quota arithmetic starts from the authoritative base.
    public var currentRecords: [ResourceKey: AuthoritativeActivationRecordSnapshot]
    /// The exact currently-authoritative workspace sentinel. Its bytes are
    /// required to distinguish a capability-preserving attachment activation
    /// from a workspace lifecycle transition.
    public var currentSentinel: AuthoritativeActivationSentinelSnapshot?

    public init(
        knownRecords: [ResourceKey: ExactRecordPrecondition] = [:],
        currentRecords: [ResourceKey: AuthoritativeActivationRecordSnapshot] = [:],
        currentSentinel: AuthoritativeActivationSentinelSnapshot? = nil
    ) {
        self.knownRecords = knownRecords
        self.currentRecords = currentRecords
        self.currentSentinel = currentSentinel
    }

    private enum CodingKeys: String, CodingKey { case knownRecords, currentRecords, currentSentinel }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            knownRecords: try container.decodeIfPresent([ResourceKey: ExactRecordPrecondition].self, forKey: .knownRecords) ?? [:],
            currentRecords: try container.decodeIfPresent([ResourceKey: AuthoritativeActivationRecordSnapshot].self, forKey: .currentRecords) ?? [:],
            currentSentinel: try container.decodeIfPresent(AuthoritativeActivationSentinelSnapshot.self, forKey: .currentSentinel)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(knownRecords, forKey: .knownRecords)
        try container.encode(currentRecords, forKey: .currentRecords)
        try container.encodeIfPresent(currentSentinel, forKey: .currentSentinel)
    }
}

public struct AuthoritativeActivationRecordSnapshot: Codable, Hashable, Sendable {
    public let recordType: String
    public let schemaVersion: Int
    public let encodedRecord: Data
    public let precondition: ExactRecordPrecondition

    public init(
        recordType: String, schemaVersion: Int, encodedRecord: Data,
        precondition: ExactRecordPrecondition
    ) {
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.encodedRecord = encodedRecord
        self.precondition = precondition
    }
}

public struct AuthoritativeActivationSentinelSnapshot: Codable, Hashable, Sendable {
    public let recordType: String
    public let schemaVersion: Int
    public let encodedRecord: Data

    public init(recordType: String, schemaVersion: Int, encodedRecord: Data) {
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.encodedRecord = encodedRecord
    }
}

public enum AuthoritativeActivationMutationValidationError: Error, Hashable, Sendable {
    case invalidScope
    case invalidActorSnapshot
    case invalidImmutablePayload
    case missingBootstrapSentinel(ResourceKey)
    case invalidBootstrapSentinelPrecondition(ResourceKey)
    case invalidCurrentBootstrapSentinel(ResourceKey)
    case invalidActivationRecordSet(ResourceKey)
    case invalidTransferSessionAssertion(ResourceKey)
    case duplicateTouchedResource(ResourceKey)
    case duplicatePrecondition(ResourceKey)
    case invalidReadAssertion(ResourceKey)
    case duplicateReadAssertion(ResourceKey)
    case readAssertionOverlapsMutation(ResourceKey)
    case readAssertionPreconditionMismatch(ResourceKey)
    case missingPrecondition(ResourceKey)
    case invalidExactPrecondition(ResourceKey)
    case resourceAlreadyExists(ResourceKey)
    case missingRecord(ResourceKey)
    case preconditionConflict(ResourceKey)
    case invalidRecordSave(ResourceKey)
    case invalidTombstone(ResourceKey)
    case invalidAuditEvent
    case invalidReceipt
}
