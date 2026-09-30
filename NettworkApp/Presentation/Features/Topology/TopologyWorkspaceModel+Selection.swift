import FeatureContracts
import NetworkModel

extension TopologyWorkspaceModel {
    var ports: [TopologyPortSnapshot] {
        racks.flatMap(\.ports)
            .reduce(into: [ObjectID: TopologyPortSnapshot]()) { $0[$1.id] = $1 }
            .values
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    var cables: [TopologyCableSnapshot] {
        ports.compactMap(\.cable)
            .reduce(into: [ObjectID: TopologyCableSnapshot]()) { $0[$1.id] = $1 }
            .values
            .sorted { $0.assetCode < $1.assetCode }
    }

    var visibleRacks: [RackElevationSnapshot] {
        guard let focusedObject else { return racks }
        return racks.filter { rack in
            switch focusedObject.kind {
            case .rack:
                rack.rackID == focusedObject.id
            case .device:
                rack.entries.contains { $0.id == focusedObject.id }
                    || rack.ports.contains { $0.deviceID == focusedObject.id }
            case .port:
                rack.ports.contains { $0.id == focusedObject.id }
            case .cable:
                rack.ports.contains { $0.cable?.id == focusedObject.id }
            case .site, .room, .address, .interface:
                true
            }
        }
    }

    var selectedPorts: [TopologyPortSnapshot] {
        ports.filter { selectedPortIDs.contains($0.id) }
    }
}
