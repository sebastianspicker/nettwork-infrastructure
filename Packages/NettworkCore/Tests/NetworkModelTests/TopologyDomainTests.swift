import Foundation
import XCTest

@testable import NetworkModel

final class TopologyDomainTests: XCTestCase {
    func testTableDrivenCableCompatibilityAndGraphRejections() throws {
        let fixture = NetworkModelTestData.passThroughTopology()
        try DefaultTopologyEngine.validate(fixture.topology)

        let firstPort = fixture.startPortID
        let secondPort = fixture.endPortID
        let cases: [(String, PhysicalTopology, TopologyValidationError)] = [
            (
                "self cable",
                topology(
                    with: Cable(
                        id: fixedID(1), assetCode: "SELF", endpointA: firstPort, endpointB: firstPort, medium: .copper, connector: .rj45, kind: .patchCord,
                        status: .installed), replacing: fixture.topology), .selfConnection(fixedID(1))
            ),
            (
                "wrong medium",
                topology(
                    with: Cable(
                        id: fixedID(2), assetCode: "FIBER", endpointA: firstPort, endpointB: secondPort, medium: .fiber, connector: .lc, kind: .fiberLink,
                        status: .installed), replacing: fixture.topology), .incompatibleEndpoints(fixedID(2))
            ),
            (
                "occupied port",
                topology(
                    appending: Cable(
                        id: fixedID(3), assetCode: "OCCUPIED", endpointA: firstPort, endpointB: secondPort, medium: .copper, connector: .rj45, kind: .patchCord,
                        status: .installed), to: fixture.topology), .duplicateCableOccupancy(fixedID(3))
            ),
        ]

        for (name, topology, expected) in cases {
            XCTAssertThrowsError(try DefaultTopologyEngine.validate(topology), name) { error in
                XCTAssertEqual(error as? TopologyValidationError, expected, name)
            }
        }
    }

    func testDerivedPortStateUsesAvailabilityThenInstalledOccupancyReservationAndPlan() throws {
        let fixture = NetworkModelTestData.passThroughTopology()
        var topology = fixture.topology
        XCTAssertEqual(topology.portState(for: fixture.startPortID), .occupied)

        let freePort = topology.ports.first { $0.id == fixture.startPortID }!
        topology.cables.removeAll { $0.endpointA == freePort.id || $0.endpointB == freePort.id }
        topology.reservations = [TopologyReservation(portIDs: [freePort.id])]
        XCTAssertEqual(topology.portState(for: freePort.id), .reserved)
        topology.reservations = []
        topology.plannedWork = [PlannedTopologyWork(portIDs: [freePort.id])]
        XCTAssertEqual(topology.portState(for: freePort.id), .planned)
        topology.ports[0].availability = .unavailable
        XCTAssertEqual(topology.portState(for: freePort.id), .unavailable)
    }

    func testDuplexFiberAndC13ToC14PowerTerminationsAreValid() throws {
        let typeID = fixedID(10)
        let fiberDeviceA = Device(id: fixedID(11), assetCode: "FIBER-A", name: "Fiber A", typeID: typeID)
        let fiberDeviceB = Device(id: fixedID(12), assetCode: "FIBER-B", name: "Fiber B", typeID: typeID)
        let powerDeviceA = Device(id: fixedID(13), assetCode: "POWER-A", name: "Power A", typeID: typeID)
        let powerDeviceB = Device(id: fixedID(14), assetCode: "POWER-B", name: "Power B", typeID: typeID)
        let fiberA = NetworkModel.Port(id: fixedID(15), deviceID: fiberDeviceA.id, label: "F1", medium: .fiber, connector: .lc, fiberMode: .duplex)
        let fiberB = NetworkModel.Port(id: fixedID(16), deviceID: fiberDeviceB.id, label: "F1", medium: .fiber, connector: .lc, fiberMode: .duplex)
        let powerA = NetworkModel.Port(id: fixedID(17), deviceID: powerDeviceA.id, label: "IN", medium: .power, connector: .c14)
        let powerB = NetworkModel.Port(id: fixedID(18), deviceID: powerDeviceB.id, label: "OUT", medium: .power, connector: .c13)
        let fiber = Cable(
            id: fixedID(19), assetCode: "FIBER-1", endpointA: fiberA.id, connectorA: .lc, endpointB: fiberB.id, connectorB: .lc, medium: .fiber,
            kind: .fiberLink, status: .installed)
        let power = Cable(
            id: fixedID(20), assetCode: "POWER-1", endpointA: powerA.id, connectorA: .c14, endpointB: powerB.id, connectorB: .c13, medium: .power,
            kind: .patchCord, status: .installed)
        let topology = PhysicalTopology(
            deviceTypes: [DeviceType(id: typeID, name: "Endpoint", kind: .generic)],
            devices: [fiberDeviceA, fiberDeviceB, powerDeviceA, powerDeviceB],
            ports: [fiberA, fiberB, powerA, powerB],
            cables: [fiber, power]
        )
        try DefaultTopologyEngine.validate(topology)
        XCTAssertEqual(topology.portState(for: fiberA.id), .occupied)
        XCTAssertEqual(topology.portState(for: powerA.id), .occupied)
    }

