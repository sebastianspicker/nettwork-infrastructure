import NetworkModel

extension TopologyWorkspaceModel {
    var hierarchyLocations: [TopologyHierarchyNode] {
        hierarchy.compactMap { $0.location == nil ? nil : $0 }
    }

    var hierarchyRacks: [TopologyHierarchyNode] {
        hierarchy.compactMap { $0.rack == nil ? nil : $0 }
    }

    var hierarchyDevices: [TopologyHierarchyNode] {
        hierarchy.filter {
            if case .device = $0.kind { return true }
            return false
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
