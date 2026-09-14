import Foundation
import NetworkModel
import WorkspaceChangeControl

extension MirrorProjection {
    struct ContainmentIndexes {
        let paths: [ObjectID: [String]]
        let siteIDs: [ObjectID: Set<ObjectID>]
        let siteNames: [ObjectID: String]
    }

    static func portStates(for topology: PhysicalTopology) -> [ObjectID: PortState] {
        var endpointStatuses: [ObjectID: (hasCable: Bool, installed: Bool)] = [:]
        for cable in topology.cables {
            for endpoint in [cable.endpointA, cable.endpointB] {
                let current = endpointStatuses[endpoint] ?? (false, false)
                endpointStatuses[endpoint] = (true, current.installed || cable.status == .installed)
            }
        }
        let reservedPorts = Set(topology.reservations.flatMap(\.portIDs))
        let plannedPorts = Set(topology.plannedWork.flatMap(\.portIDs))
        return Dictionary(
            uniqueKeysWithValues: topology.ports.map { port in
                (
                    port.id,
                    Self.portState(
                        for: port,
                        endpointStatus: endpointStatuses[port.id],
                        reservedPorts: reservedPorts,
                        plannedPorts: plannedPorts
                    )
                )
            })
    }

    private static func portState(
        for port: NetworkModel.Port,
        endpointStatus: (hasCable: Bool, installed: Bool)?,
        reservedPorts: Set<ObjectID>,
        plannedPorts: Set<ObjectID>
    ) -> PortState {
        if port.availability == .unavailable { return .unavailable }
        if let endpointStatus, endpointStatus.hasCable {
            return endpointStatus.installed ? .occupied : .planned
        }
        if reservedPorts.contains(port.id) { return .reserved }
        if plannedPorts.contains(port.id) { return .planned }
        return .free
    }

    static func locationIDsByObject(
        topology: PhysicalTopology, hierarchy: WorkspaceHierarchy, placements: [RackPlacement], addresses: [IPAddressRecord], interfaces: [Interface]
    ) throws -> [ObjectID: Set<ObjectID>] {
        let racks = Dictionary(hierarchy.racks.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let placementByDeviceID = Dictionary(placements.map { ($0.deviceID, $0) }, uniquingKeysWith: { current, _ in current })
        var result = hierarchyLocationIDs(hierarchy)
        try addDeviceLocationIDs(topology.devices, racks: racks, placementByDeviceID: placementByDeviceID, to: &result)
        addTopologyLocationIDs(topology, to: &result)
        addIPAMLocationIDs(addresses: addresses, interfaces: interfaces, to: &result)
        return result
    }

    private static func hierarchyLocationIDs(_ hierarchy: WorkspaceHierarchy) -> [ObjectID: Set<ObjectID>] {
        var result: [ObjectID: Set<ObjectID>] = [:]
        for location in hierarchy.locations { result[location.id] = [location.id] }
        for rack in hierarchy.racks { result[rack.id] = [rack.locationID] }
        return result
    }

    private static func addDeviceLocationIDs(
        _ devices: [Device], racks: [ObjectID: Rack], placementByDeviceID: [ObjectID: RackPlacement], to result: inout [ObjectID: Set<ObjectID>]
    ) throws {
        for device in devices {
            let placementRackID = placementByDeviceID[device.id]?.rackID
            if let legacyRackID = device.rackID,
                let placementRackID,
                legacyRackID != placementRackID
            {
                throw ProductionAdapterError.malformedAuthoritativeMirrorRecord(
                    .object(device.id),
                    "rack-placement"
                )
            }
            if let rackID = placementRackID ?? device.rackID,
                let rack = racks[rackID]
            {
                result[device.id] = [rack.locationID]
            }
        }
    }

    private static func addTopologyLocationIDs(_ topology: PhysicalTopology, to result: inout [ObjectID: Set<ObjectID>]) {
        for port in topology.ports {
            if let locationIDs = result[port.deviceID] { result[port.id] = locationIDs }
        }
        for cable in topology.cables {
            for endpoint in [cable.endpointA, cable.endpointB] {
                result[cable.id, default: []].formUnion(result[endpoint] ?? [])
            }
        }
    }

    private static func addIPAMLocationIDs(addresses: [IPAddressRecord], interfaces: [Interface], to result: inout [ObjectID: Set<ObjectID>]) {
        let interfacesByID = Dictionary(interfaces.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        for interface in interfaces {
            let sourceID = interface.physicalPortID ?? interface.deviceID
            if let locationIDs = result[sourceID] { result[interface.id] = locationIDs }
        }
        for address in addresses {
            guard let interfaceID = address.assignedInterfaceID,
                interfacesByID[interfaceID] != nil,
                let locationIDs = result[interfaceID]
            else { continue }
            result[SwiftDataFeatureReadAdapter.stableObjectID(address.id)] = locationIDs
        }
    }

    static func containmentIndexes(locationIDsByObject: [ObjectID: Set<ObjectID>], locations: [Location]) -> ContainmentIndexes {
        let locationsByID = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        var paths: [ObjectID: [String]] = [:]
        var siteIDs: [ObjectID: Set<ObjectID>] = [:]
        var siteNames: [ObjectID: String] = [:]
        for (objectID, startLocationIDs) in locationIDsByObject {
            let objectPaths = startLocationIDs.sorted().map { locationPath(from: $0, locations: locationsByID) }
            paths[objectID] = uniqueNames(in: objectPaths)
            let sites = objectPaths.compactMap { $0.first(where: { $0.kind == .site }) }
            if !sites.isEmpty {
                siteIDs[objectID] = Set(sites.map(\.id))
                siteNames[objectID] = uniqueValues(sites.map(\.name)).joined(separator: " / ")
            }
        }
        return ContainmentIndexes(paths: paths, siteIDs: siteIDs, siteNames: siteNames)
    }

    private static func locationPath(from startLocationID: ObjectID, locations: [ObjectID: Location]) -> [Location] {
        var path: [Location] = []
        var cursor: ObjectID? = startLocationID
        var visited = Set<ObjectID>()
        while let locationID = cursor,
            visited.insert(locationID).inserted,
            let location = locations[locationID],
            path.count < 16
        {
            path.append(location)
            cursor = location.parentID
        }
        return path
    }

    private static func uniqueNames(in paths: [[Location]]) -> [String] {
        uniqueValues(paths.flatMap { $0.reversed().map(\.name) })
    }

    private static func uniqueValues(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    static func workflowKeys(_ workOrders: [WorkOrder]) -> (planned: Set<ResourceKey>, pending: Set<ResourceKey>) {
        var planned = Set<ResourceKey>()
        var pending = Set<ResourceKey>()
        for order in workOrders {
            if order.status == .draft { planned.formUnion(order.productionResourceKeys) }
            if SwiftDataFeatureReadAdapter.isPending(order.status) {
                pending.formUnion(order.productionResourceKeys)
            }
        }
        return (planned, pending)
    }
}
