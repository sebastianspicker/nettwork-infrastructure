import Foundation
import XCTest

@testable import NetworkModel

final class TemplatesPlacementTests: XCTestCase {
    func testCloneVersionInstantiationAndExplicitMigrationPreserveSnapshot() throws {
        let roleSchema = CustomFieldSchema(key: "role", displayName: "Role", kind: .choice, isRequired: true, choices: ["access", "core"])
        let modulePort = PortTemplate(id: id(1), name: "SFP1", medium: .fiber, connector: .lc, order: 1, face: .front)
        let module = ModuleTemplate(
            id: id(2), name: "SFP module", ports: [modulePort], customFieldSchemas: [CustomFieldSchema(key: "speed", displayName: "Speed", kind: .number)])
        let directFront = PortTemplate(
            id: id(3), name: "Gi1", medium: .copper, connector: .rj45, order: 1, face: .front,
            customFieldSchemas: [CustomFieldSchema(key: "poe", displayName: "PoE", kind: .flag, isRequired: true)])
        let directRear = PortTemplate(id: id(4), name: "Console", medium: .other, connector: .other, order: 1, face: .rear)
        let template = DeviceType(
            id: id(5), name: "Access switch", kind: .switchDevice, rackHeightRU: 2, portTemplates: [directRear, directFront],
            moduleSlots: [ModuleSlotTemplate(key: "uplink", displayName: "Uplink", allowedModuleTemplateIDs: [module.id], isRequired: true)],
            customFieldSchemas: [roleSchema])
        try TemplateCatalog.validate(deviceTemplate: template, moduleTemplates: [module])
        let clonedModule = try TemplateCatalog.clone(module, id: id(6), portIDs: [modulePort.id: id(7)])
        XCTAssertEqual(clonedModule.version, 1)
        XCTAssertEqual(clonedModule.ports.map(\.id), [id(7)])
        let clone = try TemplateCatalog.clone(template, id: id(8), portIDs: [directFront.id: id(9), directRear.id: id(10)])
        XCTAssertEqual(clone.id, id(8))
        XCTAssertEqual(clone.version, 1)
        XCTAssertEqual(clone.portTemplates.map(\.id), [id(10), id(9)])
        let instantiation = try TemplateInstantiator.instantiate(
            template: template,
            request: DeviceInstantiationRequest(
                deviceID: id(11), assetCode: "SW-1", name: "Switch 1", customFields: [CustomFieldValue(key: "ROLE", value: .text("access"))],
                modulesBySlot: ["uplink": module], moduleIDsBySlot: ["uplink": id(12)],
                moduleCustomFieldsBySlot: ["uplink": [CustomFieldValue(key: "speed", value: .number(10))]],
                portIDsByTemplateID: [directFront.id: id(13), directRear.id: id(14), modulePort.id: id(15)],
                portCustomFieldsByTemplateID: [directFront.id: [CustomFieldValue(key: "poe", value: .flag(true))]]))
        XCTAssertEqual(instantiation.device.templateSnapshot, DeviceTemplateSnapshot(template: template))
        XCTAssertEqual(instantiation.device.customFields, [CustomFieldValue(key: "role", value: .text("access"))])
        XCTAssertEqual(instantiation.modules.map(\.id), [id(12)])
        XCTAssertEqual(instantiation.modules.first?.customFields, [CustomFieldValue(key: "speed", value: .number(10))])
        XCTAssertEqual(instantiation.ports.map(\.id), [id(13), id(14), id(15)])
        XCTAssertEqual(instantiation.ports.map(\.label), ["Gi1", "Console", "SFP1"])
        XCTAssertEqual(instantiation.ports.map(\.templatePortID), [directFront.id, directRear.id, modulePort.id])
        XCTAssertEqual(instantiation.ports.first?.customFields, [CustomFieldValue(key: "poe", value: .flag(true))])
        XCTAssertNoThrow(try TemplateInstantiator.validate(instantiation, against: template, moduleTemplates: [module]))
        var updated = try TemplateCatalog.nextVersion(of: template)
        updated.portTemplates.append(PortTemplate(id: id(16), name: "Gi2", medium: .copper, connector: .rj45, order: 2))
        let plan = try TemplateMigration.plan(
            device: instantiation.device,
            installedPorts: instantiation.ports,
            cables: [],
            target: updated,
            newPortIDs: [id(16): id(17)]
        )
        XCTAssertEqual(plan.sourceSnapshot.version, 1)
        XCTAssertEqual(plan.targetSnapshot.version, 2)
        let added = try XCTUnwrap(plan.portImpacts.first { $0.templatePortID == id(16) })
        XCTAssertEqual(added.action, .add)
        XCTAssertFalse(added.requiresCableReview)
        XCTAssertEqual(added.desiredPort?.id, id(17))
        XCTAssertEqual(added.desiredPort?.templatePortID, id(16))
        var migrated = instantiation.device
        try TemplateMigration.apply(plan, to: &migrated)
        XCTAssertEqual(migrated.templateSnapshot?.version, 2)
        XCTAssertEqual(instantiation.device.templateSnapshot?.version, 1)
    }

