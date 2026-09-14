import Foundation
import NetworkModel
import WorkspaceChangeControl

private struct InventoryLocationContext {
    let siteIDs: Set<ObjectID>
    let siteName: String?
    let containment: [String]
}

struct InventorySearchRecordBuilder {
    private let projection: InventorySearchIndexBuilder.Projection
    private let namespace: PersistenceNamespace
    private let locationsByID: [ObjectID: Location]
    private let locationIDsByObject: [ObjectID: Set<ObjectID>]
    private let tombstoned: Set<ObjectID>
    private let pendingWorkKeys: Set<ResourceKey>
    private let plannedPortIDs: Set<ObjectID>
    private let portStates: [ObjectID: PortState]

    init(projection: InventorySearchIndexBuilder.Projection, namespace: PersistenceNamespace) throws {
        self.projection = projection
        self.namespace = namespace
        locationsByID = Dictionary(projection.hierarchy.locations.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        locationIDsByObject = try Self.locationMappings(for: projection)
        tombstoned = Set(projection.topology.tombstones.map(\.id)).union(projection.hierarchy.tombstones.map(\.id))
        pendingWorkKeys = Set(
            projection.workOrders.filter(InventorySearchIndexBuilder.isPending).flatMap(InventorySearchIndexBuilder.canonicalAffectedResourceKeys(for:)))
        plannedPortIDs = Set(projection.topology.plannedWork.flatMap(\.portIDs))
        portStates = InventorySearchIndexBuilder.portStates(in: projection.topology, facts: projection.portStateFacts)
    }

    func build() throws -> [LocalInventorySearchRecord] {
        var records: [LocalInventorySearchRecord] = []
        records.reserveCapacity(expectedRecordCount)
        appendTopologyRecords(to: &records)
        appendIPAMRecords(to: &records)
        appendHierarchyRecords(to: &records)
        guard records.count <= InventorySearchIndexBuilder.maximumEntries else {
            throw PersistenceStoreError.inventorySearchIndexCapacityExceeded(records.count)
        }
        return records.sorted(by: Self.recordOrder)
    }

    private var expectedRecordCount: Int {
        projection.topology.devices.count
            + projection.topology.ports.count
            + projection.topology.cables.count
            + projection.hierarchy.locations.count
            + projection.hierarchy.racks.count
            + projection.addresses.count
            + projection.interfaces.count
    }

    private func appendTopologyRecords(to records: inout [LocalInventorySearchRecord]) {
        for device in projection.topology.devices where !tombstoned.contains(device.id) {
            records.append(
                makeRecord(
                    device.id, resourceKey: .object(device.id), kind: "device", title: device.name, subtitle: device.assetCode.value,
                    searchTerms: InventorySearchIndexBuilder.customFields(device.customFields) + [device.typeID.description],
                    isPending: pendingWorkKeys.contains(.object(device.id))))
        }
        for port in projection.topology.ports where !tombstoned.contains(port.id) {
            let pending = plannedPortIDs.contains(port.id) || pendingWorkKeys.contains(.object(port.id))
            records.append(
                makeRecord(
                    port.id, resourceKey: .object(port.id), kind: "port", title: port.label, subtitle: portStates[port.id, default: .unavailable].rawValue,
                    searchTerms: InventorySearchIndexBuilder.customFields(port.customFields) + [
                        port.deviceID.description, port.medium.rawValue, port.connector.rawValue, port.face.rawValue,
                    ], isPending: pending))
        }
        for cable in projection.topology.cables where !tombstoned.contains(cable.id) {
            let pending = cable.status == .planned || pendingWorkKeys.contains(.object(cable.id))
            records.append(
                makeRecord(
                    cable.id, resourceKey: .object(cable.id), kind: "cable", title: cable.assetCode.value, subtitle: cable.status.rawValue,
                    searchTerms: [
                        cable.endpointA.description,
                        cable.endpointB.description, cable.medium.rawValue, cable.connectorA.rawValue, cable.connectorB.rawValue, cable.kind.rawValue,
                        cable.color ?? "",
                    ], isPending: pending))
        }
    }

    private func appendIPAMRecords(to records: inout [LocalInventorySearchRecord]) {
        appendAddressRecords(to: &records)
        appendInterfaceRecords(to: &records)
    }

    private func appendAddressRecords(to records: inout [LocalInventorySearchRecord]) {
        for address in projection.addresses where address.isActive {
            let objectID = InventorySearchIndexBuilder.stableObjectID(address.id)
            records.append(
                makeRecord(
                    objectID, resourceKey: .string(address.id), kind: "address", title: address.address.description, subtitle: address.vrfID.description,
                    searchTerms: [
                        address.id,
                        address.assignedInterfaceID?.description ?? "",
                    ], isPending: pendingWorkKeys.contains(.string(address.id))))
        }
    }

    private func appendInterfaceRecords(to records: inout [LocalInventorySearchRecord]) {
        for interface in projection.interfaces where interface.isActive {
            records.append(
                makeRecord(
                    interface.id, resourceKey: .object(interface.id), kind: "interface", title: interface.name, subtitle: interface.mode.rawValue,
                    searchTerms: [
                        interface.deviceID.description,
                        interface.physicalPortID?.description ?? "", interface.kind.rawValue, interface.vlanID?.description ?? "",
                    ], isPending: pendingWorkKeys.contains(.object(interface.id))))
        }
    }

    private func appendHierarchyRecords(to records: inout [LocalInventorySearchRecord]) {
        for rack in projection.hierarchy.racks where rack.deletedAt == nil && !tombstoned.contains(rack.id) {
            records.append(
                makeRecord(
                    rack.id, resourceKey: .object(rack.id), kind: "rack", title: rack.assetCode.value, subtitle: "\(rack.heightRU) RU",
                    searchTerms: [rack.locationID.description],
                    isPending: pendingWorkKeys.contains(.object(rack.id))))
        }
        for location in projection.hierarchy.locations where location.deletedAt == nil && !tombstoned.contains(location.id) {
            let kind = location.kind == .room ? "room" : "site"
            records.append(
                makeRecord(
                    location.id, resourceKey: .object(location.id), kind: kind, title: location.name, subtitle: location.kind.rawValue, searchTerms: [],
                    isPending: pendingWorkKeys.contains(.object(location.id))))
        }
    }

    private func makeRecord(
        _ objectID: ObjectID, resourceKey: ResourceKey, kind: String, title: String,
        subtitle: String, searchTerms: [String], isPending: Bool
    ) -> LocalInventorySearchRecord {
        let value = locationContext(for: objectID)
        return LocalInventorySearchRecord(
            namespace: namespace, objectID: objectID, resourceKey: resourceKey, kind: kind, title: title, subtitle: subtitle, siteName: value.siteName,
            siteIDs: value.siteIDs,
            searchTerms: value.containment + searchTerms, isPending: isPending)
    }

    private func locationContext(for objectID: ObjectID) -> InventoryLocationContext {
        let paths = (locationIDsByObject[objectID] ?? []).sorted().map(locationPath)
        let containment = uniqueNames(paths.flatMap { $0.reversed().map(\.name) })
        let sites = paths.compactMap { $0.first(where: { $0.kind == .site }) }
        let siteNames = uniqueNames(sites.map(\.name))
        return InventoryLocationContext(
            siteIDs: Set(sites.map(\.id)), siteName: siteNames.isEmpty ? nil : siteNames.joined(separator: " / "), containment: containment)
    }

    private func locationPath(startingAt startID: ObjectID) -> [Location] {
        var path: [Location] = []
        var cursor: ObjectID? = startID
        var visited = Set<ObjectID>()
        while let locationID = cursor, visited.insert(locationID).inserted,
            let location = locationsByID[locationID],
            path.count < InventorySearchIndexBuilder.maximumContainmentDepth
        {
            path.append(location)
            cursor = location.parentID
        }
        return path
    }

    private func uniqueNames(_ names: [String]) -> [String] {
        names.reduce(into: []) { values, name in
            if !values.contains(name) { values.append(name) }
        }
    }

    private static func locationMappings(
        for projection: InventorySearchIndexBuilder.Projection
    ) throws -> [ObjectID: Set<ObjectID>] {
        var result: [ObjectID: Set<ObjectID>] = [:]
        appendHierarchyMappings(projection, to: &result)
        try appendDeviceMappings(projection, to: &result)
        appendTopologyMappings(projection, to: &result)
        appendIPAMMappings(projection, to: &result)
        return result
    }

    private static func appendHierarchyMappings(
        _ projection: InventorySearchIndexBuilder.Projection,
        to result: inout [ObjectID: Set<ObjectID>]
    ) {
        for location in projection.hierarchy.locations where location.deletedAt == nil {
            result[location.id] = [location.id]
        }
        for rack in projection.hierarchy.racks where rack.deletedAt == nil {
            result[rack.id] = [rack.locationID]
        }
    }

    private static func appendDeviceMappings(
        _ projection: InventorySearchIndexBuilder.Projection,
        to result: inout [ObjectID: Set<ObjectID>]
    ) throws {
        let racks = Dictionary(projection.hierarchy.racks.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let placements = Dictionary(projection.placements.map { ($0.deviceID, $0) }, uniquingKeysWith: { current, _ in current })
        for device in projection.topology.devices {
            let placementRackID = placements[device.id]?.rackID
            if let legacyRackID = device.rackID, let placementRackID, legacyRackID != placementRackID {
                throw PersistenceStoreError.invalidMirrorRecord(.object(device.id))
            }
            if let rackID = placementRackID ?? device.rackID, let rack = racks[rackID], rack.deletedAt == nil {
                result[device.id] = [rack.locationID]
            }
        }
    }

    private static func appendTopologyMappings(
        _ projection: InventorySearchIndexBuilder.Projection,
        to result: inout [ObjectID: Set<ObjectID>]
    ) {
        for port in projection.topology.ports {
            if let locations = result[port.deviceID] { result[port.id] = locations }
        }
        for cable in projection.topology.cables {
            result[cable.id] = (result[cable.endpointA] ?? []).union(result[cable.endpointB] ?? [])
        }
        for interface in projection.interfaces where interface.isActive {
            if let portID = interface.physicalPortID, let locations = result[portID] {
                result[interface.id] = locations
            } else if let locations = result[interface.deviceID] {
                result[interface.id] = locations
            }
        }
    }

    private static func appendIPAMMappings(
        _ projection: InventorySearchIndexBuilder.Projection,
        to result: inout [ObjectID: Set<ObjectID>]
    ) {
        let interfaces = Set(projection.interfaces.map(\.id))
        for address in projection.addresses where address.isActive {
            guard let interfaceID = address.assignedInterfaceID, interfaces.contains(interfaceID),
                let locations = result[interfaceID]
            else { continue }
            result[InventorySearchIndexBuilder.stableObjectID(address.id)] = locations
        }
    }

    private static func recordOrder(_ lhs: LocalInventorySearchRecord, _ rhs: LocalInventorySearchRecord) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.objectID < rhs.objectID
    }
}
