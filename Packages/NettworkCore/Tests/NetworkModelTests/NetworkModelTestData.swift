import Foundation

@testable import NetworkModel

enum NetworkModelTestData {
    static func passThroughTopology() -> (topology: PhysicalTopology, startPortID: ObjectID, endPortID: ObjectID) {
        let workstation = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let outletFront = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let outletRear = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let panelRear = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let panelFront = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        let switchPort = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000006")!)
        let workstationDevice = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let outletDevice = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let panelDevice = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
        let switchDevice = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000013")!)
        let activeType = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000020")!)
        let passiveType = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
        let types = [
            DeviceType(id: activeType, name: "Active endpoint", kind: .switchDevice),
            DeviceType(id: passiveType, name: "Pass-through", kind: .passive),
        ]
        let devices = [
            Device(id: workstationDevice, assetCode: "WS-1", name: "Workstation", typeID: activeType),
            Device(id: outletDevice, assetCode: "OUTLET-1", name: "Outlet", typeID: passiveType),
            Device(id: panelDevice, assetCode: "PANEL-1", name: "Panel", typeID: passiveType),
            Device(id: switchDevice, assetCode: "SW-1", name: "Switch", typeID: activeType),
        ]
        let ports = [
            Port(id: workstation, deviceID: workstationDevice, label: "NIC", medium: .copper, connector: .rj45),
            Port(id: outletFront, deviceID: outletDevice, label: "F", medium: .copper, connector: .rj45, face: .front),
            Port(id: outletRear, deviceID: outletDevice, label: "R", medium: .copper, connector: .rj45, face: .rear),
            Port(id: panelRear, deviceID: panelDevice, label: "R", medium: .copper, connector: .rj45, face: .rear),
            Port(id: panelFront, deviceID: panelDevice, label: "F", medium: .copper, connector: .rj45, face: .front),
            Port(id: switchPort, deviceID: switchDevice, label: "Gi1/0/1", medium: .copper, connector: .rj45),
        ]
        let cables = [
            Cable(
                id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000101")!), assetCode: "FIXED-1", endpointA: workstation, endpointB: outletFront,
                medium: .copper, connector: .rj45, kind: .fixed, status: .installed),
            Cable(
                id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000102")!), assetCode: "FIXED-2", endpointA: outletRear, endpointB: panelRear,
                medium: .copper, connector: .rj45, kind: .fixed, status: .installed),
            Cable(
                id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000103")!), assetCode: "PATCH-1", endpointA: panelFront, endpointB: switchPort,
                medium: .copper, connector: .rj45, kind: .patchCord, status: .installed),
        ]
        let links = [
            InternalLink(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000201")!), endpointA: outletFront, endpointB: outletRear),
            InternalLink(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000202")!), endpointA: panelRear, endpointB: panelFront),
        ]
        return (PhysicalTopology(deviceTypes: types, devices: devices, ports: ports, cables: cables, internalLinks: links), workstation, switchPort)
    }

    /// Adds room, rack, address, and VLAN context to the physical route.
    static func richPassThroughTrace() -> (topology: PhysicalTopology, startPortID: ObjectID, endPortID: ObjectID, enrichment: TraceEnrichment) {
        var fixture = passThroughTopology()
        let workspace = Location(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000301")!), name: "Example", kind: .workspace)
        let site = Location(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000302")!), name: "Main", kind: .site, parentID: workspace.id)
        let building = Location(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000303")!), name: "A", kind: .building, parentID: site.id)
        let floor = Location(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000304")!), name: "1", kind: .floor, parentID: building.id)
        let room = Location(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000305")!), name: "101", kind: .room, parentID: floor.id)
        let rack = Rack(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000306")!), assetCode: "RACK-101-A", locationID: room.id, heightRU: 42)
        if let deviceIndex = fixture.topology.devices.firstIndex(where: {
            $0.id == fixture.topology.ports.first(where: { $0.id == fixture.endPortID })?.deviceID
        }) {
            fixture.topology.devices[deviceIndex].rackID = rack.id
        }
        let interfaceID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000307")!)
        let vlanGroup = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000308")!)
        let vlan = VLAN(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000309")!), groupID: vlanGroup, number: 120, name: "Users")
        let interface = Interface(
            id: interfaceID, deviceID: fixture.topology.ports.first(where: { $0.id == fixture.endPortID })!.deviceID, physicalPortID: fixture.endPortID,
            name: "GigabitEthernet1/0/1", mode: .access)
        let address = IPAddressRecord(
            vrfID: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000310")!), address: IPAddress(parsing: "192.0.2.10")!,
            assignedInterfaceID: interfaceID)
        let assignment = IPAddressAssignment(
            id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000311")!), addressID: address.id, interfaceID: interfaceID, isPrimary: true)
        let membership = InterfaceVLANMembership(
            id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000312")!), interfaceID: interfaceID, vlanID: vlan.id, isNative: true)
        let enrichment = TraceEnrichment(
            revision: 1, hierarchy: WorkspaceHierarchy(locations: [workspace, site, building, floor, room], racks: [rack]), interfaces: [interface],
            addresses: [address],
            addressAssignments: [assignment], vlans: [vlan], vlanMemberships: [membership])
        return (fixture.topology, fixture.startPortID, fixture.endPortID, enrichment)
    }

    static func duplexFiberTopology() -> (topology: PhysicalTopology, startPortID: ObjectID, endPortID: ObjectID) {
        let leftDevice = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000401")!)
        let rightDevice = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000402")!)
        let deviceType = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000403")!)
        let leftPort = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000404")!)
        let rightPort = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000405")!)
        let cable = Cable(
            id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000406")!), assetCode: "FIBER-1", endpointA: leftPort, endpointB: rightPort,
            medium: .fiber, connector: .lc, kind: .fiberLink, status: .installed)
        let topology = PhysicalTopology(
            deviceTypes: [DeviceType(id: deviceType, name: "Optical switch", kind: .switchDevice)],
            devices: [
                Device(id: leftDevice, assetCode: "SW-A", name: "A", typeID: deviceType),
                Device(id: rightDevice, assetCode: "SW-B", name: "B", typeID: deviceType),
            ],
            ports: [
                Port(id: leftPort, deviceID: leftDevice, label: "Te1/1", medium: .fiber, connector: .lc),
                Port(
                    id: rightPort,
                    deviceID: rightDevice, label: "Te1/1", medium: .fiber, connector: .lc),
            ], cables: [cable])
        return (topology, leftPort, rightPort)
    }
}

struct IdentityHierarchyTestData: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var hierarchy: WorkspaceHierarchy

    init(schemaVersion: Int = currentSchemaVersion, hierarchy: WorkspaceHierarchy) {
        self.schemaVersion = schemaVersion
        self.hierarchy = hierarchy
    }

    static func canonical() -> Self {
        let workspace = Location(id: fixedID(1), name: "Example", kind: .workspace)
        let site = Location(id: fixedID(2), name: "Main", kind: .site, parentID: workspace.id)
        let building = Location(id: fixedID(3), name: "A", kind: .building, parentID: site.id)
        let floor = Location(id: fixedID(4), name: "1", kind: .floor, parentID: building.id)
        let room = Location(id: fixedID(5), name: "101", kind: .room, parentID: floor.id)
        let rack = Rack(id: fixedID(6), assetCode: "RACK-101-A", locationID: room.id, heightRU: 42)
        let tombstone = HierarchyTombstone(
            id: fixedID(7),
            kind: .rack,
            deletedAt: Date(timeIntervalSince1970: 0)
        )
        return Self(
            hierarchy: WorkspaceHierarchy(
                locations: [workspace, site, building, floor, room],
                racks: [rack],
                tombstones: [tombstone]
            )
        )
    }

    func deterministicJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decodeDeterministicJSON(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }

    private static func fixedID(_ suffix: Int) -> ObjectID {
        ObjectID(UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", suffix))!)
    }
}
