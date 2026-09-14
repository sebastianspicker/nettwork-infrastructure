import Foundation
import NetworkModel
import WorkspaceChangeControl

extension InventorySearchIndexBuilder {
    static func materializationEdges(for projection: Projection) throws -> Set<DependencyEdge> {
        var edges = Set<DependencyEdge>()
        addHierarchyEdges(projection, to: &edges)
        addDeviceEdges(projection, to: &edges)
        addPortEdges(projection, to: &edges)
        addCableEdges(projection, to: &edges)
        addInterfaceEdges(projection, to: &edges)
        addWorkOrderEdges(projection, to: &edges)
        return edges
    }

    static func connect(_ source: ResourceKey, _ target: ResourceKey, _ kind: String, to edges: inout Set<DependencyEdge>) {
        guard source != target else { return }
        edges.insert(DependencyEdge(source: source, target: target, kind: "dirty.\(kind)"))
        edges.insert(DependencyEdge(source: target, target: source, kind: "context.\(kind)"))
    }

    static func mutuallyDirty(_ lhs: ResourceKey, _ rhs: ResourceKey, _ kind: String, to edges: inout Set<DependencyEdge>) {
        guard lhs != rhs else { return }
        edges.formUnion([
            DependencyEdge(source: lhs, target: rhs, kind: "dirty.\(kind)"),
            DependencyEdge(source: rhs, target: lhs, kind: "dirty.\(kind)"),
            DependencyEdge(source: lhs, target: rhs, kind: "context.\(kind)"),
            DependencyEdge(source: rhs, target: lhs, kind: "context.\(kind)"),
        ])
    }

    static func addHierarchyEdges(_ projection: Projection, to edges: inout Set<DependencyEdge>) {
        for location in projection.hierarchy.locations where location.deletedAt == nil {
            location.parentID.map { connect(.object($0), .object(location.id), "location.child", to: &edges) }
        }
        for rack in projection.hierarchy.racks where rack.deletedAt == nil {
            connect(.object(rack.locationID), .object(rack.id), "location.rack", to: &edges)
        }
        for placement in projection.placements {
            connect(.object(placement.rackID), .rackPlacement(deviceID: placement.deviceID), "rack.placement", to: &edges)
            connect(.rackPlacement(deviceID: placement.deviceID), .object(placement.deviceID), "placement.device", to: &edges)
        }
    }

    static func addDeviceEdges(_ projection: Projection, to edges: inout Set<DependencyEdge>) {
        for device in projection.topology.devices {
            edges.insert(DependencyEdge(source: .object(device.id), target: .object(device.typeID), kind: "context.device.type"))
            device.rackID.map { connect(.object($0), .object(device.id), "rack.device", to: &edges) }
        }
        for module in projection.topology.modules {
            connect(.object(module.deviceID), .object(module.id), "device.module", to: &edges)
        }
    }

    static func addPortEdges(_ projection: Projection, to edges: inout Set<DependencyEdge>) {
        for port in projection.topology.ports {
            connect(.object(port.deviceID), .object(port.id), "device.port", to: &edges)
            port.moduleID.map { connect(.object($0), .object(port.id), "module.port", to: &edges) }
            connect(.string(portStateFactKey(port.id)), .object(port.id), "port-state.port", to: &edges)
        }
    }

    static func addCableEdges(_ projection: Projection, to edges: inout Set<DependencyEdge>) {
        for cable in projection.topology.cables {
            mutuallyDirty(.object(cable.id), .object(cable.endpointA), "port.cable", to: &edges)
            mutuallyDirty(.object(cable.id), .object(cable.endpointB), "port.cable", to: &edges)
        }
        for link in projection.topology.internalLinks {
            addInternalLinkContextEdges(link, to: &edges)
        }
    }

    static func addInternalLinkContextEdges(_ link: InternalLink, to edges: inout Set<DependencyEdge>) {
        edges.formUnion([
            DependencyEdge(source: .object(link.endpointA), target: .object(link.id), kind: "context.port.internal-link"),
            DependencyEdge(source: .object(link.endpointB), target: .object(link.id), kind: "context.port.internal-link"),
            DependencyEdge(source: .object(link.id), target: .object(link.endpointA), kind: "context.internal-link.port"),
            DependencyEdge(source: .object(link.id), target: .object(link.endpointB), kind: "context.internal-link.port"),
        ])
    }

    static func addInterfaceEdges(_ projection: Projection, to edges: inout Set<DependencyEdge>) {
        for interface in projection.interfaces where interface.isActive {
            connect(.object(interface.deviceID), .object(interface.id), "device.interface", to: &edges)
            interface.physicalPortID.map { connect(.object($0), .object(interface.id), "physical-port.interface", to: &edges) }
        }
        for address in projection.addresses where address.isActive {
            address.assignedInterfaceID.map { connect(.object($0), .string(address.id), "interface.address", to: &edges) }
        }
    }

    static func addWorkOrderEdges(_ projection: Projection, to edges: inout Set<DependencyEdge>) {
        for workOrder in projection.workOrders where isPending(workOrder) {
            let workOrderKey = ResourceKey.object(workOrder.id)
            for affectedKey in canonicalAffectedResourceKeys(for: workOrder) {
                connect(workOrderKey, affectedKey, "work-order.pending", to: &edges)
            }
        }
    }
}
