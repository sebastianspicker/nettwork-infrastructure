import Foundation
import NetworkModel

public struct CloudKitAcknowledgement: Codable, Hashable, Sendable {
    public let workspaceZone: AuthoritativeWorkspaceZone
    public let cloudKitAccountRecordName: String
    public let sessionGeneration: UInt64
    public let reservationID: ObjectID
    public let workOrderID: ObjectID
    public let ownerID: String
    public let resourceKeys: Set<ResourceKey>
    public let intentDigest: IntentDigest
    public let systemFields: Data
    public let changeTag: String
    public let acknowledgedAt: Date
    public let expiresAt: Date

    public init(
        workspaceZone: AuthoritativeWorkspaceZone, cloudKitAccountRecordName: String, sessionGeneration: UInt64, reservationID: ObjectID, workOrderID: ObjectID,
        ownerID: String, resourceKeys: Set<ResourceKey>,
        intentDigest: IntentDigest, systemFields: Data, changeTag: String, acknowledgedAt: Date, expiresAt: Date
    ) {
        self.workspaceZone = workspaceZone
        self.cloudKitAccountRecordName = cloudKitAccountRecordName
        self.sessionGeneration = sessionGeneration
        self.reservationID = reservationID
        self.workOrderID = workOrderID
        self.ownerID = ownerID
        self.resourceKeys = resourceKeys
        self.intentDigest = intentDigest
        self.systemFields = systemFields
        self.changeTag = changeTag
        self.acknowledgedAt = acknowledgedAt
        self.expiresAt = expiresAt
    }
}
public struct WorkOrderReservation: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public let ownerID: String
    public let resourceKeys: Set<ResourceKey>
    public let acknowledgedByCloudKit: CloudKitAcknowledgement?
    public init(id: ObjectID = .init(), ownerID: String, resourceKeys: Set<ResourceKey>, acknowledgedByCloudKit: CloudKitAcknowledgement? = nil) {
        self.id = id
        self.ownerID = ownerID
        self.resourceKeys = resourceKeys
        self.acknowledgedByCloudKit = acknowledgedByCloudKit
    }

    public static func deterministicID(for operationID: ObjectID) -> ObjectID {
        DeterministicWorkOrderObjectID.make(domain: "reservation", seed: operationID.description)
    }
}

/// Durable, same-zone exclusion record for one reserved resource. The lock key
/// is derived from `resourceKey`, so two work orders cannot reserve the same
/// resource when both commits use a `mustNotExist` precondition.
public struct ResourceReservationLock: Codable, Hashable, Sendable, Identifiable {
    public var id: ResourceKey { .reservationLock(for: resourceKey) }
    public let resourceKey: ResourceKey
    public let workOrderID: ObjectID
    public let reservationID: ObjectID
    public let ownerID: String
    public let intentDigest: IntentDigest
    public let expiresAt: Date

    public init(
        resourceKey: ResourceKey, workOrderID: ObjectID, reservationID: ObjectID, ownerID: String,
        intentDigest: IntentDigest, expiresAt: Date
    ) {
        self.resourceKey = resourceKey
        self.workOrderID = workOrderID
        self.reservationID = reservationID
        self.ownerID = ownerID
        self.intentDigest = intentDigest
        self.expiresAt = expiresAt
    }
}

public enum ResourceReservationLockFactoryError: Error, Hashable, Sendable {
    case missingReservation
    case invalidIntent
    case invalidExpiry
}

public enum ResourceReservationLockFactory {
    public static func saves(
        for workOrder: WorkOrder, expiresAt: Date, observedAt: Date = .now
    ) throws -> [AuthoritativeRecordSave] {
        let locks = try makeLocks(for: workOrder, expiresAt: expiresAt, observedAt: observedAt)
        return try locks.map { lock in
            AuthoritativeRecordSave(
                resourceKey: lock.id, recordType: "ResourceReservationLock",
                schemaVersion: 1, encodedRecord: try encode(lock))
        }
    }

    public static func tombstones(
        for workOrder: WorkOrder, deletedAt: Date = .now
    ) throws -> [AuthoritativeTombstone] {
        guard let reservation = workOrder.reservation, let intentDigest = workOrder.intentDigest else {
            throw ResourceReservationLockFactoryError.missingReservation
        }
        return try reservation.resourceKeys.sorted().map { resourceKey in
            let lock = ResourceReservationLock(
                resourceKey: resourceKey, workOrderID: workOrder.id,
                reservationID: reservation.id, ownerID: reservation.ownerID, intentDigest: intentDigest,
                expiresAt: reservation.acknowledgedByCloudKit?.expiresAt ?? deletedAt)
            return AuthoritativeTombstone(
                resourceKey: lock.id, recordType: "ResourceReservationLock",
                deletedAt: deletedAt, encodedTombstone: try encode(lock))
        }
    }

    private static func makeLocks(
        for workOrder: WorkOrder, expiresAt: Date, observedAt: Date
    ) throws -> [ResourceReservationLock] {
        guard workOrder.status == .reserved, let reservation = workOrder.reservation,
            !reservation.resourceKeys.isEmpty, let intentDigest = workOrder.intentDigest
        else {
            throw ResourceReservationLockFactoryError.missingReservation
        }
        guard observedAt < expiresAt else {
            throw ResourceReservationLockFactoryError.invalidExpiry
        }
        let canonical = CanonicalWorkIntent(
            intentSchemaVersion: workOrder.intentSchemaVersion ?? 1,
            workOrderID: workOrder.id, kind: workOrder.kind, creatorID: workOrder.creatorID,
            ticket: workOrder.ticket, notes: workOrder.notes, operations: workOrder.plannedOperations,
            resourceKeys: reservation.resourceKeys, evidenceHashes: workOrder.evidenceHashes)
        guard (try? canonical.digest()) == intentDigest else {
            throw ResourceReservationLockFactoryError.invalidIntent
        }
        return reservation.resourceKeys.sorted().map { resourceKey in
            ResourceReservationLock(
                resourceKey: resourceKey, workOrderID: workOrder.id,
                reservationID: reservation.id, ownerID: reservation.ownerID, intentDigest: intentDigest,
                expiresAt: expiresAt)
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
