import CloudSync
import Foundation
import NetworkModel
import XCTest

@testable import ImportExport
@testable import WorkspaceChangeControl
@testable import WorkspaceServices

/// Work orders stored before sets were encoded sorted hold their set arrays in
/// hash order. Every canonical reader must still accept those exact bytes.
final class LegacySetOrderReaderTests: XCTestCase {
    func testCanonicalDecodedAcceptsLegacySetOrder() throws {
        let fixture = try LegacyWorkOrderFixture()
        let legacy = try fixture.legacyBytes()

        XCTAssertEqual(canonicalDecoded(WorkOrder.self, from: legacy), fixture.order)
    }

    func testArchiveWorkOrderValidationAcceptsLegacySetOrder() throws {
        let fixture = try LegacyWorkOrderFixture()
        let record = WorkspaceTransferRecord(
            resourceKey: .object(fixture.order.id), recordType: .workOrder, payload: try fixture.legacyBytes())

        XCTAssertEqual(try WorkspaceTransferCandidate.decodeOperationalWorkOrder(record), fixture.order)
    }

    func testAttachmentActivationWorkOrderCheckAcceptsLegacySetOrder() throws {
        let fixture = try LegacyWorkOrderFixture()
        let canonical = try fixture.activation(encodedWorkOrder: try CloudDeterministicCoding.encode(fixture.order))
        let legacy = try fixture.activation(encodedWorkOrder: try fixture.legacyBytes())

        XCTAssertEqual(try AuthoritativeActivationMutationValidator.attachmentWorkOrder(canonical, bindingSave: fixture.bindingSave), fixture.order)
        XCTAssertEqual(try AuthoritativeActivationMutationValidator.attachmentWorkOrder(legacy, bindingSave: fixture.bindingSave), fixture.order)
    }
}

/// A reserved, acknowledged work order with six reserved resources, so reversed
/// set arrays always differ from the sorted canonical order.
private struct LegacyWorkOrderFixture {
    let order: WorkOrder
    let zone = AuthoritativeWorkspaceZone(
        workspaceID: ObjectID(), containerIdentifier: "iCloud.example.nettwork", zoneName: "workspace", zoneOwnerRecordName: "owner")
    let actor = ActorInstallationSnapshot(
        actorID: "technician", installationID: "ipad-1", sessionID: "session-1", sessionGeneration: 1,
        capturedAt: Date(timeIntervalSince1970: 1_727_713_000))
    let bindingSave = AuthoritativeRecordSave(
        resourceKey: .object(ObjectID()), recordType: WorkspaceRecordType.attachmentEvidenceBinding, schemaVersion: 1, encodedRecord: Data([1]))

    init() throws {
        let ids = (0..<6).map { _ in ObjectID() }
        let keys = Set(ids.map(ResourceKey.object))
        let workOrderID = ObjectID()
        let reservationID = ObjectID()
        let digest = try CanonicalWorkIntent(
            workOrderID: workOrderID, kind: .device, creatorID: "technician", ticket: nil, notes: nil, operations: [], resourceKeys: keys,
            evidenceHashes: []
        ).digest()
        let acknowledgement = CloudKitAcknowledgement(
            workspaceZone: zone, cloudKitAccountRecordName: actor.actorID, sessionGeneration: actor.sessionGeneration, reservationID: reservationID,
            workOrderID: workOrderID, ownerID: actor.actorID, resourceKeys: keys, intentDigest: digest, systemFields: Data([1]),
            changeTag: "reservation-v1", acknowledgedAt: Date(timeIntervalSince1970: 1_727_712_345),
            expiresAt: Date(timeIntervalSince1970: 1_727_715_945))
        order = WorkOrder(
            id: workOrderID, kind: .device, title: "Update devices", status: .reserved, reservedResourceIDs: Set(ids), creatorID: actor.actorID,
            intentDigest: digest,
            reservation: WorkOrderReservation(id: reservationID, ownerID: actor.actorID, resourceKeys: keys, acknowledgedByCloudKit: acknowledgement))
    }

    /// The canonical bytes with every set array reversed, as a build before
    /// sorted set encoding could have stored them. Nothing else changes.
    func legacyBytes() throws -> Data {
        let canonical = try CloudDeterministicCoding.encode(order)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        XCTAssertEqual(try Self.serialized(json), canonical, "The rewrite must change nothing but set order.")
        var reservation = try XCTUnwrap(json["reservation"] as? [String: Any])
        var acknowledgement = try XCTUnwrap(reservation["acknowledgedByCloudKit"] as? [String: Any])
        json["reservedResourceIDs"] = try XCTUnwrap(json["reservedResourceIDs"] as? [Any]).reversed() as [Any]
        reservation["resourceKeys"] = try XCTUnwrap(reservation["resourceKeys"] as? [Any]).reversed() as [Any]
        acknowledgement["resourceKeys"] = try XCTUnwrap(acknowledgement["resourceKeys"] as? [Any]).reversed() as [Any]
        reservation["acknowledgedByCloudKit"] = acknowledgement
        json["reservation"] = reservation
        let legacy = try Self.serialized(json)
        XCTAssertNotEqual(legacy, canonical)
        return legacy
    }

    func activation(encodedWorkOrder: Data) throws -> AuthoritativeActivationMutation {
        let operationID = ObjectID()
        return try AuthoritativeActivationMutation(
            workspaceZone: zone, operationID: operationID, intentDigest: try XCTUnwrap(order.intentDigest), actor: actor, saves: [bindingSave],
            tombstones: [], preconditions: [],
            readAssertions: [
                AuthoritativeReadAssertion(
                    resourceKey: .object(order.id), recordType: WorkspaceRecordType.workOrder, schemaVersion: 1, encodedRecord: encodedWorkOrder,
                    precondition: ExactRecordPrecondition(systemFields: Data([2]), changeTag: "work-order-v1"))
            ],
            auditEvent: AuditEvent(operationID: operationID, actorID: actor.actorID, affectedObjectIDs: [], result: .accepted))
    }

    private static func serialized(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
