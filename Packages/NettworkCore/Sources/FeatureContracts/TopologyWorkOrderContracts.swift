import Foundation
import NetworkModel
import WorkspaceChangeControl

/// The mirror-derived source records bound into one typed device-removal
/// operation. Presentation may select a device, but it cannot synthesize or
/// infer its placement and floor-plan dependencies.
public struct DeviceDecommissionSnapshot: Equatable, Sendable {
    public let device: Device
    public let modules: [Module]
    public let ports: [NetworkModel.Port]
    public let rackPlacements: [RackPlacement]
    public let floorPlanAnchors: [FloorPlanAnchor]
    public let interfaces: [Interface]
    public let addressAssignments: [IPAddressAssignment]
    public let vlanMemberships: [InterfaceVLANMembership]
    public let addresses: [IPAddressRecord]

    public init(
        device: Device,
        modules: [Module],
        ports: [NetworkModel.Port],
        rackPlacements: [RackPlacement],
        floorPlanAnchors: [FloorPlanAnchor],
        interfaces: [Interface],
        addressAssignments: [IPAddressAssignment],
        vlanMemberships: [InterfaceVLANMembership],
        addresses: [IPAddressRecord]
    ) {
        self.device = device
        self.modules = modules
        self.ports = ports
        self.rackPlacements = rackPlacements
        self.floorPlanAnchors = floorPlanAnchors
        self.interfaces = interfaces
        self.addressAssignments = addressAssignments
        self.vlanMemberships = vlanMemberships
        self.addresses = addresses
    }
}

public enum TopologyDraftAction: Equatable, Sendable {
    /// The complete desired cable, including its stable identity and physical
    /// attributes, is captured when the work order is staged.
    case connect(ConnectTopologyCommand)
    case disconnect(DisconnectTopologyCommand)
    case move(MoveTopologyCommand)
    case remove(RemoveTopologyCommand)
    case deviceDecommission(PlannedDeviceDecommission)
    case markUnavailable(MarkPortUnavailableTopologyCommand)
    case hierarchy(PlannedHierarchyOperation)
}

public struct TopologyWorkOrderRequest: Equatable, Sendable {
    public let title: String
    public let ticket: String
    public let notes: String
    public let action: TopologyDraftAction
    public let resourceKeys: Set<ResourceKey>

    public init(title: String, ticket: String, notes: String, action: TopologyDraftAction, resourceKeys: Set<ResourceKey>) {
        self.title = title
        self.ticket = ticket
        self.notes = notes
        self.action = action
        self.resourceKeys = resourceKeys
    }
}

public protocol TopologyBrowsing: Sendable {
    func hierarchy(in namespace: PersistenceNamespace) async throws -> [TopologyHierarchyNode]
    func racks(in namespace: PersistenceNamespace) async throws -> [RackElevationSnapshot]
    func deviceDecommissionSnapshot(for deviceID: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceDecommissionSnapshot
}

public protocol TopologyWorkOrderDrafting: Sendable {
    func stage(_ request: TopologyWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
}