    func testRackFacesOverlapsMovesReservationsAndDeletionGuards() throws {
        let fixture = placementFixture()
        var state = fixture.state
        let front = RackPlacement(deviceID: fixture.firstDeviceID, rackID: fixture.rackID, startRU: 1, heightRU: 2, face: .front)
        try state.place(front)

        XCTAssertThrowsError(try state.place(RackPlacement(deviceID: fixture.secondDeviceID, rackID: fixture.rackID, startRU: 2, heightRU: 2, face: .front)))
        try state.place(RackPlacement(deviceID: fixture.secondDeviceID, rackID: fixture.rackID, startRU: 1, heightRU: 2, face: .rear))
        XCTAssertThrowsError(try state.place(RackPlacement(deviceID: fixture.firstDeviceID, rackID: fixture.rackID, startRU: 1, heightRU: 2, face: .rear)))
        XCTAssertThrowsError(try state.place(RackPlacement(deviceID: fixture.firstDeviceID, rackID: fixture.rackID, startRU: 8, heightRU: 2, face: .front)))
        XCTAssertEqual(state.placements.count, 2)
        XCTAssertThrowsError(try state.reserve(RackPlacementReservation(id: id(40), rackID: fixture.rackID, startRU: 2, heightRU: 1, face: .front)))
        try state.reserve(RackPlacementReservation(id: id(41), rackID: fixture.rackID, startRU: 3, heightRU: 1, face: .front))

        try state.place(RackPlacement(deviceID: fixture.firstDeviceID, rackID: fixture.rackID, startRU: 5, heightRU: 2, face: .front))
        XCTAssertEqual(state.placements.first(where: { $0.deviceID == fixture.firstDeviceID })?.startRU, 5)
        XCTAssertThrowsError(try state.validateDeviceDeletion(fixture.firstDeviceID))
        try state.removePlacement(for: fixture.firstDeviceID)
        try state.validateDeviceDeletion(fixture.firstDeviceID)
        try state.validate()
    }

    func testInstallCommandPreservesModulesAndRejectsCrossDeviceModulePorts() throws {
        let type = DeviceType(id: id(70), name: "Modular", kind: .switchDevice)
        let device = Device(id: id(71), assetCode: "SW-71", name: "Switch", typeID: type.id)
        let module = Module(id: id(72), deviceID: device.id, templateID: id(73), slot: "uplink")
        let port = NetworkModel.Port(id: id(74), deviceID: device.id, moduleID: module.id, label: "SFP1", medium: .fiber, connector: .lc)
        var topology = PhysicalTopology(deviceTypes: [type])

        _ = try topology.apply(.install(InstallTopologyCommand(device: device, modules: [module], ports: [port])))
        XCTAssertEqual(topology.modules, [module])
        XCTAssertEqual(topology.ports, [port])

        var invalid = PhysicalTopology(deviceTypes: [type])
        let foreignModule = Module(id: id(75), deviceID: id(76), templateID: id(73), slot: "uplink")
        XCTAssertThrowsError(try invalid.apply(.install(InstallTopologyCommand(device: device, modules: [foreignModule], ports: []))))
    }

    func testNormalizedAnchorsRoundTripAndRequireOwningFloor() throws {
        let fixture = placementFixture()
        var state = fixture.state
        try state.place(RackPlacement(deviceID: fixture.firstDeviceID, rackID: fixture.rackID, startRU: 1, heightRU: 2, face: .front))
        let anchor = FloorPlanAnchor(id: id(50), objectID: fixture.firstDeviceID, floorID: fixture.floorID, x: 0, y: 1)
        try state.addAnchor(anchor)
        let encoded = try JSONEncoder().encode(state.anchors)
        XCTAssertEqual(try JSONDecoder().decode([FloorPlanAnchor].self, from: encoded), [anchor])
        XCTAssertThrowsError(try state.addAnchor(FloorPlanAnchor(id: id(51), objectID: fixture.rackID, floorID: fixture.floorID, x: 1.001, y: 0.5)))

        var hierarchy = fixture.state.hierarchy
        let secondFloor = Location(id: id(52), name: "Second", kind: .floor, parentID: fixture.buildingID)
        let secondRoom = Location(id: id(53), name: "201", kind: .room, parentID: secondFloor.id)
        hierarchy.locations.append(contentsOf: [secondFloor, secondRoom])
        var wrongFloorState = TemplatePlacementState(
            hierarchy: hierarchy, topology: state.topology, placements: state.placements, rackReservations: state.rackReservations)
        XCTAssertThrowsError(try wrongFloorState.addAnchor(FloorPlanAnchor(id: id(54), objectID: fixture.rackID, floorID: secondFloor.id, x: 0.5, y: 0.5)))
    }

    private func placementFixture() -> (
        state: TemplatePlacementState, buildingID: ObjectID, floorID: ObjectID, rackID: ObjectID, firstDeviceID: ObjectID, secondDeviceID: ObjectID
    ) {
        let workspace = Location(id: id(60), name: "Workspace", kind: .workspace)
        let site = Location(id: id(61), name: "Site", kind: .site, parentID: workspace.id)
        let building = Location(id: id(62), name: "Building", kind: .building, parentID: site.id)
        let floor = Location(id: id(63), name: "Floor", kind: .floor, parentID: building.id)
        let room = Location(id: id(64), name: "Room", kind: .room, parentID: floor.id)
        let rack = Rack(id: id(65), assetCode: "R-1", locationID: room.id, heightRU: 8)
        let type = DeviceType(id: id(66), name: "2RU", kind: .generic, rackHeightRU: 2)
        let firstDevice = Device(id: id(67), assetCode: "D-1", name: "First", typeID: type.id)
        let secondDevice = Device(id: id(68), assetCode: "D-2", name: "Second", typeID: type.id)
        return (
            TemplatePlacementState(
                hierarchy: WorkspaceHierarchy(locations: [workspace, site, building, floor, room], racks: [rack]),
                topology: PhysicalTopology(deviceTypes: [type], devices: [firstDevice, secondDevice])), building.id, floor.id, rack.id, firstDevice.id,
            secondDevice.id
        )
    }

    private func id(_ number: Int) -> ObjectID {
        ObjectID(UUID(uuidString: String(format: "90000000-0000-0000-0000-%012d", number))!)
    }
}
