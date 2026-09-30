import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

/// Canonical readers accept a payload only when decoding and re-encoding it
/// reproduces the exact bytes, so set-valued fields must not encode in hash
/// iteration order.
final class CanonicalSetEncodingTests: XCTestCase {
    private let cycles = 50

    func testReservedWorkOrderReencodesToIdenticalBytesAcrossDecodeCycles() throws {
        let original = try CloudDeterministicCoding.encode(try reservedOrder(keyCount: 6))
        var bytes = original
        var changedCycles = 0
        for _ in 0..<cycles {
            bytes = try CloudDeterministicCoding.encode(CloudDeterministicCoding.decode(WorkOrder.self, from: bytes))
            if bytes != original { changedCycles += 1 }
        }
        XCTAssertEqual(changedCycles, 0)
    }

    func testAcknowledgementReencodesToIdenticalBytesAcrossDecodeCycles() throws {
        let acknowledgement = try XCTUnwrap(try reservedOrder(keyCount: 6).reservation?.acknowledgedByCloudKit)
        let original = try CloudDeterministicCoding.encode(acknowledgement)
        var bytes = original
        var changedCycles = 0
        for _ in 0..<cycles {
            bytes = try CloudDeterministicCoding.encode(CloudDeterministicCoding.decode(CloudKitAcknowledgement.self, from: bytes))
            if bytes != original { changedCycles += 1 }
        }
        XCTAssertEqual(changedCycles, 0)
    }

    func testPayloadEncodedBeforeCanonicalOrderingStillDecodes() throws {
        let order = try reservedOrder(keyCount: 6)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: CloudDeterministicCoding.encode(order)) as? [String: Any])
        var reservation = try XCTUnwrap(json["reservation"] as? [String: Any])
        var acknowledgement = try XCTUnwrap(reservation["acknowledgedByCloudKit"] as? [String: Any])
        let legacyMilliseconds = 1_000 * (1_727_712_345.678 + Double.random(in: 0..<0.001))
        json["reservedResourceIDs"] = try XCTUnwrap(json["reservedResourceIDs"] as? [Any]).reversed() as [Any]
        json["approvedAt"] = legacyMilliseconds
        reservation["resourceKeys"] = try XCTUnwrap(reservation["resourceKeys"] as? [Any]).reversed() as [Any]
        acknowledgement["resourceKeys"] = try XCTUnwrap(acknowledgement["resourceKeys"] as? [Any]).reversed() as [Any]
        acknowledgement["acknowledgedAt"] = legacyMilliseconds
        reservation["acknowledgedByCloudKit"] = acknowledgement
        json["reservation"] = reservation
        let legacy = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        let decoded = try CloudDeterministicCoding.decode(WorkOrder.self, from: legacy)
        XCTAssertEqual(decoded.reservedResourceIDs, order.reservedResourceIDs)
        XCTAssertEqual(decoded.reservation?.resourceKeys, order.reservation?.resourceKeys)
        XCTAssertEqual(decoded.reservation?.acknowledgedByCloudKit?.resourceKeys, order.reservation?.resourceKeys)
        XCTAssertEqual(try XCTUnwrap(decoded.approvedAt).timeIntervalSince1970, legacyMilliseconds / 1_000, accuracy: 0.000_001)
        let canonical = try CloudDeterministicCoding.encode(decoded)
        XCTAssertEqual(try CloudDeterministicCoding.decode(WorkOrder.self, from: canonical), decoded)
        XCTAssertEqual(try CloudDeterministicCoding.encode(CloudDeterministicCoding.decode(WorkOrder.self, from: canonical)), canonical)
    }

    /// WorkOrder, WorkOrderReservation, and CloudKitAcknowledgement encode by
    /// hand to sort their sets. A stored property added later must also be
    /// added to `encode(to:)`, so every stored property label of a fully
    /// populated value must appear as an encoded key.
    func testHandWrittenEncodersEncodeEveryStoredProperty() throws {
        var order = try reservedOrder(keyCount: 2)
        order.cancellationReason = "superseded"
        order.ticket = "CHG-1"
        order.notes = "notes"
        order.approvedBy = "administrator"
        order.executedBy = "technician"
        order.executionStartedAt = Date(timeIntervalSince1970: 1_727_712_500)
        order.completedAt = Date(timeIntervalSince1970: 1_727_712_600)
        let reservation = try XCTUnwrap(order.reservation)
        let acknowledgement = try XCTUnwrap(reservation.acknowledgedByCloudKit)
        try assertEncodesEveryStoredProperty(order)
        try assertEncodesEveryStoredProperty(reservation)
        try assertEncodesEveryStoredProperty(acknowledgement)
    }

    private func assertEncodesEveryStoredProperty<Value: Encodable>(_ value: Value, file: StaticString = #filePath, line: UInt = #line) throws {
        let labels = Set(Mirror(reflecting: value).children.compactMap(\.label))
        let object = try JSONSerialization.jsonObject(with: CloudDeterministicCoding.encode(value)) as? [String: Any]
        let keys = Set(try XCTUnwrap(object, file: file, line: line).keys)
        XCTAssertEqual(labels.subtracting(keys), [], "\(Value.self) omits stored properties from encode(to:)", file: file, line: line)
    }

    private func reservedOrder(keyCount: Int) throws -> WorkOrder {
        let ids = (0..<keyCount).map { _ in ObjectID() }
        let keys = Set(ids.map(ResourceKey.object))
        let workOrderID = ObjectID()
        let reservationID = ObjectID()
        let digest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 7, count: 32))
        let acknowledgement = CloudKitAcknowledgement(
            workspaceZone: AuthoritativeWorkspaceZone(
                workspaceID: ObjectID(), containerIdentifier: "iCloud.example.nettwork", zoneName: "workspace", zoneOwnerRecordName: "owner"),
            cloudKitAccountRecordName: "technician", sessionGeneration: 1, reservationID: reservationID, workOrderID: workOrderID,
            ownerID: "technician", resourceKeys: keys, intentDigest: digest, systemFields: Data([1]), changeTag: "reservation-v1",
            acknowledgedAt: Date(timeIntervalSince1970: 1_727_712_345), expiresAt: Date(timeIntervalSince1970: 1_727_715_945))
        return WorkOrder(
            id: workOrderID, kind: .device, title: "Update devices", status: .reserved, reservedResourceIDs: Set(ids), creatorID: "technician",
            intentDigest: digest,
            reservation: WorkOrderReservation(id: reservationID, ownerID: "technician", resourceKeys: keys, acknowledgedByCloudKit: acknowledgement),
            approvedAt: Date(timeIntervalSince1970: 1_727_712_400))
    }
}
