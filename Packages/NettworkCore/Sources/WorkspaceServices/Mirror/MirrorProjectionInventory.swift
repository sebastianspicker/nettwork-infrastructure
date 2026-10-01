import CloudSync
import ContentSafety
import CryptoKit
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension MirrorProjection {
    func workflowFlags(for resourceKey: ResourceKey) -> IPAMWorkflowFlags {
        return IPAMWorkflowFlags(
            isPlanned: plannedResourceKeys.contains(resourceKey),
            isPending: pendingResourceKeys.contains(resourceKey),
            isConflicted: conflictResourceKeys.contains(resourceKey)
        )
    }

    var inventoryResults: [InventorySearchResult] {
        let tombstoned = Set(topology.tombstones.map(\.id)).union(hierarchy.tombstones.map(\.id))
        let pendingIDs = Set(topology.plannedWork.flatMap { $0.portIDs }).union(topology.reservations.flatMap { $0.portIDs })
        let deviceRows = topology.devices.map { device in
            let context = containment(for: device.id)
            return InventorySearchResult(
                id: device.id,
                kind: .device,
                title: device.name,
                subtitle: device.assetCode.value,
                siteName: siteName(for: device.id),
                searchTerms: customFieldSearchTerms(device.customFields) + context + [device.typeID.description],
                isTombstoned: tombstoned.contains(device.id),
                isPending: hasPendingWork(for: .object(device.id)),
                isConflicted: hasConflict(for: .object(device.id))
            )
        }
        let portRows = topology.ports.map { port in
            let context = containment(for: port.id)
            return InventorySearchResult(
                id: port.id,
                kind: .port,
                title: port.label,
                subtitle: portStates[port.id]?.rawValue ?? "unavailable",
                siteName: siteName(for: port.id),
                searchTerms: customFieldSearchTerms(port.customFields) + context + [
                    port.deviceID.description, port.medium.rawValue,
                    port.connector.rawValue, port.face.rawValue,
                ],
                isTombstoned: tombstoned.contains(port.id),
                isPending: pendingIDs.contains(port.id) || hasPendingWork(for: .object(port.id)),
                isConflicted: hasConflict(for: .object(port.id))
            )
        }
        let cableRows = topology.cables.map { cable in
            let context = containment(for: cable.id)
            return InventorySearchResult(
                id: cable.id,
                kind: .cable,
                title: cable.assetCode.value,
                subtitle: cable.status.rawValue,
                siteName: siteName(for: cable.id),
                searchTerms: context + [
                    cable.endpointA.description, cable.endpointB.description, cable.medium.rawValue,
                    cable.connectorA.rawValue, cable.connectorB.rawValue, cable.kind.rawValue, cable.color ?? "",
                ],
                isTombstoned: tombstoned.contains(cable.id),
                isPending: cable.status == .planned || hasPendingWork(for: .object(cable.id)),
                isConflicted: hasConflict(for: .object(cable.id))
            )
        }
        let addressRows = addresses.map { address in
            let displayID = SwiftDataFeatureReadAdapter.stableObjectID(address.id)
            return InventorySearchResult(
                id: displayID,
                kind: .address,
                title: address.address.description,
                subtitle: address.vrfID.description,
                siteName: siteName(for: displayID),
                searchTerms: containment(for: displayID) + [address.id, address.assignedInterfaceID?.description ?? ""],
                isTombstoned: !address.isActive,
                isPending: hasPendingWork(for: .string(address.id)),
                isConflicted: hasConflict(for: .string(address.id))
            )
        }
        let interfaceRows = interfaces.map { interface in
            InventorySearchResult(
                id: interface.id,
                kind: .interface,
                title: interface.name,
                subtitle: interface.mode.rawValue,
                siteName: siteName(for: interface.id),
                searchTerms: containment(for: interface.id) + [
                    interface.deviceID.description,
                    interface.physicalPortID?.description ?? "", interface.kind.rawValue, interface.vlanID?.description ?? "",
                ],
                isTombstoned: !interface.isActive,
                isPending: hasPendingWork(for: .object(interface.id)),
                isConflicted: hasConflict(for: .object(interface.id))
            )
        }
        let rackRows = hierarchy.racks.map { rack in
            InventorySearchResult(
                id: rack.id,
                kind: .rack,
                title: rack.assetCode.value,
                subtitle: "\(rack.heightRU) RU",
                siteName: siteName(for: rack.id),
                searchTerms: containment(for: rack.id) + [rack.locationID.description],
                isTombstoned: rack.deletedAt != nil || tombstoned.contains(rack.id),
                isPending: hasPendingWork(for: .object(rack.id)),
                isConflicted: hasConflict(for: .object(rack.id))
            )
        }
        let locationRows = hierarchy.locations.map { location in
            InventorySearchResult(
                id: location.id,
                kind: SwiftDataFeatureReadAdapter.inventoryKind(location.kind),
                title: location.name,
                subtitle: location.kind.rawValue,
                siteName: siteName(for: location.id),
                searchTerms: containment(for: location.id),
                isTombstoned: location.deletedAt != nil || tombstoned.contains(location.id),
                isPending: hasPendingWork(for: .object(location.id)),
                isConflicted: hasConflict(for: .object(location.id))
            )
        }
        return deviceRows + portRows + cableRows + addressRows + interfaceRows + rackRows + locationRows
    }

    func siteIDs(for id: ObjectID) -> Set<ObjectID> {
        siteIDIndex[id] ?? []
    }

    func portState(for id: ObjectID) -> PortState { portStates[id] ?? .unavailable }

    func siteName(for id: ObjectID) -> String? {
        siteNameIndex[id]
    }

    func containment(for id: ObjectID) -> [String] {
        containmentIndex[id] ?? []
    }

    func connectivitySummary(for id: ObjectID) -> String {
        if topology.ports.contains(where: { $0.id == id }) { return portStates[id]?.rawValue ?? "Unavailable" }
        if let cable = topology.cables.first(where: { $0.id == id }) {
            return "\(cable.status.rawValue) cable between \(cable.endpointA.description) and \(cable.endpointB.description)"
        }
        if let device = topology.devices.first(where: { $0.id == id }) {
            let devicePortIDs = Set(topology.ports.filter { $0.deviceID == device.id }.map(\.id))
            let connected = topology.cables.filter { devicePortIDs.contains($0.endpointA) || devicePortIDs.contains($0.endpointB) }.count
            return "\(devicePortIDs.count) port(s), \(connected) connected cable(s)"
        }
        return "No physical connectivity record"
    }

    func traceSummary(for id: ObjectID) -> String {
        let startPort: ObjectID?
        if topology.ports.contains(where: { $0.id == id }) {
            startPort = id
        } else if let cable = topology.cables.first(where: { $0.id == id }) {
            startPort = cable.endpointA
        } else if let interface = interfaces.first(where: { $0.id == id }) {
            startPort = interface.physicalPortID
        } else {
            startPort = topology.ports.first(where: { $0.deviceID == id })?.id
        }
        guard let startPort,
            let summary = try? DefaultPathTraceService.summarize(from: startPort, in: topology)
        else {
            return "No physical trace starts from this object."
        }
        return Self.inventoryTraceDescription(summary)
    }

    static func inventoryTraceDescription(_ summary: PathTraceSummary) -> String {
        let metrics =
            "\(summary.exploredPathCount) path(s), up to \(summary.longestSegmentCount) segment(s), "
            + "\(summary.cycleCount) cycle warning(s)"
        return summary.isTruncated ? "Partial trace: \(metrics); limit reached." : metrics
    }

    func logicalContext(for id: ObjectID) -> [String] {
        let selectedAddress = addresses.first { SwiftDataFeatureReadAdapter.stableObjectID($0.id) == id }
        let selectedInterfaces = interfaces.filter {
            $0.id == id || $0.deviceID == id || $0.physicalPortID == id || selectedAddress?.assignedInterfaceID == $0.id
        }
        return selectedInterfaces.flatMap { interface in
            let interfaceAddresses = addresses.filter { $0.assignedInterfaceID == interface.id }.map { $0.address.description }
            let interfaceMemberships = memberships.filter { $0.interfaceID == interface.id }
            let vlanDescriptions = interfaceMemberships.compactMap { membership in
                vlans.first(where: { $0.id == membership.vlanID }).map { vlan in
                    "VLAN \(vlan.number) \(vlan.name) · \(membership.isNative ? "native" : "tagged")"
                }
            }
            return ["\(interface.name) · \(interface.kind.rawValue) · \(interface.mode.rawValue)"] + interfaceAddresses + vlanDescriptions
        }
    }

    private func customFieldSearchTerms(_ fields: [CustomFieldValue]) -> [String] {
        fields.flatMap { field in
            let value: String
            switch field.value {
            case .text(let text): value = text
            case .number(let number): value = String(number)
            case .flag(let flag): value = String(flag)
            case .date(let date): value = String(date.timeIntervalSince1970)
            }
            return [field.key, value]
        }
    }

    func reservationSummary(for id: ObjectID) -> String? {
        if let order = workOrders.first(where: {
            workOrderResourceKeys($0).contains(.object(id)) && SwiftDataFeatureReadAdapter.isPending($0.status)
        }),
            let reservation = order.reservation
        {
            return "\(order.status.rawValue) by \(reservation.ownerID) in work order \(order.id.description)."
        }
        guard topology.reservations.contains(where: { $0.portIDs.contains(id) }) else {
            return nil
        }
        return "Reserved by an active topology reservation; owner is unavailable in this record."
    }
    func attachmentCount(for id: ObjectID) -> Int {
        let workOrderIDs = Set(
            workOrders.filter {
                workOrderResourceKeys($0).contains(.object(id))
            }.map(\.id))
        let evidenceCount = attachmentEvidenceBindings.filter {
            workOrderIDs.contains($0.workOrderID)
        }.count
        let floorPlanCount = floorPlanAssetBindings.filter { $0.floorID == id }.count
        return evidenceCount + floorPlanCount
    }
    func hasConflict(for key: ResourceKey) -> Bool { conflictResourceKeys.contains(key) }

    private func workOrderResourceKeys(_ workOrder: WorkOrder) -> Set<ResourceKey> {
        workOrder.productionResourceKeys
    }
    func hasPendingWork(for key: ResourceKey) -> Bool { pendingResourceKeys.contains(key) }
    func cableSummary(for portID: ObjectID) -> String? {
        topology.cables.first {
            $0.endpointA == portID || $0.endpointB == portID
        }.map {
            "\($0.assetCode.value) · \($0.status.rawValue)"
        }
    }
}
