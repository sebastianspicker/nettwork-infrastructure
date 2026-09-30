import Foundation
import NetworkModel

public struct WorkOrder: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var kind: WorkOrderKind
    public var status: WorkOrderStatus
    public var title: String
    /// Legacy object-only reservation shape. New calls should use the reservation property.
    public var reservedResourceIDs: Set<ObjectID>
    public var cancellationReason: String?
    public var creatorID: String
    public var ticket: String?
    public var notes: String?
    public var plannedOperations: [PlannedWorkOperation]
    public private(set) var revision: Int
    /// Set at creation and never rewritten. Legacy work orders may have no digest.
    public let intentDigest: IntentDigest?
    /// Missing on legacy rows means canonical intent v1. New reservations
    /// persist the exact version so future clients never reinterpret a digest.
    public let intentSchemaVersion: Int?
    public var reservation: WorkOrderReservation?
    public var approvedBy: String?
    public var approvedAt: Date?
    public var executedBy: String?
    public var executionStartedAt: Date?
    public var completedAt: Date?
    public var evidenceHashes: [EvidenceHash]
    public var cancellationHistory: [WorkOrderCancellation]

    public init(
        id: ObjectID = .init(), kind: WorkOrderKind, title: String, status: WorkOrderStatus = .draft, reservedResourceIDs: Set<ObjectID> = [],
        creatorID: String = "legacy-unspecified", ticket: String? = nil,
        notes: String? = nil, plannedOperations: [PlannedWorkOperation] = [], revision: Int = 0, intentDigest: IntentDigest? = nil,
        intentSchemaVersion: Int? = CanonicalWorkIntent.schemaVersion,
        reservation: WorkOrderReservation? = nil, approvedBy: String? = nil, approvedAt: Date? = nil, executedBy: String? = nil,
        executionStartedAt: Date? = nil, completedAt: Date? = nil,
        evidenceHashes: [EvidenceHash] = [], cancellationHistory: [WorkOrderCancellation] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.reservedResourceIDs = reservedResourceIDs
        self.cancellationReason = nil
        self.creatorID = creatorID
        self.ticket = ticket
        self.notes = notes
        self.plannedOperations = plannedOperations
        self.revision = max(0, revision)
        self.intentDigest = intentDigest
        self.intentSchemaVersion = intentSchemaVersion
        self.reservation = reservation
        self.approvedBy = approvedBy
        self.approvedAt = approvedAt?.canonicalPayloadTimestamp
        self.executedBy = executedBy
        self.executionStartedAt = executionStartedAt?.canonicalPayloadTimestamp
        self.completedAt = completedAt?.canonicalPayloadTimestamp
        self.evidenceHashes = evidenceHashes
        self.cancellationHistory = cancellationHistory
    }

    public var reservedResourceKeys: Set<ResourceKey> {
        (reservation?.resourceKeys ?? []).union(reservedResourceIDs.map(ResourceKey.object))
    }
    mutating func advanceRevision() { revision += 1 }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(status, forKey: .status)
        try container.encode(title, forKey: .title)
        try container.encodeSorted(reservedResourceIDs, forKey: .reservedResourceIDs)
        try container.encodeIfPresent(cancellationReason, forKey: .cancellationReason)
        try container.encode(creatorID, forKey: .creatorID)
        try container.encodeIfPresent(ticket, forKey: .ticket)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(plannedOperations, forKey: .plannedOperations)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(intentDigest, forKey: .intentDigest)
        try container.encodeIfPresent(intentSchemaVersion, forKey: .intentSchemaVersion)
        try container.encodeIfPresent(reservation, forKey: .reservation)
        try container.encodeIfPresent(approvedBy, forKey: .approvedBy)
        try container.encodeIfPresent(approvedAt, forKey: .approvedAt)
        try container.encodeIfPresent(executedBy, forKey: .executedBy)
        try container.encodeIfPresent(executionStartedAt, forKey: .executionStartedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(evidenceHashes, forKey: .evidenceHashes)
        try container.encode(cancellationHistory, forKey: .cancellationHistory)
    }
}