    func testCommandsValidateBeforeAfterAndAreIdempotent() throws {
        var topology = NetworkModelTestData.passThroughTopology().topology
        let removableDevice = topology.devices.first { $0.assetCode == "SW-1" }!
        let disconnect = TopologyCommand.disconnect(
            DisconnectTopologyCommand(operationID: ObjectID(UUID(uuidString: "30000000-0000-0000-0000-000000000001")!), cableID: topology.cables[0].id))
        XCTAssertTrue(try topology.apply(disconnect).didApply)
        XCTAssertFalse(try topology.apply(disconnect).didApply)
        XCTAssertEqual(topology.revision, 1)

        XCTAssertThrowsError(try topology.apply(.remove(RemoveTopologyCommand(deviceID: removableDevice.id))))
        let switchCableID = topology.cables.first { cable in
            topology.ports.contains { $0.deviceID == removableDevice.id && ($0.id == cable.endpointA || $0.id == cable.endpointB) }
        }!.id
        _ = try topology.apply(.disconnect(DisconnectTopologyCommand(cableID: switchCableID)))
        _ = try topology.apply(.remove(RemoveTopologyCommand(deviceID: removableDevice.id, deletedAt: .distantPast)))
        XCTAssertTrue(topology.tombstones.contains { $0.id == removableDevice.id && $0.kind == .device })
    }

    func testObjectIDsCannotBeReusedAcrossTopologyRecordKinds() throws {
        var topology = NetworkModelTestData.passThroughTopology().topology
        let deviceType = try XCTUnwrap(topology.deviceTypes.first)
        topology.devices[0].typeID = deviceType.id
        topology.devices[0] = Device(
            id: deviceType.id,
            assetCode: topology.devices[0].assetCode,
            name: topology.devices[0].name,
            typeID: deviceType.id
        )

        XCTAssertThrowsError(try DefaultTopologyEngine.validate(topology)) { error in
            XCTAssertEqual(error as? TopologyValidationError, .duplicateObjectID(deviceType.id))
        }
    }

    func testDeterministicGeneratedCommandSequencesAlwaysPreserveInvariants() throws {
        for index in 0..<24 {
            var topology = twoPortTopology(seed: index)
            let cable = Cable(
                id: ObjectID(UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", index + 1))!), assetCode: AssetCode("C-\(index)"),
                endpointA: topology.ports[0].id, endpointB: topology.ports[1].id, medium: .copper, connector: .rj45, kind: .patchCord, status: .planned)
            _ = try topology.apply(.connect(ConnectTopologyCommand(cable: cable)))
            try DefaultTopologyEngine.validate(topology)
            _ = try topology.apply(
                .move(MoveTopologyCommand(cableID: cable.id, endpointA: cable.endpointB, connectorA: .rj45, endpointB: cable.endpointA, connectorB: .rj45)))
            try DefaultTopologyEngine.validate(topology)
            _ = try topology.apply(.disconnect(DisconnectTopologyCommand(cableID: cable.id)))
            try DefaultTopologyEngine.validate(topology)
        }
    }

    private func topology(with cable: Cable, replacing fixture: PhysicalTopology) -> PhysicalTopology {
        var topology = fixture
        topology.cables = [cable]
        return topology
    }

    private func topology(appending cable: Cable, to fixture: PhysicalTopology) -> PhysicalTopology {
        var topology = fixture
        topology.cables.append(cable)
        return topology
    }

    private func fixedID(_ number: Int) -> ObjectID {
        ObjectID(UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", number))!)
    }

    private func twoPortTopology(seed: Int) -> PhysicalTopology {
        let deviceID = ObjectID(UUID(uuidString: String(format: "50000000-0000-0000-0000-%012d", seed + 1))!)
        let firstPort = ObjectID(UUID(uuidString: String(format: "51000000-0000-0000-0000-%012d", seed + 1))!)
        let secondPort = ObjectID(UUID(uuidString: String(format: "52000000-0000-0000-0000-%012d", seed + 1))!)
        let typeID = ObjectID(UUID(uuidString: "53000000-0000-0000-0000-000000000001")!)
        let device = Device(id: deviceID, assetCode: AssetCode("D-\(seed)"), name: "Device", typeID: typeID)
        return PhysicalTopology(
            deviceTypes: [DeviceType(id: typeID, name: "Endpoint", kind: .generic)], devices: [device],
            ports: [
                NetworkModel.Port(id: firstPort, deviceID: deviceID, label: "A", medium: .copper, connector: .rj45),
                NetworkModel.Port(id: secondPort, deviceID: deviceID, label: "B", medium: .copper, connector: .rj45),
            ])
    }
}
