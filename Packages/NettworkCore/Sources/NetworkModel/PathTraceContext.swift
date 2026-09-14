import Foundation

struct RichGraphEdge: Sendable {
    let segment: TraceSegment
    let cable: Cable?
    let isTombstoned: Bool
}
struct RichWalkState {
    let limits: TraceTraversalLimits
    var emittedPathCount = 0
    var didReachPathLimit = false
}

struct TraceContextResolver {
    private let ports: [ObjectID: Port]
    private let devices: [ObjectID: Device]
    private let deviceTypes: [ObjectID: DeviceType]
    private let tombstonedPorts: Set<ObjectID>
    private let tombstonedDevices: Set<ObjectID>
    private let hierarchy: WorkspaceHierarchy?
    private let interfaces: [Interface]
    private let addresses: [IPAddressRecord]
    private let assignments: [IPAddressAssignment]
    private let vlans: [ObjectID: VLAN]
    private let memberships: [InterfaceVLANMembership]

    init(topology: PhysicalTopology, enrichment: TraceEnrichment) {
        ports = Dictionary(topology.ports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        devices = Dictionary(topology.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        deviceTypes = Dictionary(topology.deviceTypes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tombstonedPorts = Set(topology.tombstones.filter { $0.kind == .port }.map(\.id))
        tombstonedDevices = Set(topology.tombstones.filter { $0.kind == .device }.map(\.id))
        hierarchy = enrichment.hierarchy
        interfaces = enrichment.interfaces
        addresses = enrichment.addresses
        assignments = enrichment.addressAssignments
        vlans = Dictionary(enrichment.vlans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        memberships = enrichment.vlanMemberships
    }

    func hasPort(_ id: ObjectID) -> Bool { ports[id] != nil }
    func isTombstonedPort(_ id: ObjectID) -> Bool { tombstonedPorts.contains(id) }
    func isPassivePort(_ id: ObjectID) -> Bool {
        guard let port = ports[id], let device = devices[port.deviceID], let kind = deviceTypes[device.typeID]?.kind else { return false }
        return [.patchPanel, .fiberPanel, .wallOutlet, .passive].contains(kind)
    }

    func node(for id: ObjectID) -> RichTraceNode? {
        guard let port = ports[id] else { return nil }
        let device = devices[port.deviceID]
        var warnings = [TraceWarning]()
        if port.availability == .unavailable { warnings.append(.unavailablePort(id)) }
        if tombstonedPorts.contains(id) { warnings.append(.tombstonedResource(.port(id))) }
        if tombstonedDevices.contains(port.deviceID) { warnings.append(.tombstonedResource(.device(port.deviceID))) }
        let rack = device.flatMap { rackContext(for: $0, warnings: &warnings) }
        let logical = logicalInterfaces(for: id, warnings: &warnings)
        return RichTraceNode(
            id: port.id, portLabel: port.label, portFace: port.face, medium: port.medium, connector: port.connector, fiberMode: port.fiberMode,
            device: device.map(TraceDeviceContext.init), rack: rack,
            interfaces: logical, warnings: warnings.sorted { $0.sortKey < $1.sortKey })
    }

    private func rackContext(for device: Device, warnings: inout [TraceWarning]) -> TraceRackContext? {
        guard let rackID = device.rackID, let hierarchy else { return nil }
        guard let rack = hierarchy.racks.first(where: { $0.id == rackID }) else {
            if hierarchy.tombstones.contains(where: { $0.id == rackID && $0.kind == .rack }) { warnings.append(.tombstonedResource(.rack(rackID))) }
            return nil
        }
        if rack.deletedAt != nil { warnings.append(.tombstonedResource(.rack(rack.id))) }
        let locationsByID = Dictionary(hierarchy.locations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var path = [TraceLocationContext]()
        var currentID: ObjectID? = rack.locationID
        var visited = Set<ObjectID>()
        while let id = currentID, visited.insert(id).inserted, let location = locationsByID[id] {
            if location.deletedAt != nil { warnings.append(.tombstonedResource(.location(location.id))) }
            path.append(TraceLocationContext(location: location))
            currentID = location.parentID
        }
        return TraceRackContext(rack: rack, locationPath: Array(path.reversed()))
    }

    private func logicalInterfaces(for portID: ObjectID, warnings: inout [TraceWarning]) -> [TraceLogicalInterfaceContext] {
        let matching = interfaces.filter { $0.physicalPortID == portID }.sorted { $0.id < $1.id }
        for interface in matching where !interface.isActive { warnings.append(.tombstonedLogicalInterface(interface.id)) }
        return matching.filter(\.isActive).map { logicalInterfaceContext(for: $0, warnings: &warnings) }
    }

    private func logicalInterfaceContext(for interface: Interface, warnings: inout [TraceWarning]) -> TraceLogicalInterfaceContext {
        let interfaceAddresses = addresses(for: interface, warnings: &warnings)
        let vlanContexts = vlanContexts(for: interface, warnings: &warnings)
        return TraceLogicalInterfaceContext(
            interface: interface, addresses: interfaceAddresses.filter(\.isActive).map { $0.address.description }, vlans: vlanContexts)
    }

    private func addresses(for interface: Interface, warnings: inout [TraceWarning]) -> [IPAddressRecord] {
        let assignmentIDs = Set(assignments.filter { $0.interfaceID == interface.id && $0.isActive }.map(\.addressID))
        let result = addresses.filter { $0.assignedInterfaceID == interface.id || assignmentIDs.contains($0.id) }.sorted { $0.id < $1.id }
        for address in result where !address.isActive { warnings.append(.tombstonedIPAddress(address.id)) }
        return result
    }

    private func vlanContexts(for interface: Interface, warnings: inout [TraceWarning]) -> [TraceVLANContext] {
        let active = memberships.filter { $0.interfaceID == interface.id && $0.isActive }
        for membership in memberships where membership.interfaceID == interface.id && !membership.isActive {
            warnings.append(.tombstonedVLAN(membership.vlanID))
        }
        var pairs = active.compactMap { vlanPair(for: $0, warnings: &warnings) }
        if let vlanID = interface.vlanID, let vlan = vlans[vlanID], vlan.isActive { pairs.append((vlan, interface.mode == .access)) }
        return uniqueVLANContexts(pairs)
    }

    private func vlanPair(for membership: InterfaceVLANMembership, warnings: inout [TraceWarning]) -> (VLAN, Bool)? {
        guard let vlan = vlans[membership.vlanID] else { return nil }
        guard vlan.isActive else {
            warnings.append(.tombstonedVLAN(vlan.id))
            return nil
        }
        return (vlan, membership.isNative)
    }

    private func uniqueVLANContexts(_ pairs: [(VLAN, Bool)]) -> [TraceVLANContext] {
        let unique = Dictionary(pairs.map { ($0.0.id, $0) }, uniquingKeysWith: { $0.1 ? $0 : $1 }).values
        return unique.map { TraceVLANContext(vlan: $0.0, isNative: $0.1) }.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
    }
}
