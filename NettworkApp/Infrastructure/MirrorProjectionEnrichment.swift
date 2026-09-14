import CloudSync
import ContentSafety
import CryptoKit
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension MirrorProjection {
    var enrichment: TraceEnrichment {
        TraceEnrichment(
            revision: topology.revision, hierarchy: hierarchy, interfaces: interfaces,
            addresses: addresses, addressAssignments: assignments, vlans: vlans, vlanMemberships: memberships)
    }

    var csvWorkspaceExportProjection: CSVWorkspaceExportProjection {
        CSVWorkspaceExportProjection(
            locations: hierarchy.locations, racks: hierarchy.racks, deviceTypes: topology.deviceTypes, moduleTemplates: moduleTemplates,
            devices: topology.devices, modules: topology.modules, rackPlacements: placements, ports: topology.ports,
            internalLinks: topology.internalLinks, cables: topology.cables, vrfs: vrfs, prefixes: prefixes, addresses: addresses,
            vlanGroups: vlanGroups, vlans: vlans, interfaces: interfaces, assignments: assignments, floorPlanAnchors: anchors, memberships: memberships
        )
    }

    struct Indexes {
        let portStates: [ObjectID: PortState]
        let containment: [ObjectID: [String]]
        let siteIDs: [ObjectID: Set<ObjectID>]
        let siteNames: [ObjectID: String]
        let plannedKeys: Set<ResourceKey>
        let pendingKeys: Set<ResourceKey>
        let conflictKeys: Set<ResourceKey>
    }

    static func makeIndexes(
        topology: PhysicalTopology, hierarchy: WorkspaceHierarchy, placements: [RackPlacement], addresses: [IPAddressRecord],
        interfaces: [Interface], workOrders: [WorkOrder], conflictResourceKeys: Set<ResourceKey>
    ) throws -> Indexes {
        let locationIDs = try locationIDsByObject(
            topology: topology, hierarchy: hierarchy, placements: placements, addresses: addresses, interfaces: interfaces
        )
        let containment = containmentIndexes(locationIDsByObject: locationIDs, locations: hierarchy.locations)
        let workflow = workflowKeys(workOrders)
        return Indexes(
            portStates: portStates(for: topology),
            containment: containment.paths,
            siteIDs: containment.siteIDs,
            siteNames: containment.siteNames,
            plannedKeys: workflow.planned,
            pendingKeys: workflow.pending,
            conflictKeys: conflictResourceKeys
        )
    }
}
