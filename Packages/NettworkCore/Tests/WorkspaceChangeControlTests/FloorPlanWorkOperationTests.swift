import Foundation
import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

final class FloorPlanWorkOperationTests: XCTestCase {
    func testFloorPlanOperationRoundTripsItsTypedAnchorPayload() throws {
        let anchor = FloorPlanAnchor(
            id: ObjectID(),
            objectID: ObjectID(),
            floorID: ObjectID(),
            x: 0.25,
            y: 0.75
        )
        let operation = PlannedWorkOperation.floorPlan(.upsert(anchor))

        let encoded = try JSONEncoder().encode(operation)

        XCTAssertEqual(try JSONDecoder().decode(PlannedWorkOperation.self, from: encoded), operation)
        XCTAssertEqual(
            PlannedFloorPlanOperation.upsert(anchor).resourceKeys,
            [.object(anchor.id), .object(anchor.objectID), .object(anchor.floorID)]
        )
    }

    func testFloorPlanIntentDigestDistinguishesUpsertFromRemoval() throws {
        let anchor = FloorPlanAnchor(
            id: ObjectID(),
            objectID: ObjectID(),
            floorID: ObjectID(),
            x: 0.5,
            y: 0.5
        )
        let workOrderID = ObjectID()
        let resourceKeys: Set<ResourceKey> = [.object(anchor.id), .object(anchor.objectID), .object(anchor.floorID)]
        let upsert = CanonicalWorkIntent(
            workOrderID: workOrderID,
            kind: .floorPlan,
            creatorID: "technician",
            ticket: "CHG-42",
            notes: nil,
            operations: [.floorPlan(.upsert(anchor))],
            resourceKeys: resourceKeys,
            evidenceHashes: []
        )
        let removal = CanonicalWorkIntent(
            workOrderID: workOrderID,
            kind: .floorPlan,
            creatorID: "technician",
            ticket: "CHG-42",
            notes: nil,
            operations: [.floorPlan(.remove(anchor))],
            resourceKeys: resourceKeys,
            evidenceHashes: []
        )

        XCTAssertNotEqual(try upsert.digest(), try removal.digest())
    }

    func testDeviceDecommissionRoundTripsItsCompleteDependentResourceSet() throws {
        let deviceID = ObjectID()
        let rackID = ObjectID()
        let module = Module(deviceID: deviceID, templateID: ObjectID(), slot: "uplink")
        let port = NetworkModel.Port(deviceID: deviceID, moduleID: module.id, label: "xe-0/0/0", medium: .fiber, connector: .lc)
        let placement = RackPlacement(deviceID: deviceID, rackID: rackID, startRU: 8, heightRU: 1, face: .front)
        let anchor = FloorPlanAnchor(objectID: deviceID, floorID: ObjectID(), x: 0.25, y: 0.75)
        let interface = Interface(deviceID: deviceID, physicalPortID: port.id, name: "xe-0/0/0", mode: .access)
        let address = IPAddressRecord(vrfID: ObjectID(), address: try XCTUnwrap(IPAddress(parsing: "192.0.2.10")), assignedInterfaceID: interface.id)
        let assignment = IPAddressAssignment(addressID: address.id, interfaceID: interface.id, isPrimary: true)
        let membership = InterfaceVLANMembership(interfaceID: interface.id, vlanID: ObjectID(), isNative: true)
        let decommission = PlannedDeviceDecommission(
            removal: RemoveTopologyCommand(deviceID: deviceID, deletedAt: .distantPast),
            device: Device(id: deviceID, assetCode: "EDGE-01", name: "Edge switch", typeID: ObjectID(), rackID: rackID),
            modules: [module],
            ports: [port],
            rackPlacements: [placement],
            floorPlanAnchors: [anchor],
            interfaces: [interface],
            addressAssignments: [assignment],
            vlanMemberships: [membership],
            addresses: [address]
        )
        let operation = PlannedWorkOperation.deviceDecommission(decommission)

        XCTAssertEqual(try JSONDecoder().decode(PlannedWorkOperation.self, from: JSONEncoder().encode(operation)), operation)
        XCTAssertEqual(
            decommission.resourceKeys,
            [
                .object(deviceID), .object(module.id), .object(port.id),
                .rackPlacement(deviceID: deviceID), .object(rackID),
                .object(anchor.id), .object(anchor.objectID), .object(anchor.floorID),
                .object(interface.id), .object(assignment.id),
                .object(membership.id), .object(membership.vlanID),
                .string(address.id),
            ]
        )
    }

    func testPlannedFloorPlanAssetCarriesOnlyImmutableMetadataAndProtectsItsFloor() throws {
        let floorID = ObjectID()
        let bytes = Data("floor-plan-jpeg".utf8)
        let metadata = try CloudRecordAssetMetadata(
            id: ObjectID(),
            fieldName: "floorPlanAsset",
            sha256: CloudRecordAssetDescriptor.sha256(for: bytes),
            contentType: "image/jpeg",
            byteCount: bytes.count
        )
        let planned = try PlannedFloorPlanAsset(floorID: floorID, assetMetadata: metadata)
        let operation = PlannedFloorPlanOperation.bindAsset(planned)

        XCTAssertEqual(
            operation.resourceKeys,
            [.object(floorID), .floorPlanAssetBinding(for: floorID)]
        )
        XCTAssertEqual(try JSONDecoder().decode(PlannedFloorPlanAsset.self, from: JSONEncoder().encode(planned)), planned)
        XCTAssertThrowsError(
            try PlannedFloorPlanAsset(
                floorID: floorID,
                assetMetadata: CloudRecordAssetMetadata(
                    id: metadata.id,
                    fieldName: "floorPlanAsset",
                    sha256: metadata.sha256,
                    contentType: "application/pdf",
                    byteCount: metadata.byteCount
                )
            ))
    }
}
